//
//  StorageTests.swift
//  HopChat-1Tests
//
//  ConversationStore: durability (the v1 write race lost messages), status
//  monotonicity, unread accounting, deletion authorization, seen-envelope TTL,
//  number-change merges and the one-time legacy migration — contract §7.
//

import Testing
import Foundation
@testable import HopChat_1

// MARK: - Helpers

@MainActor
private func makeStore(_ directory: URL,
                       defaults: UserDefaults? = nil,
                       now: @escaping @Sendable () -> Date = { Date() }) -> ConversationStore {
    ConversationStore(directory: directory,
                      legacyDefaults: defaults,
                      debounce: .milliseconds(1),
                      now: now)
}

private func message(_ id: String,
                     conversation: String = "+14155552671",
                     from: String = "+14155552671",
                     to: String = "+351912345678",
                     body: String = "hello",
                     at seconds: TimeInterval = 0,
                     isFromMe: Bool = false,
                     isRead: Bool = false,
                     status: MessageStatus = .delivered,
                     kind: MessageKind = .text,
                     imageFilename: String? = nil) -> StoredMessage {
    StoredMessage(id: id,
                  conversationID: conversation,
                  fromPhone: from,
                  toPhone: to,
                  kind: kind,
                  body: body,
                  imageFilename: imageFilename,
                  timestamp: Date(timeIntervalSince1970: 1_790_000_000 + seconds),
                  status: status,
                  isFromMe: isFromMe,
                  isRead: isRead)
}

// MARK: - Messages

@MainActor
@Suite("ConversationStore — messages")
struct StoreMessageTests {

