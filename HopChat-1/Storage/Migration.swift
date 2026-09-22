//
//  Migration.swift
//  HopChat-1
//
//  One-time import of the v1 UserDefaults store into the v2 file store.
//  Tolerates corrupt blobs (a bad value is skipped, never fatal) and is
//  idempotent: the legacy keys are removed only after the new files are on disk,
//  and migration is skipped entirely once v2 data exists.
//

import Foundation
import os

nonisolated enum LegacyMigration {

    // MARK: - Keys

    static let contactsKey = "hoppin.contacts.v1"
    static let messagesKey = "hoppin.messages.v1"
    static let phoneKey    = "hoppin.phone"          // NOT removed here: the network layer consumes it
    /// Removed together with the store keys once migration succeeds.
    static let obsoleteKeys = [
        "hoppin.routingTable.v1",
        "hoppin.peerKeys.agreement.v1",
        "hoppin.peerKeys.signing.v1"
    ]

    static let threadSeparator = "↔︎"

    // MARK: - Legacy shapes

    private struct OldContact: Decodable {
        let phone: String
        let name: String?
        let ip: String?
        let port: UInt16?
        let addedAt: Date?
    }

    private struct OldStoredMessage: Decodable {
        let id: String
        let fromPhone: String
        let toPhone: String
        let body: String
        let timestamp: Date
        let delivered: Bool?
        let isFromMe: Bool
        let translatedBody: String?
        let isRead: Bool?
    }

    struct Imported: Sendable {
        var contacts: [Contact] = []
        /// conversationID (peer phone) → messages sorted by timestamp
        var threads: [String: [StoredMessage]] = [:]
        var isEmpty: Bool { contacts.isEmpty && threads.isEmpty }
    }

    // MARK: - API

    static func hasLegacyData(in defaults: UserDefaults) -> Bool {
        defaults.data(forKey: contactsKey) != nil || defaults.data(forKey: messagesKey) != nil
    }

    /// Decodes whatever is readable out of the legacy defaults. Never throws.
    static func importLegacy(from defaults: UserDefaults) -> Imported {
        var result = Imported()
        let decoder = JSONDecoder()
        let myPhone = defaults.string(forKey: phoneKey)

        // Contacts — old phone strings may not be E.164; keep them verbatim.
        if let data = defaults.data(forKey: contactsKey) {
            if let old = try? decoder.decode([OldContact].self, from: data) {
                for c in old where !c.phone.isEmpty {
                    guard !result.contacts.contains(where: { $0.phone == c.phone }) else { continue }
                    result.contacts.append(
                        Contact(phone: c.phone,
                                name: (c.name?.isEmpty == false ? c.name! : c.phone),
                                addedAt: c.addedAt ?? Date(),
                                lanIP: (c.ip?.isEmpty == false) ? c.ip : nil,
                                lanPort: (c.port ?? 0) == 0 ? nil : c.port)
                    )
                }
            } else {
                Log.store.error("legacy contacts blob unreadable; skipping")
            }
        }

        // Messages — keyed "a↔︎b".
        if let data = defaults.data(forKey: messagesKey) {
            if let old = try? decoder.decode([String: [OldStoredMessage]].self, from: data) {
                for (threadKey, oldMessages) in old {
                    guard !oldMessages.isEmpty else { continue }
                    guard let peer = peerPhone(threadKey: threadKey,
                                               myPhone: myPhone,
                                               sample: oldMessages[0]) else { continue }
                    var converted: [StoredMessage] = []
                    var seenIDs = Set<String>()
                    for m in oldMessages {
                        guard !m.id.isEmpty, seenIDs.insert(m.id).inserted else { continue }
                        converted.append(
                            StoredMessage(id: m.id,
                                          conversationID: peer,
                                          fromPhone: m.fromPhone,
                                          toPhone: m.toPhone,
                                          kind: .text,
                                          body: m.body,
                                          timestamp: m.timestamp,
                                          status: (m.delivered ?? false) ? .delivered : .pending,
                                          isFromMe: m.isFromMe,
                                          isRead: m.isRead ?? true,
                                          translatedBody: m.translatedBody)
                        )
                    }
                    guard !converted.isEmpty else { continue }
                    converted.sort { $0.timestamp < $1.timestamp }
                    var existing = result.threads[peer] ?? []
                    let known = Set(existing.map(\.id))
                    existing.append(contentsOf: converted.filter { !known.contains($0.id) })
                    existing.sort { $0.timestamp < $1.timestamp }
                    result.threads[peer] = existing
                }
            } else {
                Log.store.error("legacy messages blob unreadable; skipping")
            }
        }

        // Every conversation should have a contact row so the chat list is not empty.
        for peer in result.threads.keys where !result.contacts.contains(where: { $0.phone == peer }) {
            result.contacts.append(Contact(phone: peer, name: peer))
        }

        return result
    }

    /// Maps a legacy `"a↔︎b"` thread key to the peer phone (the one that is not mine).
    static func peerPhone(threadKey: String, myPhone: String?) -> String? {
        peerPhone(threadKey: threadKey, myPhone: myPhone, sample: nil)
    }

    private static func peerPhone(threadKey: String,
                                  myPhone: String?,
                                  sample: OldStoredMessage?) -> String? {
        let parts = threadKey.components(separatedBy: threadSeparator).filter { !$0.isEmpty }
        if parts.count == 2 {
            if let mine = myPhone, !mine.isEmpty {
                if parts[0] == mine, parts[1] != mine { return parts[1] }
                if parts[1] == mine, parts[0] != mine { return parts[0] }
            }
            // No usable local phone: infer from the message direction.
            if let s = sample {
                let candidate = s.isFromMe ? s.toPhone : s.fromPhone
                if parts.contains(candidate) { return candidate }
            }
            return parts[0]
        }
        // Key was already a bare phone (or something unexpected but non-empty).
        if parts.count == 1 { return parts[0] }
        if let s = sample { return s.isFromMe ? s.toPhone : s.fromPhone }
        return nil
    }

    /// Called only after the v2 files are safely written.
    static func removeLegacyKeys(from defaults: UserDefaults) {
        defaults.removeObject(forKey: contactsKey)
        defaults.removeObject(forKey: messagesKey)
        for key in obsoleteKeys { defaults.removeObject(forKey: key) }
        // `hoppin.phone` is intentionally left for the network layer to consume.
    }
}
