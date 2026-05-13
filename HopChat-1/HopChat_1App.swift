//
//  HopChat_1App.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 25/02/2026.
//

import SwiftUI
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Keep the TCP listener alive when the app moves to background.
    // The `voip` background mode in Info.plist is the primary mechanism;
    // the background task token here prevents surprise expiration during
    // the transition window.
    func applicationDidEnterBackground(_ application: UIApplication) {
        bgTask = application.beginBackgroundTask(withName: "hopchat.keepalive") { [weak self] in
            application.endBackgroundTask(self?.bgTask ?? .invalid)
            self?.bgTask = .invalid
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // Tap on a notification → navigate to the conversation
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        if let phone = response.notification.request.content.userInfo["phone"] as? String {
            NotificationCenter.default.post(name: .openChat, object: nil,
                                            userInfo: ["phone": phone])
        }
        completionHandler()
    }

    // Show banner + play sound even when app is in the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct HopChat_1App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