    @Test("appendMessage rejects a duplicate id")
    func duplicateAppend() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)

        #expect(store.appendMessage(message("m1")))
        #expect(store.appendMessage(message("m1", body: "different text")) == false)
        #expect(store.thread("+14155552671").count == 1)
        #expect(store.thread("+14155552671").first?.body == "hello")
    }

    @Test("messages are kept sorted by timestamp regardless of insertion order")
    func ordering() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)

        store.appendMessage(message("c", at: 300))
        store.appendMessage(message("a", at: 100))
        store.appendMessage(message("b", at: 200))

        #expect(store.thread("+14155552671").map { $0.id } == ["a", "b", "c"])
        #expect(store.lastMessage("+14155552671")?.id == "c")
    }

    @Test("status never downgrades, but failed → pending is allowed")
    func statusMonotonicity() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let cid = "+14155552671"
        store.appendMessage(message("m1", conversation: cid, isFromMe: true, status: .pending))

        func status() -> MessageStatus? { store.thread(cid).first?.status }

        store.updateStatus(messageID: "m1", conversationID: cid, to: .sent)
        #expect(status() == .sent)
        store.updateStatus(messageID: "m1", conversationID: cid, to: .pending)
        #expect(status() == .sent, "sent must not fall back to pending")
        store.updateStatus(messageID: "m1", conversationID: cid, to: .delivered)
        #expect(status() == .delivered)
        store.updateStatus(messageID: "m1", conversationID: cid, to: .sent)
        #expect(status() == .delivered)
        store.updateStatus(messageID: "m1", conversationID: cid, to: .read)
        #expect(status() == .read)
        store.updateStatus(messageID: "m1", conversationID: cid, to: .delivered)
        #expect(status() == .read)
        store.updateStatus(messageID: "m1", conversationID: cid, to: .failed)
        #expect(status() == .read, "a delivered/read message must never become failed")

        // A pending message may give up, and a failed one may be retried.
        store.appendMessage(message("m2", conversation: cid, isFromMe: true, status: .pending))
        store.updateStatus(messageID: "m2", conversationID: cid, to: .failed)
        #expect(store.thread(cid).first { $0.id == "m2" }?.status == .failed)
        store.updateStatus(messageID: "m2", conversationID: cid, to: .pending)
        #expect(store.thread(cid).first { $0.id == "m2" }?.status == .pending)
        store.updateStatus(messageID: "m2", conversationID: cid, to: .failed)
        store.updateStatus(messageID: "m2", conversationID: cid, to: .delivered)
        #expect(store.thread(cid).first { $0.id == "m2" }?.status == .delivered,
                "a late ack after a failure must still count")
    }

    @Test("transition rules are self-consistent")
    func transitionTable() {
        #expect(MessageStatus.pending.canTransition(to: .sent))
        #expect(MessageStatus.pending.canTransition(to: .failed))
        #expect(MessageStatus.failed.canTransition(to: .pending))
        #expect(MessageStatus.failed.canTransition(to: .delivered))
        #expect(MessageStatus.sent.canTransition(to: .failed) == false)
        #expect(MessageStatus.read.canTransition(to: .delivered) == false)
        #expect(MessageStatus.read.canTransition(to: .read) == false)
        #expect(MessageStatus.delivered < MessageStatus.read)
    }

    @Test("recordAttempt increments attempts and stamps the time")
    func attempts() {
        let temp = TempDirectory()
        let stamp = Date(timeIntervalSince1970: 1_790_100_000)
        let store = makeStore(temp.url, now: { stamp })
        store.appendMessage(message("m1", isFromMe: true, status: .pending))

        store.recordAttempt(messageID: "m1", conversationID: "+14155552671")
        store.recordAttempt(messageID: "m1", conversationID: "+14155552671")
        let stored = store.thread("+14155552671").first
        #expect(stored?.attempts == 2)
        #expect(stored?.lastAttemptAt == stamp)
    }

    @Test("pendingOutgoing lists only our own pending messages, oldest first")
    func pendingOutgoing() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        store.appendMessage(message("mine-late", at: 200, isFromMe: true, status: .pending))
        store.appendMessage(message("mine-early", at: 100, isFromMe: true, status: .pending))
        store.appendMessage(message("sent", at: 150, isFromMe: true, status: .sent))
        store.appendMessage(message("theirs", at: 120, isFromMe: false, status: .delivered))

        #expect(store.pendingOutgoing().map { $0.id } == ["mine-early", "mine-late"])
    }

    @Test("delete-for-everyone is honoured only for the author")
    func deleteForEveryoneAuthorization() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let cid = "+14155552671"
        store.appendMessage(message("theirs", conversation: cid, from: "+14155552671",
                                    body: "their message"))
        store.appendMessage(message("mine", conversation: cid, from: "+351912345678",
                                    body: "my message", isFromMe: true))

        // The sender may retract their own message.
        #expect(store.markDeletedForEveryone(messageID: "theirs", conversationID: cid,
                                             requestedBy: "+14155552671"))
        let deleted = store.thread(cid).first { $0.id == "theirs" }
        #expect(deleted?.isDeleted == true)
        #expect(deleted?.body.isEmpty == true)

        // Nobody else may.
        #expect(store.markDeletedForEveryone(messageID: "mine", conversationID: cid,
                                             requestedBy: "+14155552671") == false)
        #expect(store.markDeletedForEveryone(messageID: "mine", conversationID: cid,
                                             requestedBy: "+447700900123") == false)
        let intact = store.thread(cid).first { $0.id == "mine" }
        #expect(intact?.isDeleted == false)
        #expect(intact?.body == "my message")

        // Unknown ids are refused rather than crashing.
        #expect(store.markDeletedForEveryone(messageID: "nope", conversationID: cid,
                                             requestedBy: "+14155552671") == false)
    }

    @Test("deleting a message removes its image file")
    func deleteRemovesMedia() throws {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let filename = try store.saveImage(Data(repeating: 0xFF, count: 64), id: "img1")
        store.appendMessage(message("img1", kind: .image, imageFilename: filename))
        #expect(FileManager.default.fileExists(atPath: store.imageURL(filename).path))

        store.deleteMessageLocally(messageID: "img1", conversationID: "+14155552671")
        #expect(store.thread("+14155552671").isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.imageURL(filename).path) == false)
    }

    @Test("translations are not applied to deleted messages")
    func translationSkipsDeleted() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let cid = "+14155552671"
        store.appendMessage(message("m1", conversation: cid))
        store.setTranslation(messageID: "m1", conversationID: cid, text: "olá")
        #expect(store.thread(cid).first?.translatedBody == "olá")

        store.markDeletedForEveryone(messageID: "m1", conversationID: cid,
                                     requestedBy: "+14155552671")
        store.setTranslation(messageID: "m1", conversationID: cid, text: "late translation")
        #expect(store.thread(cid).first?.translatedBody == nil)
    }
}

// MARK: - Durability

