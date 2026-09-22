//
//  NotificationService.swift
//  HopChat-1
//
//  Local notifications for incoming messages. Honours the notification
//  settings from contract §6 and never leaks message content when previews
//  are disabled.
//

import Foundation
import UserNotifications
import UIKit
import os

extension Notification.Name {
    /// Posted when the user taps a message notification.
    /// `userInfo["conversationID"] as? String`
    static let openChat = Notification.Name("hoppin.openChat")
}

@MainActor
final class NotificationService {

    static let shared = NotificationService()

    /// Set by the chat view while a conversation is on screen. No notification
    /// is posted for that conversation while the app is active.
    var activeConversationID: String?

    init() {}

    // MARK: - Permission

    @discardableResult
    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Posting

    func postIncoming(conversationID: String, title: String, body: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppConfig.Keys.notificationsEnabled) == nil
                || defaults.bool(forKey: AppConfig.Keys.notificationsEnabled) else { return }

        // Don't interrupt the user while they are reading that very thread.
        if UIApplication.shared.applicationState == .active,
           activeConversationID == conversationID {
            return
        }

        let showPreview = defaults.object(forKey: AppConfig.Keys.notificationsPreview) == nil
            ? true : defaults.bool(forKey: AppConfig.Keys.notificationsPreview)
        let withSound = defaults.object(forKey: AppConfig.Keys.notificationsSound) == nil
            ? true : defaults.bool(forKey: AppConfig.Keys.notificationsSound)

        let content = UNMutableNotificationContent()
        content.title = showPreview ? title : "hoppin"
        content.body = showPreview ? body : String(localized: "New message")
        if withSound { content.sound = .default }
        content.threadIdentifier = conversationID
        content.userInfo = ["conversationID": conversationID]

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.error("Failed to post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Badge

    func clearBadge() {
        setBadge(0)
    }

    func setBadge(_ n: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, n)) { error in
            if let error {
                Log.app.error("Failed to set badge: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Removes delivered notifications for one conversation (called when the
    /// user opens it).
    func clearNotifications(for conversationID: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == conversationID }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
