//
//  NotificationService.swift
//  HopChat-1
//

import UserNotifications
import UIKit

extension Notification.Name {
    static let openChat = Notification.Name("hopchat.openChat")
}

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(from senderPhone: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        let name = ConversationStore.shared.contact(for: senderPhone)?.name ?? senderPhone
        content.title = name
        content.body = body
        content.sound = .default
        content.threadIdentifier = senderPhone
        content.userInfo = ["phone": senderPhone]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}