@MainActor
@Suite("ConversationStore — durability (the v1 write race)")
struct StoreDurabilityTests {

    @Test("1000 rapid appends all survive a flush and reload", .timeLimit(.minutes(2)))
    func rapidAppendsSurvive() async throws {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let cid = "+14155552671"

        for i in 0..<1000 {
            #expect(store.appendMessage(message("m-\(i)", conversation: cid,
                                                body: "body \(i)", at: TimeInterval(i))))
        }
        await store.flush()

        // A brand-new instance reading the same directory must see everything,
        // in order. v1 coalesced full-snapshot writes out of order and lost mail.
        let reloaded = makeStore(temp.url)
        let thread = reloaded.thread(cid)
        #expect(thread.count == 1000)
        #expect(thread.map { $0.id } == (0..<1000).map { "m-\($0)" })
        #expect(thread.first?.body == "body 0")
        #expect(thread.last?.body == "body 999")
    }

    @Test("interleaved writes across many conversations all persist")
    func interleavedConversations() async throws {
        let temp = TempDirectory()
        let store = makeStore(temp.url)

        for i in 0..<200 {
            let cid = "+35191234\(String(format: "%04d", i % 20))"
            store.appendMessage(message("m-\(i)", conversation: cid, from: cid,
                                        at: TimeInterval(i)))
        }
        store.addContact(Contact(phone: "+14155552671", name: "Bob"))
        await store.flush()

        let reloaded = makeStore(temp.url)
        let total = reloaded.messages.values.reduce(0) { $0 + $1.count }
        #expect(total == 200)
        #expect(reloaded.messages.keys.count == 20)
        #expect(reloaded.contacts.count == 1)
    }

    @Test("a status update after a burst is the version that lands on disk")
    func lastWriteWins() async throws {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let cid = "+14155552671"
        store.appendMessage(message("m1", conversation: cid, isFromMe: true, status: .pending))
        for _ in 0..<50 {
            store.appendMessage(message(UUID().uuidString, conversation: cid))
        }
        store.updateStatus(messageID: "m1", conversationID: cid, to: .read)
        await store.flush()

        let reloaded = makeStore(temp.url)
        #expect(reloaded.thread(cid).first { $0.id == "m1" }?.status == .read)
        #expect(reloaded.thread(cid).count == 51)
    }

    @Test("thread files are named by hash — no phone numbers on disk")
    func filenamesArehashed() async throws {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        store.appendMessage(message("m1", conversation: "+14155552671"))
        await store.flush()

        let files = try FileManager.default
            .contentsOfDirectory(atPath: temp.url.appendingPathComponent("threads").path)
        #expect(files.isEmpty == false)
        #expect(files.contains { $0.contains("4155552671") } == false)
        #expect(files.contains("\(MediaStore.sha256Hex("+14155552671")).json"))
    }
}

// MARK: - Unread

@MainActor
@Suite("ConversationStore — unread accounting")
struct StoreUnreadTests {

    @Test("unread counts only incoming, unread, undeleted messages")
    func counting() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let cid = "+14155552671"

        store.appendMessage(message("a", conversation: cid, at: 1))
        store.appendMessage(message("b", conversation: cid, at: 2))
        store.appendMessage(message("read", conversation: cid, at: 3, isRead: true))
        store.appendMessage(message("mine", conversation: cid, from: "+351912345678",
                                    at: 4, isFromMe: true, isRead: true))

