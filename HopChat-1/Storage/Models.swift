//
//  Models.swift
//  HopChat-1
//
//  Storage value types. All are `nonisolated` Codable/Hashable/Sendable so they
//  can cross actor boundaries freely (the target defaults to MainActor isolation).
//

import Foundation

// MARK: - Contact

nonisolated struct Contact: Codable, Identifiable, Hashable, Sendable {
    var id: String { phone }
    var phone: String
    var name: String
    var addedAt: Date
    var isBlocked: Bool = false
    var avatarFilename: String? = nil
    /// Display name the contact announced via a `profile` payload.
    var profileName: String? = nil
    var lanIP: String? = nil
    var lanPort: UInt16? = nil
    /// Auto-translate incoming messages in this chat into this language
    /// code (e.g. "en"); nil = off. Local-only, never sent.
    var translateLanguage: String? = nil
    /// Hidden from the main chat list (local-only).
    var isArchived: Bool? = nil

    init(phone: String,
         name: String,
         addedAt: Date = Date(),
         isBlocked: Bool = false,
         avatarFilename: String? = nil,
         profileName: String? = nil,
         lanIP: String? = nil,
         lanPort: UInt16? = nil) {
        self.phone = phone
        self.name = name
        self.addedAt = addedAt
        self.isBlocked = isBlocked
        self.avatarFilename = avatarFilename
        self.profileName = profileName
        self.lanIP = lanIP
        self.lanPort = lanPort
    }

    /// Name shown in the UI: user-given name wins, then announced profile name, then the phone.
    var displayName: String {
        if !name.isEmpty && name != phone { return name }
        if let p = profileName, !p.isEmpty { return p }
        return phone
    }
}

// MARK: - Group

nonisolated struct ChatGroup: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var members: [String]
    var admins: [String]
    var createdAt: Date
    var isActive: Bool = true
    /// Local-only auto-translate target for this group chat; nil = off.
    var translateLanguage: String? = nil
    /// Hidden from the main chat list (local-only).
    var isArchived: Bool? = nil

    init(id: String,
         name: String,
         members: [String],
         admins: [String],
         createdAt: Date = Date(),
         isActive: Bool = true) {
        self.id = id
        self.name = name
        self.members = members
        self.admins = admins
        self.createdAt = createdAt
        self.isActive = isActive
    }
}

// MARK: - Message status / kind

nonisolated enum MessageStatus: Int, Codable, Comparable, Sendable {
    case pending = 0
    case sent = 1
    case delivered = 2
    case read = 3
    case failed = 4

    nonisolated static func < (lhs: MessageStatus, rhs: MessageStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Delivery progress rank used for monotonicity. `.failed` is *not* progress —
    /// it ranks with `.pending` so a failed message can still be marked sent later.
    var progress: Int {
        switch self {
        case .pending, .failed: return 0
        case .sent: return 1
        case .delivered: return 2
        case .read: return 3
        }
    }

    /// Status transitions never downgrade delivery progress. The only exceptions are
    /// `.pending → .failed` (give-up) and `.failed → .pending` (manual retry).
    func canTransition(to new: MessageStatus) -> Bool {
        if self == new { return false }
        switch (self, new) {
        case (.failed, .pending): return true      // manual retry
        case (.pending, .failed): return true      // gave up
        case (_, .failed): return false            // sent/delivered/read never fail backwards
        case (.failed, _): return true             // late ack after a failure
        default: return new.progress > self.progress
        }
    }
}

/// How a message travelled. Local-only; set when it was sent or received.
nonisolated enum MessageRoute: String, Codable, Sendable {
    /// Phone to phone on the local network (Wi-Fi or peer-to-peer Wi-Fi).
    case direct
    /// Through the encrypted relay.
    case relay
    /// Hop by hop over the Bluetooth mesh, with no internet at all.
    case mesh

    /// Which route is the notable one when a message used more than one — a
    /// group fan-out that went partly direct, or a mesh copy the relay later
    /// carried as well. Higher wins; a message's route never downgrades.
    var precedence: Int {
        switch self {
        case .direct: return 3
        case .mesh:   return 2
        case .relay:  return 1
        }
    }
}

nonisolated enum MessageKind: String, Codable, Sendable {
    case text, image, system
}

// MARK: - Stored message

nonisolated struct StoredMessage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let conversationID: String
    let fromPhone: String
    let toPhone: String
    var kind: MessageKind
    var body: String
    var imageFilename: String?
    let timestamp: Date
    var status: MessageStatus
    let isFromMe: Bool
    var isRead: Bool
    var translatedBody: String?
    var isDeleted: Bool = false
    var attempts: Int = 0
    var lastAttemptAt: Date? = nil
    /// Id of the message this one replies to, in the same conversation.
    var replyToID: String? = nil
    /// How it travelled (nil until sent, and for messages from older versions).
    var route: MessageRoute? = nil

    init(id: String = UUID().uuidString,
         conversationID: String,
         fromPhone: String,
         toPhone: String,
         kind: MessageKind = .text,
         body: String,
         imageFilename: String? = nil,
         timestamp: Date = Date(),
         status: MessageStatus = .pending,
         isFromMe: Bool,
         isRead: Bool = true,
         translatedBody: String? = nil,
         isDeleted: Bool = false,
         attempts: Int = 0,
         lastAttemptAt: Date? = nil,
         replyToID: String? = nil,
         route: MessageRoute? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.fromPhone = fromPhone
        self.toPhone = toPhone
        self.kind = kind
        self.body = body
        self.imageFilename = imageFilename
        self.timestamp = timestamp
        self.status = status
        self.isFromMe = isFromMe
        self.isRead = isRead
        self.translatedBody = translatedBody
        self.isDeleted = isDeleted
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.replyToID = replyToID
        self.route = route
    }

    /// Counts toward an unread badge.
    var isUnreadIncoming: Bool { !isFromMe && !isRead && !isDeleted }

    /// Copy of this message re-homed onto a new conversation, remapping any
    /// occurrence of `oldPhone` in the participants (used by `renameConversation`).
    func remapped(toConversation newConversationID: String,
                  replacing oldPhone: String,
                  with newPhone: String) -> StoredMessage {
        StoredMessage(id: id,
                      conversationID: newConversationID,
                      fromPhone: fromPhone == oldPhone ? newPhone : fromPhone,
                      toPhone: toPhone == oldPhone ? newPhone : toPhone,
                      kind: kind,
                      body: body,
                      imageFilename: imageFilename,
                      timestamp: timestamp,
                      status: status,
                      isFromMe: isFromMe,
                      isRead: isRead,
                      translatedBody: translatedBody,
                      isDeleted: isDeleted,
                      attempts: attempts,
                      lastAttemptAt: lastAttemptAt,
                      replyToID: replyToID,
                      route: route)
    }
}

// MARK: - File protection

nonisolated enum StorageProtection {
    /// Atomic write + data protection (no-op outside iOS-family platforms, so the
    /// same code path is exercised by the macOS test harness).
    static let writingOptions: Data.WritingOptions = {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }()

    /// Directory attributes matching the file protection class.
    static var directoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return [:]
        #endif
    }
}
