//
//  ConversationStore.swift
//  HopChat-1
//
//  File-backed conversation store.
//
//  Layout (Application Support/HopChat/, excluded from backup):
//     contacts.json
//     groups.json
//     seen.json
//     threads/<sha256hex(conversationID)>.json     // no phone numbers in filenames
//     media/<messageID>.jpg
//     avatars/<sha256hex(phone)>.jpg
//
//  All writes go through a single serial `StoreWriter` with per-file versions,
//  and only the touched file is rewritten (never the whole store).
//

import Foundation
import Combine
import os

@MainActor
final class ConversationStore: ObservableObject {

    // MARK: - Shared

    static let shared = ConversationStore(directory: ConversationStore.defaultDirectory)

    nonisolated static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("HopChat", isDirectory: true)
    }

    // MARK: - Published state

    @Published var showTabBar: Bool = true
    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var groups: [ChatGroup] = []
    /// conversationID → messages sorted ascending by timestamp
    @Published private(set) var messages: [String: [StoredMessage]] = [:]
    @Published private(set) var totalUnreadCount: Int = 0

    // MARK: - Storage plumbing

    let directory: URL
    private let media: MediaStore
    private let writer: StoreWriter
    private let legacyDefaults: UserDefaults?
    private let now: @Sendable () -> Date
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var unreadCounts: [String: Int] = [:]
    /// envelope id → first-seen time (unix seconds)
    private var seenEnvelopes: [String: Int64] = [:]

    private var versionCounter: UInt64 = 0
    private var writeChain: Task<Void, Never>?

    private static let seenTTL: TimeInterval = 30 * 24 * 60 * 60
    private static let seenCap = 50_000

    private var contactsURL: URL { directory.appendingPathComponent("contacts.json") }
    private var groupsURL: URL { directory.appendingPathComponent("groups.json") }
    private var seenURL: URL { directory.appendingPathComponent("seen.json") }
    private var threadsDirectory: URL { directory.appendingPathComponent("threads", isDirectory: true) }

    private func threadURL(_ conversationID: String) -> URL {
        threadsDirectory.appendingPathComponent("\(MediaStore.sha256Hex(conversationID)).json")
    }

    // MARK: - Init

    init(directory: URL,
         legacyDefaults: UserDefaults? = .standard,
         debounce: Duration = .milliseconds(150),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.legacyDefaults = legacyDefaults
        self.media = MediaStore(root: directory)
        self.writer = StoreWriter(debounce: debounce)
        self.now = now

        prepareDirectories()
        migrateLegacyIfNeeded()
        loadFromDisk()
        recomputeUnread()
    }

    private func prepareDirectories() {
        for dir in [directory, threadsDirectory] {
            guard !fm.fileExists(atPath: dir.path) else { continue }
            do {
                try fm.createDirectory(at: dir,
                                       withIntermediateDirectories: true,
                                       attributes: StorageProtection.directoryAttributes)
            } catch {
                Log.store.error("could not create store directory: \(String(describing: error), privacy: .public)")
            }
        }
        media.ensureDirectories()
        excludeFromBackup()
    }

    private func excludeFromBackup() {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try url.setResourceValues(values) }
        catch { Log.store.error("could not exclude store from backup: \(String(describing: error), privacy: .public)") }
    }

    // MARK: - Conversation identity

    /// A 1:1 conversation is identified by the peer's phone number.
    nonisolated static func conversationID(peer phone: String) -> String { phone }
    nonisolated static func conversationID(group id: String) -> String { "group:" + id }
    nonisolated static func groupID(from conversationID: String) -> String? {
        conversationID.hasPrefix("group:")
            ? String(conversationID.dropFirst("group:".count))
            : nil
    }

    // MARK: - Loading

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: contactsURL) {
            if let decoded = try? decoder.decode([Contact].self, from: data) {
                contacts = decoded
            } else {
                Log.store.error("contacts.json unreadable; starting empty")
            }
        }
        if let data = try? Data(contentsOf: groupsURL) {
            if let decoded = try? decoder.decode([ChatGroup].self, from: data) {
                groups = decoded
            } else {
                Log.store.error("groups.json unreadable; starting empty")
            }
        }
        if let data = try? Data(contentsOf: seenURL),
           let decoded = try? decoder.decode([String: Int64].self, from: data) {
            seenEnvelopes = decoded
            pruneSeen(persist: false)
        }

        // Threads are small JSON files; load them eagerly. The conversationID is
        // recovered from the messages themselves (filenames are hashed).
        guard let entries = try? fm.contentsOfDirectory(at: threadsDirectory,
                                                        includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let thread = try? decoder.decode([StoredMessage].self, from: data) else {
                Log.store.error("thread file unreadable: \(url.lastPathComponent, privacy: .public)")
                continue
            }
            guard let cid = thread.first?.conversationID else { continue }
            messages[cid] = thread.sorted { $0.timestamp < $1.timestamp }
        }
    }

    // MARK: - Legacy migration

    private func migrateLegacyIfNeeded() {
        guard let defaults = legacyDefaults, LegacyMigration.hasLegacyData(in: defaults) else { return }

        // Never clobber v2 data: if it already exists, just drop the stale keys.
        let hasV2 = fm.fileExists(atPath: contactsURL.path)
            || ((try? fm.contentsOfDirectory(atPath: threadsDirectory.path))?.isEmpty == false)
        guard !hasV2 else {
            LegacyMigration.removeLegacyKeys(from: defaults)
            return
        }

        let imported = LegacyMigration.importLegacy(from: defaults)
        guard !imported.isEmpty else {
            LegacyMigration.removeLegacyKeys(from: defaults)
            return
        }

        // Written synchronously so the keys are only dropped once the data is safe.
        do {
            if !imported.contacts.isEmpty {
                try encoder.encode(imported.contacts)
                    .write(to: contactsURL, options: StorageProtection.writingOptions)
            }
            for (cid, thread) in imported.threads {
                try encoder.encode(thread)
                    .write(to: threadURL(cid), options: StorageProtection.writingOptions)
            }
        } catch {
            Log.store.error("legacy migration write failed; keeping legacy keys: \(String(describing: error), privacy: .public)")
            return
        }
        LegacyMigration.removeLegacyKeys(from: defaults)
        Log.store.info("migrated \(imported.contacts.count) contacts and \(imported.threads.count) threads from legacy storage")
    }

    // MARK: - Persistence

    private enum PendingOp: Sendable {
        case write(Data)
        case delete
    }

    private func nextVersion() -> UInt64 {
        versionCounter &+= 1
        return versionCounter
    }

    private func enqueue(_ op: PendingOp, to url: URL) {
        let version = nextVersion()
        let writer = self.writer
        let previous = writeChain
        writeChain = Task { @MainActor in
            _ = await previous?.value
            switch op {
            case .write(let data): await writer.write(data, to: url, version: version)
            case .delete:          await writer.delete(url, version: version)
            }
        }
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        do { enqueue(.write(try encoder.encode(value)), to: url) }
        catch { Log.store.error("encode failed for \(url.lastPathComponent, privacy: .public)") }
    }

    private func persistContacts() { persist(contacts, to: contactsURL) }
    private func persistGroups() { persist(groups, to: groupsURL) }
    private func persistSeen() { persist(seenEnvelopes, to: seenURL) }

    /// Writes only the touched thread (or removes the file when the thread is gone).
    private func persistThread(_ conversationID: String) {
        if let thread = messages[conversationID], !thread.isEmpty {
            persist(thread, to: threadURL(conversationID))
        } else {
            enqueue(.delete, to: threadURL(conversationID))
        }
    }

    /// Awaits every pending write. Tests and app-background hooks use this.
    func flush() async {
        let chain = writeChain
        _ = await chain?.value
        await writer.flush()
    }

    // MARK: - Contacts

    func contact(for phone: String) -> Contact? {
        contacts.first { $0.phone == phone }
    }

    func addContact(_ c: Contact) {
        guard !contacts.contains(where: { $0.phone == c.phone }) else { return }
        contacts.append(c)
        persistContacts()
    }

    func renameContact(phone: String, newName: String) {
        guard let idx = contacts.firstIndex(where: { $0.phone == phone }) else { return }
        contacts[idx].name = newName
        persistContacts()
    }

    func setProfile(phone: String, profileName: String?, avatarJPEG: Data?) {
        guard let idx = contacts.firstIndex(where: { $0.phone == phone }) else { return }
        var changed = false
        if contacts[idx].profileName != profileName {
            contacts[idx].profileName = profileName
            changed = true
        }
        if let jpeg = avatarJPEG {
            do {
                let filename = try media.saveAvatar(jpeg, phone: phone)
                contacts[idx].avatarFilename = filename
                changed = true
            } catch {
                Log.store.error("avatar write failed: \(String(describing: error), privacy: .public)")
            }
        }
        if changed { persistContacts() }
    }

    /// Removing a contact optionally removes the conversation *and its media* —
    /// the v1 UI promised this and never did it.
    func removeContact(phone: String, deleteMessages: Bool) {
        if let idx = contacts.firstIndex(where: { $0.phone == phone }) {
            media.deleteAvatar(contacts[idx].avatarFilename)
            contacts.remove(at: idx)
            persistContacts()
        }
        if deleteMessages {
            deleteConversation(ConversationStore.conversationID(peer: phone))
        } else {
            recomputeUnread()
        }
    }

    func setBlocked(_ phone: String, _ blocked: Bool) {
        guard let idx = contacts.firstIndex(where: { $0.phone == phone }) else {
            // Allow blocking someone who is not in the address book.
            guard blocked else { return }
            contacts.append(Contact(phone: phone, name: phone, isBlocked: true))
            persistContacts()
            recomputeUnread()
            return
        }
        guard contacts[idx].isBlocked != blocked else { return }
        contacts[idx].isBlocked = blocked
        persistContacts()
        recomputeUnread()
    }

    func isBlocked(_ phone: String) -> Bool {
        contact(for: phone)?.isBlocked ?? false
    }

    func updateLAN(phone: String, ip: String?, port: UInt16?) {
        guard let idx = contacts.firstIndex(where: { $0.phone == phone }) else { return }
        guard contacts[idx].lanIP != ip || contacts[idx].lanPort != port else { return }
        contacts[idx].lanIP = ip
        contacts[idx].lanPort = port
        persistContacts()
    }

    // MARK: - Groups

    func upsertGroup(_ g: ChatGroup) {
        var g = g
        if let idx = groups.firstIndex(where: { $0.id == g.id }) {
            // Group updates arrive from other members; the translate choice
            // is ours and only changes through `setTranslateLanguage`.
            g.translateLanguage = groups[idx].translateLanguage
            g.isArchived = groups[idx].isArchived
            guard groups[idx] != g else { return }
            groups[idx] = g
        } else {
            groups.append(g)
        }
        persistGroups()
        recomputeUnread()
    }

    func group(id: String) -> ChatGroup? {
        groups.first { $0.id == id }
    }

    // MARK: - Per-chat translation

    /// Target language for auto-translating this conversation, or nil when off.
    func translateLanguage(for conversationID: String) -> String? {
        if let gid = ConversationStore.groupID(from: conversationID) {
            return group(id: gid)?.translateLanguage
        }
        return contact(for: conversationID)?.translateLanguage
    }

    func setTranslateLanguage(_ language: String?, for conversationID: String) {
        if let gid = ConversationStore.groupID(from: conversationID) {
            guard let idx = groups.firstIndex(where: { $0.id == gid }),
                  groups[idx].translateLanguage != language else { return }
            groups[idx].translateLanguage = language
            persistGroups()
        } else if let idx = contacts.firstIndex(where: { $0.phone == conversationID }) {
            guard contacts[idx].translateLanguage != language else { return }
            contacts[idx].translateLanguage = language
            persistContacts()
        } else if let language {
            // Someone who messaged us but isn't saved yet.
            var contact = Contact(phone: conversationID, name: conversationID)
            contact.translateLanguage = language
            contacts.append(contact)
            persistContacts()
        }
    }

    // MARK: - Archive

    func isArchived(_ conversationID: String) -> Bool {
        if let gid = ConversationStore.groupID(from: conversationID) {
            return group(id: gid)?.isArchived ?? false
        }
        return contact(for: conversationID)?.isArchived ?? false
    }

    /// Archives or unarchives several conversations with one write per file.
    func setArchived(_ archived: Bool, for conversationIDs: [String]) {
        var contactsChanged = false
        var groupsChanged = false
        let value: Bool? = archived ? true : nil
        for conversationID in conversationIDs {
            if let gid = ConversationStore.groupID(from: conversationID) {
                guard let idx = groups.firstIndex(where: { $0.id == gid }),
                      groups[idx].isArchived != value else { continue }
                groups[idx].isArchived = value
                groupsChanged = true
            } else if let idx = contacts.firstIndex(where: { $0.phone == conversationID }) {
                guard contacts[idx].isArchived != value else { continue }
                contacts[idx].isArchived = value
                contactsChanged = true
            } else if archived {
                var contact = Contact(phone: conversationID, name: conversationID)
                contact.isArchived = true
                contacts.append(contact)
                contactsChanged = true
            }
        }
        if contactsChanged { persistContacts() }
        if groupsChanged { persistGroups() }
    }

    /// Drops every translation in a thread (auto-translate turned off or
    /// switched to another language).
    func clearTranslations(in conversationID: String) {
        guard var thread = messages[conversationID],
              thread.contains(where: { $0.translatedBody != nil }) else { return }
        for i in thread.indices { thread[i].translatedBody = nil }
        messages[conversationID] = thread
        persistThread(conversationID)
    }

    // MARK: - Messages

    @discardableResult
    func appendMessage(_ m: StoredMessage) -> Bool {
        var thread = messages[m.conversationID] ?? []
        guard !thread.contains(where: { $0.id == m.id }) else { return false }
        let idx = thread.firstIndex { $0.timestamp > m.timestamp } ?? thread.endIndex
        thread.insert(m, at: idx)
        messages[m.conversationID] = thread
        refreshUnread(for: m.conversationID)
        persistThread(m.conversationID)
        return true
    }

    /// Status never downgrades; `.failed → .pending` is allowed for manual retry.
    func updateStatus(messageID: String, conversationID: String, to status: MessageStatus) {
        mutate(messageID: messageID, conversationID: conversationID) { msg in
            guard msg.status.canTransition(to: status) else { return false }
            msg.status = status
            return true
        }
    }

    func recordAttempt(messageID: String, conversationID: String) {
        let stamp = now()
        mutate(messageID: messageID, conversationID: conversationID) { msg in
            msg.attempts += 1
            msg.lastAttemptAt = stamp
            return true
        }
    }

    /// Records how a message travelled. A direct delivery wins over a relay
    /// one (a group message may use both; direct is the notable fact).
    func setRoute(_ route: MessageRoute, messageID: String, conversationID: String) {
        mutate(messageID: messageID, conversationID: conversationID) { msg in
            guard msg.route != route, msg.route != .direct else { return false }
            msg.route = route
            return true
        }
    }

    func setTranslation(messageID: String, conversationID: String, text: String?) {
        mutate(messageID: messageID, conversationID: conversationID) { msg in
            guard !msg.isDeleted, msg.translatedBody != text else { return false }
            msg.translatedBody = text
            return true
        }
    }

    /// Honored only when the requester actually sent the message.
    @discardableResult
    func markDeletedForEveryone(messageID: String, conversationID: String, requestedBy phone: String) -> Bool {
        guard let thread = messages[conversationID],
              let msg = thread.first(where: { $0.id == messageID }),
              msg.fromPhone == phone else { return false }
        let filename = msg.imageFilename
        let changed = mutate(messageID: messageID, conversationID: conversationID) { m in
            guard !m.isDeleted else { return false }
            m.isDeleted = true
            m.body = ""
            m.translatedBody = nil
            m.imageFilename = nil
            m.kind = .text
            return true
        }
        if changed { media.deleteImage(filename) }
        return true
    }

    func deleteMessageLocally(messageID: String, conversationID: String) {
        guard var thread = messages[conversationID],
              let idx = thread.firstIndex(where: { $0.id == messageID }) else { return }
        media.deleteImage(thread[idx].imageFilename)
        thread.remove(at: idx)
        messages[conversationID] = thread.isEmpty ? nil : thread
        refreshUnread(for: conversationID)
        persistThread(conversationID)
    }

    @discardableResult
    private func mutate(messageID: String,
                        conversationID: String,
                        _ body: (inout StoredMessage) -> Bool) -> Bool {
        guard var thread = messages[conversationID],
              let idx = thread.firstIndex(where: { $0.id == messageID }) else { return false }
        var msg = thread[idx]
        guard body(&msg) else { return false }
        thread[idx] = msg
        messages[conversationID] = thread
        refreshUnread(for: conversationID)
        persistThread(conversationID)
        return true
    }

    // MARK: - Reading threads

    func thread(_ conversationID: String) -> [StoredMessage] {
        messages[conversationID] ?? []
    }

    func lastMessage(_ conversationID: String) -> StoredMessage? {
        messages[conversationID]?.last
    }

    func pendingOutgoing() -> [StoredMessage] {
        messages.values
            .flatMap { $0 }
            .filter { $0.isFromMe && $0.status == .pending && !$0.isDeleted }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Incoming, non-deleted text messages from `phone`, oldest-first, most recent `limit`.
    func recentMessages(with phone: String, limit: Int) -> [StoredMessage] {
        guard limit > 0 else { return [] }
        let all = messages.values
            .flatMap { $0 }
            .filter { !$0.isFromMe && !$0.isDeleted && $0.kind == .text && $0.fromPhone == phone }
            .sorted { $0.timestamp < $1.timestamp }
        return all.count > limit ? Array(all.suffix(limit)) : all
    }

    // MARK: - Unread

    func unreadCount(_ conversationID: String) -> Int {
        unreadCounts[conversationID] ?? 0
    }

    /// Marks every incoming message read; returns the ones that changed so the
    /// caller can send read receipts for exactly those.
    @discardableResult
    func markConversationRead(_ conversationID: String) -> [StoredMessage] {
        guard var thread = messages[conversationID] else { return [] }
        var newlyRead: [StoredMessage] = []
        for i in thread.indices where thread[i].isUnreadIncoming {
            thread[i].isRead = true
            newlyRead.append(thread[i])
        }
        guard !newlyRead.isEmpty else { return [] }
        messages[conversationID] = thread
        refreshUnread(for: conversationID)
        persistThread(conversationID)
        return newlyRead
    }

    private func refreshUnread(for conversationID: String) {
        let count = (messages[conversationID] ?? []).reduce(into: 0) { $0 += $1.isUnreadIncoming ? 1 : 0 }
        if count == 0 { unreadCounts.removeValue(forKey: conversationID) }
        else { unreadCounts[conversationID] = count }
        recomputeTotalUnread()
    }

    private func recomputeUnread() {
        unreadCounts.removeAll(keepingCapacity: true)
        for (cid, thread) in messages {
            let count = thread.reduce(into: 0) { $0 += $1.isUnreadIncoming ? 1 : 0 }
            if count > 0 { unreadCounts[cid] = count }
        }
        recomputeTotalUnread()
    }

    /// Blocked contacts and inactive groups never contribute to the badge.
    private func recomputeTotalUnread() {
        var total = 0
        for (cid, count) in unreadCounts {
            if let gid = ConversationStore.groupID(from: cid) {
                if let g = group(id: gid), !g.isActive { continue }
            } else if isBlocked(cid) {
                continue
            }
            total += count
        }
        if totalUnreadCount != total { totalUnreadCount = total }
    }

    // MARK: - Conversation lifecycle

    func deleteConversation(_ conversationID: String) {
        if let thread = messages[conversationID] {
            for m in thread { media.deleteImage(m.imageFilename) }
        }
        messages.removeValue(forKey: conversationID)
        unreadCounts.removeValue(forKey: conversationID)
        recomputeTotalUnread()
        enqueue(.delete, to: threadURL(conversationID))
    }

    /// Number change: moves the thread and the contact onto the new phone,
    /// merging into an existing conversation when one is already there.
    func renameConversation(from oldPhone: String, to newPhone: String) {
        guard oldPhone != newPhone, !oldPhone.isEmpty, !newPhone.isEmpty else { return }
        let oldCID = ConversationStore.conversationID(peer: oldPhone)
        let newCID = ConversationStore.conversationID(peer: newPhone)

        // Contact
        if let oldIdx = contacts.firstIndex(where: { $0.phone == oldPhone }) {
            let old = contacts[oldIdx]
            contacts.remove(at: oldIdx)
            if let newIdx = contacts.firstIndex(where: { $0.phone == newPhone }) {
                var merged = contacts[newIdx]
                if merged.name.isEmpty || merged.name == newPhone { merged.name = old.name }
                merged.profileName = merged.profileName ?? old.profileName
                merged.avatarFilename = merged.avatarFilename ?? old.avatarFilename
                merged.isBlocked = merged.isBlocked || old.isBlocked
                merged.translateLanguage = merged.translateLanguage ?? old.translateLanguage
                merged.isArchived = merged.isArchived ?? old.isArchived
                merged.addedAt = min(merged.addedAt, old.addedAt)
                contacts[newIdx] = merged
            } else {
                var moved = old
                moved.phone = newPhone
                if moved.name == oldPhone { moved.name = newPhone }
                contacts.append(moved)
            }
            persistContacts()
        }

        // Thread
        if let oldThread = messages[oldCID] {
            var merged = messages[newCID] ?? []
            var known = Set(merged.map(\.id))
            for m in oldThread where known.insert(m.id).inserted {
                merged.append(m.remapped(toConversation: newCID, replacing: oldPhone, with: newPhone))
            }
            merged.sort { $0.timestamp < $1.timestamp }
            messages[newCID] = merged
            messages.removeValue(forKey: oldCID)
            unreadCounts.removeValue(forKey: oldCID)
            enqueue(.delete, to: threadURL(oldCID))
            refreshUnread(for: newCID)
            persistThread(newCID)
        } else {
            recomputeTotalUnread()
        }
    }

    // MARK: - Media

    /// Writes a JPEG for a message and returns its filename.
    func saveImage(_ data: Data, id: String) throws -> String {
        try media.saveImage(data, id: id)
    }

    func imageURL(_ filename: String) -> URL {
        media.imageURL(filename)
    }

    /// Avatars live in their own directory (filename = SHA-256 of the phone).
    func avatarURL(_ filename: String) -> URL {
        media.avatarURL(filename)
    }

    // MARK: - Replay / seen envelope IDs

    func hasSeenEnvelope(_ id: String) -> Bool {
        seenEnvelopes[id] != nil
    }

    func recordSeenEnvelope(_ id: String) {
        guard seenEnvelopes[id] == nil else { return }
        seenEnvelopes[id] = Int64(now().timeIntervalSince1970)
        if !pruneSeen(persist: false) { persistSeen() }
    }

    /// Drops entries older than 30 days and caps the set. Returns true if it persisted.
    @discardableResult
    private func pruneSeen(persist shouldPersist: Bool) -> Bool {
        let cutoff = Int64(now().addingTimeInterval(-Self.seenTTL).timeIntervalSince1970)
        let before = seenEnvelopes.count
        seenEnvelopes = seenEnvelopes.filter { $0.value >= cutoff }
        if seenEnvelopes.count > Self.seenCap {
            let keep = seenEnvelopes
                .sorted { $0.value > $1.value }
                .prefix(Self.seenCap)
            seenEnvelopes = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let pruned = seenEnvelopes.count != before
        if pruned || shouldPersist { persistSeen() }
        return pruned
    }

    // MARK: - Wipe

    /// Account deletion: cancel queued writes, remove the directory, reset state,
    /// and clear every legacy UserDefaults key.
    func wipeAll() {
        let writer = self.writer
        let dir = directory
        let previous = writeChain
        writeChain = Task { @MainActor in
            _ = await previous?.value          // let in-flight work settle, then blow it all away
            await writer.wipe(directory: dir)
        }

        contacts = []
        groups = []
        messages = [:]
        unreadCounts = [:]
        seenEnvelopes = [:]
        totalUnreadCount = 0

        if let defaults = legacyDefaults {
            LegacyMigration.removeLegacyKeys(from: defaults)
            defaults.removeObject(forKey: LegacyMigration.phoneKey)
        }
    }
}