        #expect(store.unreadCount(cid) == 2)
        #expect(store.totalUnreadCount == 2)
    }

    @Test("markConversationRead returns only the newly-read incoming messages")
    func markRead() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let cid = "+14155552671"
        store.appendMessage(message("a", conversation: cid, at: 1))
        store.appendMessage(message("b", conversation: cid, at: 2))
        store.appendMessage(message("already", conversation: cid, at: 3, isRead: true))
        store.appendMessage(message("mine", conversation: cid, from: "+351912345678",
                                    at: 4, isFromMe: true))

        let newlyRead = store.markConversationRead(cid)
        #expect(newlyRead.map { $0.id } == ["a", "b"])
        #expect(store.unreadCount(cid) == 0)
        #expect(store.totalUnreadCount == 0)

        // Reading again reports nothing, so no duplicate read receipts are sent.
        #expect(store.markConversationRead(cid).isEmpty)
        #expect(store.markConversationRead("+447700900123").isEmpty)
    }

    @Test("blocked contacts and inactive groups do not add to the badge")
    func badgeExclusions() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)

        store.appendMessage(message("a", conversation: "+14155552671", from: "+14155552671"))
        store.appendMessage(message("b", conversation: "group:g1", from: "+447700900123"))
        store.upsertGroup(ChatGroup(id: "g1", name: "Trip",
                                    members: ["+351912345678", "+447700900123"],
                                    admins: ["+351912345678"]))
        #expect(store.totalUnreadCount == 2)

        store.setBlocked("+14155552671", true)
        #expect(store.totalUnreadCount == 1)
        #expect(store.unreadCount("+14155552671") == 1, "the per-thread count is unchanged")

        store.upsertGroup(ChatGroup(id: "g1", name: "Trip",
                                    members: ["+447700900123"],
                                    admins: ["+351912345678"],
                                    isActive: false))
        #expect(store.totalUnreadCount == 0)

        store.setBlocked("+14155552671", false)
        #expect(store.totalUnreadCount == 1)
    }
}

// MARK: - Contacts and conversations

@MainActor
@Suite("ConversationStore — contacts and conversations")
struct StoreContactTests {

    @Test("removeContact(deleteMessages:) honours both choices")
    func removeContact() async {
        let temp = TempDirectory()
        let store = makeStore(temp.url)

        store.addContact(Contact(phone: "+14155552671", name: "Bob"))
        store.addContact(Contact(phone: "+447700900123", name: "Carol"))
        store.appendMessage(message("m1", conversation: "+14155552671", from: "+14155552671"))
        store.appendMessage(message("m2", conversation: "+447700900123", from: "+447700900123"))

        // Keep the history.
        store.removeContact(phone: "+14155552671", deleteMessages: false)
        #expect(store.contact(for: "+14155552671") == nil)
        #expect(store.thread("+14155552671").count == 1)

        // Delete it.
        store.removeContact(phone: "+447700900123", deleteMessages: true)
        #expect(store.contact(for: "+447700900123") == nil)
        #expect(store.thread("+447700900123").isEmpty)
        #expect(store.unreadCount("+447700900123") == 0)

        await store.flush()
        let reloaded = makeStore(temp.url)
        #expect(reloaded.thread("+14155552671").count == 1)
        #expect(reloaded.thread("+447700900123").isEmpty)
    }

