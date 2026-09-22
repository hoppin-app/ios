//
//  ChatPayload.swift
//  HopChat-1
//
//  Design Contract §4 — the plaintext that lives inside an Envelope's
//  ciphertext. Never leaves the device unsealed.
//

import Foundation

nonisolated struct ChatPayload: Codable, Equatable {

    enum Kind: String, Codable {
        case text
        case image
        case deliveryReceipt
        case readReceipt
        case typing
        case deleteForEveryone
        case profile
        case groupCreate
        case groupUpdate
        case groupText
        case groupImage
        case groupLeave
        case numberChange
    }

    var kind: Kind
    var text: String?
    /// ≤ 600 KB decoded, ≤ 1600 px long edge.
    var imageJPEGBase64: String?
    /// Receipt / deleteForEveryone targets.
    var refIDs: [String]?
    var groupID: String?
    var groupName: String?
    var groupMembers: [String]?
    var groupAdmins: [String]?
    /// Profile broadcast.
    var displayName: String?
    /// Profile avatar, ≤ 64 KB, 256 px.
    var avatarJPEGBase64: String?
    /// Number change.
    var newPhone: String?
    /// Number change — must carry the same signing key as the sender's cert.
    var newCertificate: String?
    /// Text/image: id of the message being replied to.
    var replyToID: String?
    /// Sender clock, unix seconds.
    var sentAt: Int64

    init(kind: Kind,
         text: String? = nil,
         imageJPEGBase64: String? = nil,
         refIDs: [String]? = nil,
         groupID: String? = nil,
         groupName: String? = nil,
         groupMembers: [String]? = nil,
         groupAdmins: [String]? = nil,
         displayName: String? = nil,
         avatarJPEGBase64: String? = nil,
         newPhone: String? = nil,
         newCertificate: String? = nil,
         replyToID: String? = nil,
         sentAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.kind = kind
        self.text = text
        self.imageJPEGBase64 = imageJPEGBase64
        self.refIDs = refIDs
        self.groupID = groupID
        self.groupName = groupName
        self.groupMembers = groupMembers
        self.groupAdmins = groupAdmins
        self.displayName = displayName
        self.avatarJPEGBase64 = avatarJPEGBase64
        self.newPhone = newPhone
        self.newCertificate = newCertificate
        self.replyToID = replyToID
        self.sentAt = sentAt
    }

    // MARK: - Coding

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> ChatPayload? {
        try? JSONDecoder().decode(ChatPayload.self, from: data)
    }

    // MARK: - Classification

    /// Receipts and typing indicators are never stored as messages and never
    /// generate receipts of their own (contract §4).
    var isTransient: Bool {
        switch kind {
        case .deliveryReceipt, .readReceipt, .typing: return true
        default: return false
        }
    }

    /// Payload kinds that are only ever sent over an authenticated LAN link.
    var isLANOnly: Bool { kind == .typing }

    /// What the Bluetooth mesh will carry (contract §9): text, receipts,
    /// delete-for-everyone and profile names. Photos are far too big for a
    /// hop-by-hop radio, and typing indicators stay on the LAN.
    var isMeshEligible: Bool {
        switch kind {
        case .image, .groupImage, .typing: return false
        default: return true
        }
    }

    /// Kinds that result in a stored, user-visible message.
    var isStoredMessage: Bool {
        switch kind {
        case .text, .image, .groupText, .groupImage: return true
        default: return false
        }
    }

    /// Group payloads carry a `groupID` and are authorised against the
    /// stored membership (contract §4).
    var isGroupPayload: Bool {
        switch kind {
        case .groupCreate, .groupUpdate, .groupText, .groupImage, .groupLeave: return true
        default: return false
        }
    }

    // MARK: - Limits (contract §4)

    static let maxImageBytes = 600 * 1024
    static let maxAvatarBytes = 64 * 1024

    /// Structural sanity check applied before a payload is acted on.
    var isWellFormed: Bool {
        switch kind {
        case .text, .groupText:
            guard let t = text, !t.isEmpty, t.utf8.count <= 64 * 1024 else { return false }
        case .image, .groupImage:
            guard let b64 = imageJPEGBase64,
                  let data = Data(base64Encoded: b64),
                  !data.isEmpty,
                  data.count <= ChatPayload.maxImageBytes else { return false }
        case .deliveryReceipt, .readReceipt, .deleteForEveryone:
            guard let ids = refIDs, !ids.isEmpty, ids.count <= 200 else { return false }
        case .typing:
            break
        case .profile:
            if let b64 = avatarJPEGBase64 {
                guard let data = Data(base64Encoded: b64),
                      data.count <= ChatPayload.maxAvatarBytes else { return false }
            }
        case .groupCreate, .groupUpdate:
            guard let members = groupMembers,
                  !members.isEmpty,
                  members.count <= AppConfig.maxGroupMembers,
                  groupID != nil else { return false }
        case .groupLeave:
            guard groupID != nil else { return false }
        case .numberChange:
            guard let p = newPhone, !p.isEmpty, newCertificate != nil else { return false }
        }
        if let replyToID, replyToID.isEmpty || replyToID.utf8.count > 64 { return false }
        if isGroupPayload && groupID == nil { return false }
        return true
    }
}
