//
//  AppConfig.swift
//  HopChat-1
//
//  Design Contract §6. Non-sensitive configuration only — no secrets,
//  no phone numbers. DEBUG overrides read `hoppin.dev.*` UserDefaults keys
//  and are compiled out of Release builds.
//

import Foundation

nonisolated enum AppConfig {

    // MARK: - Server

    /// Bootstrap/relay server host.
    static var serverHost: String {
        #if DEBUG
        if let override = devOverride("hoppin.dev.serverHost", env: "HOPPIN_DEV_SERVER_HOST") {
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
        // Same precedence as `devOverride`, but stored as a Bool because the
        // Developer screen binds to it with `@AppStorage`.
        let defaults = UserDefaults.standard
        let key = "hoppin.dev.allowPlaintext"
        let appliedKey = key + ".fromScheme"
        let env = (ProcessInfo.processInfo.environment["HOPPIN_DEV_ALLOW_PLAINTEXT"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStored = defaults.object(forKey: key) != nil

        if !env.isEmpty, env != defaults.string(forKey: appliedKey) || !hasStored {
            let allowed = ["1", "true", "yes"].contains(env.lowercased())
            defaults.set(allowed, forKey: key)
            defaults.set(env, forKey: appliedKey)
            return allowed
        }
        return hasStored ? defaults.bool(forKey: key) : false
        #else
        return false
        #endif
    }

    /// DEBUG-only port override, for a dev server that isn't on the usual
    /// port — a tunnel (ngrok and friends hand out a random one), or a second
    /// server on the same machine. Ignored in Release.
    static var devServerPort: UInt16? {
        #if DEBUG
        guard let raw = devOverride("hoppin.dev.serverPort", env: "HOPPIN_DEV_SERVER_PORT"),
              let port = UInt16(raw), port != 0 else { return nil }
        return port
        #else
        return nil
        #endif
    }

    /// The port actually used, derived from `usePlaintextTransport`.
    static var serverPort: UInt16 {
        #if DEBUG
        if let port = devServerPort { return port }
        #endif
        return usePlaintextTransport ? serverPlaintextPort : serverTLSPort
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
        if let override = devOverride("hoppin.dev.serverKey", env: "HOPPIN_DEV_SERVER_KEY") {
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
        if let override = devOverride("hoppin.dev.serverPins", env: "HOPPIN_DEV_SERVER_PINS") {
            return override.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        #endif
        return []
    }

    #if DEBUG
    /// DEBUG-only override lookup, in this order:
    ///
    /// 1. the Xcode scheme's environment variable (Product ▸ Scheme ▸ Edit
    ///    Scheme ▸ Run ▸ Arguments), **when it changed since the last launch**;
    /// 2. whatever is stored on the device — the Developer screen, or the last
    ///    scheme value, which is how home-screen launches keep working;
    /// 3. the scheme value, when nothing is stored.
    ///
    /// The point of rule 1 is that editing the scheme must actually take
    /// effect. It used to lose to the stored copy, so a dev server that moved
    /// to a new address left the phone quietly dialling the old one. The point
    /// of rule 2 is that an edit made on the device must survive a relaunch
    /// from Xcode, which would otherwise re-apply an unchanged scheme over it.
    ///
    /// Compiled out of Release.
    private static func devOverride(_ defaultsKey: String, env: String) -> String? {
        let defaults = UserDefaults.standard
        let appliedKey = defaultsKey + ".fromScheme"
        let resolution = resolveDevOverride(
            stored: defaults.string(forKey: defaultsKey) ?? "",
            lastApplied: defaults.string(forKey: appliedKey),
            fromEnv: ProcessInfo.processInfo.environment[env] ?? "")

        if resolution.persist, let value = resolution.value {
            defaults.set(value, forKey: defaultsKey)
            defaults.set(value, forKey: appliedKey)
        }
        return resolution.value
    }

    /// The decision behind `devOverride`, without the `UserDefaults` around
    /// it so it can be tested directly.
    ///
    /// - `lastApplied` is the scheme value this device last took, which is how
    ///   an unchanged scheme is told apart from a changed one.
    struct DevOverrideResolution: Equatable {
        let value: String?
        /// Whether `value` should be written back as the new stored override.
        let persist: Bool
    }

    static func resolveDevOverride(stored: String,
                                   lastApplied: String?,
                                   fromEnv: String) -> DevOverrideResolution {
        let whitespace = CharacterSet.whitespacesAndNewlines
        let stored = stored.trimmingCharacters(in: whitespace)
        let fromEnv = fromEnv.trimmingCharacters(in: whitespace)

        // The scheme changed (or nothing is stored yet): take it and remember it.
        if !fromEnv.isEmpty, fromEnv != lastApplied || stored.isEmpty {
            return DevOverrideResolution(value: fromEnv, persist: true)
        }
        // Otherwise the device's own value wins, so an edit in the Developer
        // screen survives the next launch from Xcode.
        if !stored.isEmpty {
            return DevOverrideResolution(value: stored, persist: false)
        }
        return DevOverrideResolution(value: nil, persist: false)
    }
    #endif

    // MARK: - Links

    static let websiteURL = URL(string: "https://hoppin.app")!
    static let privacyURL = URL(string: "https://hoppin.app/privacy")!
    static let termsURL   = URL(string: "https://hoppin.app/terms")!
    static let supportURL = URL(string: "https://hoppin.app/support")!
    static let inviteURL  = URL(string: "https://hoppin.app/join")!

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

    static let bonjourServiceType = "_hoppin._tcp"
    static let bonjourDomain = "local."

    // MARK: - UserDefaults keys (non-sensitive only)

    enum Keys {
        static let displayName        = "hoppin.displayName"
        /// Legacy global translate settings — translation is per chat now
        /// (stored with the contact/group). Kept so account deletion clears them.
        static let autoTranslate      = "hoppin.autoTranslate"
        static let translateLang      = "hoppin.translateLang"
        static let sendReadReceipts   = "hoppin.sendReadReceipts"
        static let sendTypingIndicators = "hoppin.sendTypingIndicators"
        static let notificationsEnabled = "hoppin.notifications.enabled"
        static let notificationsPreview = "hoppin.notifications.showPreview"
        static let notificationsSound   = "hoppin.notifications.sound"
        static let animatedBackground = "hoppin.appearance.animatedBackground"
        static let peopleSort         = "hoppin.people.sort"
        static let backgroundTheme    = "hoppin.appearance.backgroundTheme"
        static let backgroundCustomColors = "hoppin.appearance.customColors"
        static let appLockEnabled     = "hoppin.appLock.enabled"
        static let appLockTimeout     = "hoppin.appLock.timeout"
        /// DEBUG-only: dev server port, for tunnels and non-standard ports.
        static let devServerPort      = "hoppin.dev.serverPort"
        /// App language override, written through to `AppleLanguages`.
        /// "" (or absent) means "follow the system".
        static let appLanguage        = "hoppin.appLanguage"
        /// On-device typing suggestions in the chat composer (default true).
        static let typingSuggestions  = "hoppin.typingSuggestions"
        /// Publish this device's IPv6 address to contacts and dial theirs,
        /// so two phones on different networks can talk without the relay
        /// (default true). Off means cross-network delivery is relay-only.
        static let directInternet     = "hoppin.direct.internet"
        /// Deliver over the Bluetooth mesh when there is no internet
        /// (default true). Off means the app only ever uses Wi-Fi and the relay.
        static let meshEnabled        = "hoppin.mesh.enabled"
        static let hasSeenOnboarding  = "hoppin.hasSeenOnboarding"
        static let hasAcceptedTerms   = "hoppin.hasAcceptedTerms"
        /// Legacy v1 key — migrated away on first v2 launch.
        static let legacyPhone        = "hoppin.phone"
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
            Keys.typingSuggestions: true,
            Keys.meshEnabled: true,
            Keys.directInternet: true,
        ])
    }

    /// Every `hoppin.*` default this app owns — used by account deletion.
    static var allUserDefaultsKeys: [String] {
        [Keys.displayName, Keys.autoTranslate, Keys.translateLang,
         Keys.sendReadReceipts, Keys.sendTypingIndicators,
         Keys.notificationsEnabled, Keys.notificationsPreview, Keys.notificationsSound,
         Keys.appLockEnabled, Keys.appLockTimeout, Keys.animatedBackground, Keys.peopleSort,
         Keys.backgroundTheme, Keys.backgroundCustomColors,
         Keys.appLanguage, Keys.typingSuggestions, Keys.meshEnabled, Keys.directInternet,
         Keys.hasSeenOnboarding, Keys.hasAcceptedTerms, Keys.legacyPhone]
    }
}