    @Test("addContact is idempotent and blocking works for unknown numbers")
    func contactBasics() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)

        store.addContact(Contact(phone: "+14155552671", name: "Bob"))
        store.addContact(Contact(phone: "+14155552671", name: "Robert"))
        #expect(store.contacts.count == 1)
        #expect(store.contact(for: "+14155552671")?.name == "Bob")

        store.renameContact(phone: "+14155552671", newName: "Robert")
        #expect(store.contact(for: "+14155552671")?.name == "Robert")

        // Blocking a stranger creates a blocked row.
        #expect(store.isBlocked("+447700900123") == false)
        store.setBlocked("+447700900123", true)
        #expect(store.isBlocked("+447700900123"))
        #expect(store.contact(for: "+447700900123")?.isBlocked == true)
    }

    @Test("renameConversation merges into an existing thread without duplicates")
    func renameMerge() async {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let old = "+14155552671"
        let new = "+351911111111"

        store.addContact(Contact(phone: old, name: "Bob"))
        store.appendMessage(message("old-1", conversation: old, from: old, at: 100))
        store.appendMessage(message("shared", conversation: old, from: old, at: 200))
        store.appendMessage(message("new-1", conversation: new, from: new, at: 300))
        store.appendMessage(message("shared", conversation: new, from: new, at: 200))

        store.renameConversation(from: old, to: new)

        let merged = store.thread(new)
        #expect(store.thread(old).isEmpty)
        #expect(merged.count == 3, "the shared id must not be duplicated")
        #expect(merged.map { $0.id } == ["shared", "old-1", "new-1"].sorted { lhs, rhs in
            let order = ["old-1": 100, "shared": 200, "new-1": 300]
            return order[lhs]! < order[rhs]!
        })
        // Participants are remapped onto the new number.
        #expect(merged.allSatisfy { $0.fromPhone != old && $0.toPhone != old })
        #expect(merged.first { $0.id == "old-1" }?.fromPhone == new)

        // The contact moved too.
        #expect(store.contact(for: old) == nil)
        #expect(store.contact(for: new)?.name == "Bob")

        await store.flush()
        let reloaded = makeStore(temp.url)
        #expect(reloaded.thread(new).count == 3)
        #expect(reloaded.thread(old).isEmpty)
    }

    @Test("renameConversation with no existing target simply moves the thread")
    func renameMove() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        store.addContact(Contact(phone: "+14155552671", name: "+14155552671"))
        store.appendMessage(message("m1", conversation: "+14155552671", from: "+14155552671"))

        store.renameConversation(from: "+14155552671", to: "+351911111111")
        #expect(store.thread("+351911111111").count == 1)
        #expect(store.contact(for: "+351911111111")?.name == "+351911111111")

        // No-ops are safe.
        store.renameConversation(from: "+351911111111", to: "+351911111111")
        store.renameConversation(from: "", to: "+351911111111")
        #expect(store.thread("+351911111111").count == 1)
    }

    @Test("conversation id helpers round-trip")
    func conversationIDs() {
        #expect(ConversationStore.conversationID(peer: "+14155552671") == "+14155552671")
        #expect(ConversationStore.conversationID(group: "g1") == "group:g1")
        #expect(ConversationStore.groupID(from: "group:g1") == "g1")
        #expect(ConversationStore.groupID(from: "+14155552671") == nil)
    }

    @Test("recentMessages returns the last incoming text messages only")
    func recentMessages() {
        let temp = TempDirectory()
        let store = makeStore(temp.url)
        let peer = "+14155552671"
        for i in 0..<30 {
            store.appendMessage(message("m-\(i)", conversation: peer, from: peer,
                                        body: "text \(i)", at: TimeInterval(i)))
        }
        store.appendMessage(message("mine", conversation: peer, from: "+351912345678",
                                    at: 100, isFromMe: true))
        store.appendMessage(message("img", conversation: peer, from: peer, at: 101,
                                    kind: .image))

        let recent = store.recentMessages(with: peer, limit: 20)
        #expect(recent.count == 20)
        #expect(recent.first?.id == "m-10")
        #expect(recent.last?.id == "m-29")
        #expect(recent.allSatisfy { !$0.isFromMe && $0.kind == .text })
        #expect(store.recentMessages(with: peer, limit: 0).isEmpty)
    }
}

// MARK: - Seen envelopes

@MainActor
@Suite("ConversationStore — seen-envelope set")
struct StoreSeenTests {

    @Test("seen ids are remembered and persisted")
    func recordAndReload() async {
        let temp = TempDirectory()
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let store = makeStore(temp.url, now: { stamp })

        #expect(store.hasSeenEnvelope("env-1") == false)
        store.recordSeenEnvelope("env-1")
        store.recordSeenEnvelope("env-1")     // idempotent
        #expect(store.hasSeenEnvelope("env-1"))
        await store.flush()

        let reloaded = makeStore(temp.url, now: { stamp })
        #expect(reloaded.hasSeenEnvelope("env-1"))
        #expect(reloaded.hasSeenEnvelope("env-2") == false)
    }

    @Test("entries older than 30 days are pruned")
    func ttlPruning() async {
        let temp = TempDirectory()
        let clock = TestClock.Movable(Date(timeIntervalSince1970: 1_790_000_000))
        let store = makeStore(temp.url, now: clock.closure)

        store.recordSeenEnvelope("old")
        clock.advance(by: 31 * 86_400)
        store.recordSeenEnvelope("new")

        #expect(store.hasSeenEnvelope("old") == false, "expired entry should be pruned")
        #expect(store.hasSeenEnvelope("new"))
        await store.flush()

        let reloaded = makeStore(temp.url, now: clock.closure)
        #expect(reloaded.hasSeenEnvelope("old") == false)
        #expect(reloaded.hasSeenEnvelope("new"))
    }

    @Test("an entry inside the window survives")
    func ttlBoundary() {
        let temp = TempDirectory()
        let clock = TestClock.Movable(Date(timeIntervalSince1970: 1_790_000_000))
        let store = makeStore(temp.url, now: clock.closure)
        store.recordSeenEnvelope("recent")
        clock.advance(by: 29 * 86_400)
        store.recordSeenEnvelope("other")
        #expect(store.hasSeenEnvelope("recent"))
    }
}

