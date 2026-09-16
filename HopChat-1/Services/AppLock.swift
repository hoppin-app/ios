//
//  AppLock.swift
//  HopChat-1
//
//  Face ID / Touch ID / passcode lock for the whole app (contract §0, §6).
//
//  Design rules:
//  * `LAPolicy.deviceOwnerAuthentication` is used everywhere, so the device
//    passcode is always available when biometry fails, is unenrolled or is
//    locked out.
//  * The app is never left locked with no way forward: if the device has no
//    passcode at all there is nothing to authenticate against, so the lock is
//    turned off rather than trapping the user.
//  * Turning the lock *on* requires a successful authentication first.
//

import Combine
import Foundation
import LocalAuthentication
import os

@MainActor
final class AppLock: ObservableObject {

    static let shared = AppLock()

    // MARK: - State

    /// `true` while the unlock screen should cover the app.
    @Published private(set) var isLocked: Bool = false

    /// Human-readable explanation of the last failed authentication, for the
    /// unlock screen. `nil` when there is nothing to report.
    @Published private(set) var lastFailureMessage: String?

    /// `true` while an `evaluatePolicy` call is in flight — the unlock screen
    /// uses this to avoid stacking prompts.
    @Published private(set) var isAuthenticating: Bool = false

    private let defaults: UserDefaults
    private var backgroundedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A cold launch with the lock enabled starts locked.
        self.isLocked = defaults.bool(forKey: AppConfig.Keys.appLockEnabled)
    }

    // MARK: - Settings

    /// Persisted to `hopchat.appLock.enabled`.
    ///
    /// Prefer ``setEnabled(_:)`` from UI: enabling must be gated on a
    /// successful authentication. The plain setter exists for the contract's
    /// API surface and for wipes.
    var isEnabled: Bool {
        get { defaults.bool(forKey: AppConfig.Keys.appLockEnabled) }
        set {
            guard newValue != isEnabled else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: AppConfig.Keys.appLockEnabled)
            if !newValue {
                backgroundedAt = nil
                isLocked = false
                lastFailureMessage = nil
            }
            Log.ui.info("App lock \(newValue ? "enabled" : "disabled", privacy: .public)")
        }
    }

    /// Grace period in seconds, persisted to `hopchat.appLock.timeout`.
    /// `0` means lock as soon as the app leaves the foreground.
    var timeout: Int {
        get { max(0, defaults.integer(forKey: AppConfig.Keys.appLockTimeout)) }
        set {
            guard newValue != timeout else { return }
            objectWillChange.send()
            defaults.set(max(0, newValue), forKey: AppConfig.Keys.appLockTimeout)
        }
    }

    /// Enables or disables the lock. Enabling first asks for Face ID / passcode
    /// so nobody can be locked out by a device that cannot authenticate.
    /// Returns the resulting state of ``isEnabled``.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            isEnabled = false
            return false
        }
        guard canAuthenticate else {
            lastFailureMessage = noAuthenticationMessage
            Log.ui.error("App lock refused: device cannot authenticate the owner")
            return false
        }
        let ok = await evaluate(reason: String(localized: "Turn on app lock for HopChat"))
        if ok {
            isEnabled = true
            isLocked = false
        }
        return ok
    }

    // MARK: - Lifecycle

    func appDidEnterBackground() {
        guard isEnabled else { return }
        backgroundedAt = Date()
        if timeout == 0 {
            isLocked = true
        }
    }

    func appWillEnterForeground() {
        guard isEnabled else {
            isLocked = false
            return
        }
        defer { backgroundedAt = nil }
        guard !isLocked else { return }
        if let since = backgroundedAt,
           Date().timeIntervalSince(since) >= Double(timeout) {
            isLocked = true
        }
    }

    /// Locks immediately. A no-op when the lock is switched off, so a caller
    /// can never strand the user behind an unlock screen they cannot pass.
    func lockNow() {
        guard isEnabled else {
            Log.ui.debug("lockNow ignored: app lock is off")
            return
        }
        backgroundedAt = nil
        isLocked = true
    }

    // MARK: - Authentication

    /// Presents Face ID / Touch ID, falling back to the device passcode.
    /// Returns `true` when the app is unlocked afterwards.
    func authenticate() async -> Bool {
        guard isLocked || isEnabled else { return true }
        guard !isAuthenticating else { return !isLocked }

        guard canAuthenticate else {
            // Nothing to authenticate against — do not trap the user.
            Log.ui.error("App lock disabled: device owner authentication unavailable")
            lastFailureMessage = noAuthenticationMessage
            isEnabled = false
            isLocked = false
            return true
        }

        return await evaluate(reason: String(localized: "Unlock HopChat"))
    }

    private func evaluate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")

        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: reason)
            if ok {
                isLocked = false
                lastFailureMessage = nil
            }
            return ok
        } catch {
            lastFailureMessage = Self.message(for: error)
            Log.ui.error("App lock authentication failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// `true` when the device can authenticate its owner by biometry or
    /// passcode.
    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// "Face ID", "Touch ID", "Optic ID" or "device passcode" — used for row
    /// labels so VoiceOver reads something meaningful.
    var authenticationName: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return String(localized: "device passcode")
        }
        switch context.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:       return String(localized: "device passcode")
        }
    }

    private var noAuthenticationMessage: String {
        String(localized: "This device has no passcode or biometrics set up, so app lock cannot be used. Set a passcode in the Settings app first.")
    }

    private static func message(for error: Error) -> String {
        guard let la = error as? LAError else {
            return String(localized: "Authentication failed. Try again.")
        }
        switch la.code {
        case .userCancel, .appCancel, .systemCancel:
            return String(localized: "Authentication was cancelled.")
        case .userFallback:
            return String(localized: "Enter your device passcode to unlock HopChat.")
        case .biometryLockout:
            return String(localized: "Too many failed attempts. Unlock with your device passcode.")
        case .biometryNotEnrolled, .biometryNotAvailable:
            return String(localized: "Biometrics are unavailable. Unlock with your device passcode.")
        case .passcodeNotSet:
            return String(localized: "This device has no passcode, so app lock cannot be used.")
        case .authenticationFailed:
            return String(localized: "Not recognised. Try again.")
        default:
            return String(localized: "Authentication failed. Try again.")
        }
    }
}
