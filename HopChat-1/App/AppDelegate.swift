//
//  AppDelegate.swift
//  HopChat-1
//
//  Launch-time wiring and the notification-center delegate.
//
//  Two things must happen before the app finishes launching:
//    • the BGTaskScheduler handler is registered (iOS refuses a late
//      registration for `com.hopchat.relay-fetch`),
//    • the UNUserNotificationCenter delegate is installed, so a tap on a
//      notification that launched the app is still routed.
//

import UIKit
import UserNotifications
import os

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        // UI tests launch with -UITestResetState to start from a clean install.
        // Debug-only: a launch argument must never be able to wipe a user's data.
        if ProcessInfo.processInfo.arguments.contains("-UITestResetState") {
            KademliaService.shared.wipeLocalState()
            Log.app.info("UI test reset: local state wiped")
        }
        #endif
        AppConfig.registerDefaults()
        BackgroundRefresh.register()
        UNUserNotificationCenter.current().delegate = self
        Log.app.info("HopChat \(AppConfig.appVersion, privacy: .public) launched")
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground presentation, honouring `hopchat.notifications.*`.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: AppConfig.Keys.notificationsEnabled) == nil
            ? true : defaults.bool(forKey: AppConfig.Keys.notificationsEnabled)
        guard enabled else {
            completionHandler([])
            return
        }
        let withSound = defaults.object(forKey: AppConfig.Keys.notificationsSound) == nil
            ? true : defaults.bool(forKey: AppConfig.Keys.notificationsSound)
        completionHandler(withSound ? [.banner, .sound] : [.banner])
    }

    /// A tap opens the conversation. The key is `conversationID` (v1 used
    /// `phone`); group conversations look like `group:<uuid>`.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let conversationID = response.notification.request.content.userInfo["conversationID"] as? String,
           !conversationID.isEmpty {
            NotificationCenter.default.post(name: .openChat,
                                            object: nil,
                                            userInfo: ["conversationID": conversationID])
        }
        completionHandler()
    }
}