// MARK: - Legacy migration

@MainActor
@Suite("ConversationStore — legacy v1 migration")
struct LegacyMigrationTests {

    private struct OldContact: Encodable {
        let phone: String
        let name: String?
        let ip: String?
        let port: UInt16?
        let addedAt: Date
    }

    private struct OldMessage: Encodable {
        let id: String
        let fromPhone: String
        let toPhone: String
        let body: String
        let timestamp: Date
        let delivered: Bool
        let isFromMe: Bool
        let translatedBody: String?
        let isRead: Bool
    }

    private func populate(_ defaults: UserDefaults,
                          corruptMessages: Bool = false) throws {
        let encoder = JSONEncoder()
        let contacts = [
            OldContact(phone: "+14155552671", name: "Bob", ip: "192.168.1.5",
                       port: 4001, addedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            OldContact(phone: "+447700900123", name: nil, ip: nil, port: 0,
                       addedAt: Date(timeIntervalSince1970: 1_700_000_100)),
        ]
        defaults.set(try encoder.encode(contacts), forKey: LegacyMigration.contactsKey)
        defaults.set("+351912345678", forKey: LegacyMigration.phoneKey)

        if corruptMessages {
            defaults.set(Data("this is not JSON".utf8), forKey: LegacyMigration.messagesKey)
        } else {
            let key = "+351912345678\(LegacyMigration.threadSeparator)+14155552671"
            let messages = [
                OldMessage(id: "old-1", fromPhone: "+14155552671", toPhone: "+351912345678",
                           body: "hi there", timestamp: Date(timeIntervalSince1970: 1_700_000_200),
                           delivered: true, isFromMe: false, translatedBody: "olá", isRead: false),
                OldMessage(id: "old-2", fromPhone: "+351912345678", toPhone: "+14155552671",
                           body: "hello back", timestamp: Date(timeIntervalSince1970: 1_700_000_300),
                           delivered: false, isFromMe: true, translatedBody: nil, isRead: true),
            ]
            defaults.set(try encoder.encode([key: messages]), forKey: LegacyMigration.messagesKey)
        }
        defaults.set(Data("routing".utf8), forKey: "hopchat.routingTable.v1")
        defaults.set(Data("keys".utf8), forKey: "hopchat.peerKeys.signing.v1")
    }

    @Test("v1 contacts and threads are imported and the legacy keys removed")
    func migrates() async throws {
        let temp = TempDirectory()
        let suite = TempDefaults()
        try populate(suite.defaults)
        #expect(LegacyMigration.hasLegacyData(in: suite.defaults))

        let store = makeStore(temp.url, defaults: suite.defaults)

        #expect(store.contacts.count == 2)
        #expect(store.contact(for: "+14155552671")?.name == "Bob")
        #expect(store.contact(for: "+14155552671")?.lanIP == "192.168.1.5")
        #expect(store.contact(for: "+14155552671")?.lanPort == 4001)
        // A missing name falls back to the phone; port 0 becomes nil.
        #expect(store.contact(for: "+447700900123")?.name == "+447700900123")
        #expect(store.contact(for: "+447700900123")?.lanPort == nil)

        let thread = store.thread("+14155552671")
        #expect(thread.count == 2)
        #expect(thread.map { $0.id } == ["old-1", "old-2"])
        #expect(thread[0].status == .delivered)
        #expect(thread[0].translatedBody == "olá")
        #expect(thread[0].isRead == false)
        #expect(thread[1].status == .pending)
        #expect(thread[1].isFromMe)
        #expect(store.unreadCount("+14155552671") == 1)

        // Legacy keys are gone, except the phone (the network layer consumes it).
        #expect(suite.defaults.data(forKey: LegacyMigration.contactsKey) == nil)
        #expect(suite.defaults.data(forKey: LegacyMigration.messagesKey) == nil)
        #expect(suite.defaults.data(forKey: "hopchat.routingTable.v1") == nil)
        #expect(suite.defaults.data(forKey: "hopchat.peerKeys.signing.v1") == nil)
        #expect(suite.defaults.string(forKey: LegacyMigration.phoneKey) == "+351912345678")
        #expect(LegacyMigration.hasLegacyData(in: suite.defaults) == false)

        await store.flush()
    }

    @Test("a corrupt messages blob does not block the contacts import")
    func corruptBlobIsSurvivable() async throws {
        let temp = TempDirectory()
        let suite = TempDefaults()
        try populate(suite.defaults, corruptMessages: true)

        let store = makeStore(temp.url, defaults: suite.defaults)
        #expect(store.contacts.count == 2, "contacts should still import")
        #expect(store.messages.isEmpty, "the unreadable thread blob is skipped")
        #expect(suite.defaults.data(forKey: LegacyMigration.messagesKey) == nil)
        await store.flush()
    }

    @Test("migration is idempotent and never runs twice")
    func idempotent() async throws {
        let temp = TempDirectory()
        let suite = TempDefaults()
        try populate(suite.defaults)

        let first = makeStore(temp.url, defaults: suite.defaults)
        #expect(first.thread("+14155552671").count == 2)
        await first.flush()

        // A second launch: the keys are gone, nothing is duplicated.
        let second = makeStore(temp.url, defaults: suite.defaults)
        #expect(second.contacts.count == 2)
        #expect(second.thread("+14155552671").count == 2)

        // Even if stale legacy keys reappear, existing v2 data wins.
        try populate(suite.defaults)
        let third = makeStore(temp.url, defaults: suite.defaults)
        #expect(third.thread("+14155552671").count == 2)
        #expect(third.contacts.count == 2)
        #expect(LegacyMigration.hasLegacyData(in: suite.defaults) == false,
                "stale legacy keys must be dropped rather than re-imported")
    }

