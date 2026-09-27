//
//  PushRegistration.swift
//  HopChat-1
//
//  The device half of push: getting an APNs token from iOS and telling the
//  relay about it — or telling the relay to forget it.
//
//  What the relay can do with the token is deliberately small. Its push
//  payload carries no sender and no text, only `mutable-content`, so all Apple
//  and the relay learn is that *something* arrived for this account. The real
//  sender and message are filled in on the device.
//
//  Registration is conditional on two things, re-checked every time:
//    • the in-app "Message notifications" switch, and
//    • the iOS permission.
//  Turning either off clears the token on the relay, so the phone stops being
//  woken at all rather than being woken for a notification that is suppressed.
//

import Foundation
import UIKit
import UserNotifications
import os

@MainActor
final class PushRegistration {

    static let shared = PushRegistration()

    /// `token|phone` last accepted by the relay, so an unchanged token isn't
    /// re-sent on every launch. Cleared with the rest of `hoppin.*` on account
    /// deletion.
    private static let memoKey = "hoppin.push.registered"

    private let defaults: UserDefaults
    private let service: KademliaService
    private var inFlight = false

    init(defaults: UserDefaults = .standard, service: KademliaService = .shared) {
        self.defaults = defaults
        self.service = service
    }

    /// Whether the relay currently holds a token for this install. Read by the
    /// "Your data" screen, which must not claim less than the relay actually
    /// has.
    var isRegisteredWithRelay: Bool {
        defaults.string(forKey: Self.memoKey) != nil
    }

    // MARK: - Entry points

    /// Asks iOS for a device token when the user has agreed to notifications,
    /// and withdraws the old one when they have not. Safe to call on every
    /// launch and whenever the notification settings change.
    func refresh() async {
        guard service.isRegistered else { return }

        let enabled = defaults.object(forKey: AppConfig.Keys.notificationsEnabled) == nil
            ? true : defaults.bool(forKey: AppConfig.Keys.notificationsEnabled)
        guard enabled, await isAuthorized() else {
            await withdraw()
            return
        }

        // iOS answers on the app delegate, not here: the token arrives in
        // `didRegister(deviceToken:)` below, which may be several seconds later
        // or never (no network, no entitlement, Simulator without a paired Mac
        // push service).
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// iOS handed us a token. Send it on if the relay hasn't got this one yet.
    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }

        let memo = "\(token)|\(service.myPhone)"
        guard defaults.string(forKey: Self.memoKey) != memo, !inFlight else { return }

        inFlight = true
        Task {
            let sandbox = APNsEnvironment.isSandbox
            if await service.registerPushToken(token, sandbox: sandbox) {
                defaults.set(memo, forKey: Self.memoKey)
            }
            inFlight = false
        }
    }

    /// iOS could not produce a token. Nothing to tell the user: without push
    /// the app still fetches on launch and on background refresh, which is
    /// exactly how it behaved before push existed.
    func didFailToRegister(_ error: Error) {
        Log.app.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// A push woke the app. The payload says nothing, so the only sensible
    /// response is to go and look in the mailbox.
    func handleRemoteNotification() async -> Bool {
        await service.performBackgroundFetch()
    }

    // MARK: - Withdrawing

    /// Stops iOS sending us a token and asks the relay to forget the one it
    /// has. Both halves matter: unregistering alone would leave the relay
    /// pushing to a token Apple no longer routes.
    private func withdraw() async {
        let hadToken = defaults.string(forKey: Self.memoKey) != nil
        UIApplication.shared.unregisterForRemoteNotifications()
        guard hadToken else { return }
        if await service.clearPushToken() {
            defaults.removeObject(forKey: Self.memoKey)
        }
    }

    private func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

// MARK: - Which APNs host the relay should use

/// Whether this build's tokens belong to Apple's sandbox.
///
/// A token minted against the development gateway is rejected by the
/// production one with `BadDeviceToken` and nothing else — no hint as to why.
/// Rather than guess from the build configuration (a Release build installed
/// straight from Xcode is still a development token), read what the signed
/// profile actually says.
enum APNsEnvironment {

    static let isSandbox: Bool = {
        switch apsEnvironment() {
        case "development": return true
        case "production": return false
        default:
            // No profile: the Simulator, or an App Store build where the value
            // was stripped. Trust the build configuration as a last resort.
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
    }()

    /// `aps-environment` out of `embedded.mobileprovision`. The file is a
    /// CMS-signed blob with a plain XML plist in the middle of it; the
    /// signature is Apple's business, and all we need is one string.
    private static func apsEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let blob = try? Data(contentsOf: url),
              let text = String(data: blob, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }

        let plist = String(text[start.lowerBound..<end.upperBound])
        guard let data = plist.data(using: .isoLatin1),
              let root = try? PropertyListSerialization.propertyList(from: data,
                                                                    format: nil) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any] else { return nil }

        return entitlements["aps-environment"] as? String
    }
}
