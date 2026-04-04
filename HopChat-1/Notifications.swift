//
//  Notification.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//

import Foundation

extension Notifications.Name {
    /// Posted when another peer sends a connection request.
    /// userInfo: ["phone": String, "ip": String, "port": UInt16]
    static let newContactRequest = Notification.Name("hopchat.newContactRequest")

    /// Posted when a chat message arrives from a peer.
    /// userInfo: ["phone": String, "body": String, "chatID": String, "timestamp": Date]
    static let incomingChatMessage = Notification.Name("hopchat.incomingChatMessage")
}