    @Test("legacy thread keys map to the peer phone")
    func threadKeyMapping() {
        let sep = LegacyMigration.threadSeparator
        #expect(LegacyMigration.peerPhone(threadKey: "+351912345678\(sep)+14155552671",
                                          myPhone: "+351912345678") == "+14155552671")
        #expect(LegacyMigration.peerPhone(threadKey: "+14155552671\(sep)+351912345678",
                                          myPhone: "+351912345678") == "+14155552671")
        #expect(LegacyMigration.peerPhone(threadKey: "+14155552671",
                                          myPhone: "+351912345678") == "+14155552671")
        #expect(LegacyMigration.peerPhone(threadKey: "", myPhone: "+351912345678") == nil)
    }

    @Test("no legacy data means no migration work")
    func noLegacyData() {
        let temp = TempDirectory()
        let suite = TempDefaults()
        let store = makeStore(temp.url, defaults: suite.defaults)
        #expect(store.contacts.isEmpty)
        #expect(store.messages.isEmpty)
    }
}

// MARK: - Wipe

@MainActor
@Suite("ConversationStore — wipeAll")
struct StoreWipeTests {

    @Test("wipeAll clears memory, disk and legacy keys")
    func wipe() async throws {
        let temp = TempDirectory()
        let suite = TempDefaults()
        suite.defaults.set("+351912345678", forKey: LegacyMigration.phoneKey)

        let store = makeStore(temp.url, defaults: suite.defaults)
        store.addContact(Contact(phone: "+14155552671", name: "Bob"))
        store.upsertGroup(ChatGroup(id: "g1", name: "Trip", members: ["+14155552671"],
                                    admins: ["+14155552671"]))
        store.appendMessage(message("m1"))
        store.recordSeenEnvelope("env-1")
        _ = try store.saveImage(Data(repeating: 0xFF, count: 32), id: "img")
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: temp.url.path))

        store.wipeAll()

        #expect(store.contacts.isEmpty)
        #expect(store.groups.isEmpty)
        #expect(store.messages.isEmpty)
        #expect(store.totalUnreadCount == 0)
        #expect(store.hasSeenEnvelope("env-1") == false)
        #expect(suite.defaults.string(forKey: LegacyMigration.phoneKey) == nil)

        await store.flush()
        #expect(FileManager.default.fileExists(atPath: temp.url.path) == false,
                "the whole store directory should be gone")

        // A fresh store on the same path starts empty.
        let reloaded = makeStore(temp.url, defaults: suite.defaults)
        #expect(reloaded.contacts.isEmpty)
        #expect(reloaded.messages.isEmpty)
    }
}
