//
//  AppConfig.swift
//  HopChat-1
//
//  Design Contract §6. Non-sensitive configuration only — no secrets,
//  no phone numbers. DEBUG overrides read `hopchat.dev.*` UserDefaults keys
//  and are compiled out of Release builds.
//

import Foundation

nonisolated enum AppConfig {

    // MARK: - Server

    /// Bootstrap/relay server host.
    static var serverHost: String {
        #if DEBUG
        if let override = devOverride("hopchat.dev.serverHost", env: "HOPCHAT_DEV_SERVER_HOST") {
            return override
        }
        #endif
        return "34.14.80.215"
    }

    static let serverTLSPort: UInt16 = 4443

    /// Plaintext port — DEBUG builds only, never used in Release.
    static let serverPlaintextPort: UInt16 = 4001

    /// Always `false` in Release. In DEBUG it may be enabled by a developer
    /// override so the app can talk to a local `bootstrap.py` without TLS.
    static var usePlaintextTransport: Bool {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "hopchat.dev.allowPlaintext") != nil {
            return UserDefaults.standard.bool(forKey: "hopchat.dev.allowPlaintext")
        }
        let env = ProcessInfo.processInfo.environment["HOPCHAT_DEV_ALLOW_PLAINTEXT"] ?? ""
        let allowed = ["1", "true", "yes"].contains(env.lowercased())
        // Remembered for home-screen launches, like `devOverride`.
        if allowed { UserDefaults.standard.set(true, forKey: "hopchat.dev.allowPlaintext") }
        return allowed
        #else
        return false
        #endif
    }

    /// The port actually used, derived from `usePlaintextTransport`.
    static var serverPort: UInt16 {
        usePlaintextTransport ? serverPlaintextPort : serverTLSPort
    }

    /// Pinned Ed25519 public key of the bootstrap server (standard base64,
    /// raw 32 bytes). Printed by `bootstrap.py` at startup.
    ///
    /// While this is the placeholder value the service refuses to start and
    /// reports `.error("Server key not configured")` rather than trusting
    /// anything the network says.
    static let serverKeyPlaceholder = "REPLACE_WITH_SERVER_ED25519_PUBLIC_KEY"

    static var serverSigningKeyBase64: String {
        #if DEBUG
        if let override = devOverride("hopchat.dev.serverKey", env: "HOPCHAT_DEV_SERVER_KEY") {
            return override
        }
        #endif
        return serverKeyPlaceholder
    }

    /// `true` when the pinned server key is present and decodes to 32 bytes.
    static var isServerKeyConfigured: Bool {
        let key = serverSigningKeyBase64
        guard key != serverKeyPlaceholder,
              let data = Data(base64Encoded: key),
              data.count == 32 else { return false }
        return true
    }

    /// TLS SPKI pins — base64 of SHA-256 over the DER SubjectPublicKeyInfo.
    /// Current + backup. Empty is tolerated in DEBUG only (pinning skipped).
    static var serverSPKISHA256Base64: [String] {
        #if DEBUG
        if let override = devOverride("hopchat.dev.serverPins", env: "HOPCHAT_DEV_SERVER_PINS") {
            return override.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        #endif
        return []
    }

    #if DEBUG
    /// DEBUG-only override lookup: a value set on the device (Developer screen)
    /// wins; otherwise an environment variable from the Xcode scheme
    /// (Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments). Compiled out of Release.
    ///
    /// Scheme variables only exist when Xcode launches the app, so the first
    /// one seen is copied to the device. Opening the app from the home screen
    /// then keeps talking to the same dev server. To change it later, use the
    /// Developer screen.
    private static func devOverride(_ defaultsKey: String, env: String) -> String? {
        let stored = (UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        let fromEnv = (ProcessInfo.processInfo.environment[env] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromEnv.isEmpty else { return nil }
        UserDefaults.standard.set(fromEnv, forKey: defaultsKey)
        return fromEnv
    }
    #endif

    // MARK: - Links

    static let websiteURL = URL(string: "https://hopchat.app")!
    static let privacyURL = URL(string: "https://hopchat.app/privacy")!
    static let termsURL   = URL(string: "https://hopchat.app/terms")!
    static let supportURL = URL(string: "https://hopchat.app/support")!
    static let inviteURL  = URL(string: "https://hopchat.app/join")!

    // MARK: - App

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static let maxGroupMembers = 32

    /// Long-poll hold time requested from the relay, in seconds.
    static let relayFetchWait = 25

    // MARK: - Bonjour / LAN

    static let bonjourServiceType = "_hopchat._tcp"
    static let bonjourDomain = "local."

    // MARK: - UserDefaults keys (non-sensitive only)

    enum Keys {
        static let displayName        = "hopchat.displayName"
        /// Legacy global translate settings — translation is per chat now
        /// (stored with the contact/group). Kept so account deletion clears them.
        static let autoTranslate      = "hopchat.autoTranslate"
        static let translateLang      = "hopchat.translateLang"
        static let sendReadReceipts   = "hopchat.sendReadReceipts"
        static let sendTypingIndicators = "hopchat.sendTypingIndicators"
        static let notificationsEnabled = "hopchat.notifications.enabled"
        static let notificationsPreview = "hopchat.notifications.showPreview"
        static let notificationsSound   = "hopchat.notifications.sound"
        static let animatedBackground = "hopchat.appearance.animatedBackground"
        static let peopleSort         = "hopchat.people.sort"
        static let backgroundTheme    = "hopchat.appearance.backgroundTheme"
        static let backgroundCustomColors = "hopchat.appearance.customColors"
        static let appLockEnabled     = "hopchat.appLock.enabled"
        static let appLockTimeout     = "hopchat.appLock.timeout"
        static let hasSeenOnboarding  = "hopchat.hasSeenOnboarding"
        static let hasAcceptedTerms   = "hopchat.hasAcceptedTerms"
        /// Legacy v1 key — migrated away on first v2 launch.
        static let legacyPhone        = "hopchat.phone"
    }

    /// Registers the contract's non-`false` defaults exactly once.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.sendReadReceipts: true,
            Keys.sendTypingIndicators: true,
            Keys.notificationsEnabled: true,
            Keys.notificationsPreview: true,
            Keys.notificationsSound: true,
            Keys.animatedBackground: true,
            Keys.appLockEnabled: false,
            Keys.appLockTimeout: 0,
        ])
    }

    /// Every `hopchat.*` default this app owns — used by account deletion.
    static var allUserDefaultsKeys: [String] {
        [Keys.displayName, Keys.autoTranslate, Keys.translateLang,
         Keys.sendReadReceipts, Keys.sendTypingIndicators,
         Keys.notificationsEnabled, Keys.notificationsPreview, Keys.notificationsSound,
         Keys.appLockEnabled, Keys.appLockTimeout, Keys.animatedBackground, Keys.peopleSort,
         Keys.backgroundTheme, Keys.backgroundCustomColors,
         Keys.hasSeenOnboarding, Keys.hasAcceptedTerms, Keys.legacyPhone]
    }
}
