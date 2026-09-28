//
//  SettingsView.swift
//  HopChat-1
//
//  Root of the settings tab (contract §6, §7). Every persisted value here is
//  a non-sensitive `hoppin.*` UserDefaults key from §6 — no phone numbers,
//  no secrets. The v1 bootstrap-IP editor is gone: developer overrides live
//  behind `#if DEBUG` in SettingsDeveloperView.
//

import SwiftUI

/// Languages offered for auto-translation. Shared by the settings screens.
nonisolated enum TranslateLanguage {

    struct Option: Identifiable, Hashable {
        let code: String
        let name: String
        let flag: String
        var id: String { code }
    }

    static let all: [Option] = [
        Option(code: "en", name: String(localized: "English"),    flag: "🇬🇧"),
        Option(code: "pt", name: String(localized: "Portuguese"), flag: "🇵🇹"),
        Option(code: "es", name: String(localized: "Spanish"),    flag: "🇪🇸"),
        Option(code: "fr", name: String(localized: "French"),     flag: "🇫🇷"),
        Option(code: "de", name: String(localized: "German"),     flag: "🇩🇪"),
        Option(code: "it", name: String(localized: "Italian"),    flag: "🇮🇹"),
        Option(code: "zh", name: String(localized: "Chinese"),    flag: "🇨🇳"),
        Option(code: "ja", name: String(localized: "Japanese"),   flag: "🇯🇵"),
        Option(code: "ar", name: String(localized: "Arabic"),     flag: "🇸🇦"),
        Option(code: "hi", name: String(localized: "Hindi"),      flag: "🇮🇳"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? String(localized: "English")
    }
}

struct SettingsView: View {

    @StateObject private var kad = KademliaService.shared
    @StateObject private var store = ConversationStore.shared

    @AppStorage(AppConfig.Keys.displayName)   private var displayName   = ""
    @AppStorage(AppConfig.Keys.animatedBackground) private var animatedBackground = true
    @AppStorage(AppConfig.Keys.backgroundTheme) private var backgroundTheme = BackgroundTheme.plain.rawValue

    /// Only the lava moves; the plain page has nothing to animate.
    private var hasLavaBackground: Bool {
        BackgroundTheme.current(from: backgroundTheme) != .plain
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    profileSection
                    privacySection
                    translateSection
                    appearanceSection
                    accountSection
                    aboutSection
                    developerSection
                }
                .backdropListRows()
            }
            .listStyle(.insetGrouped)
            .appBackground()
            .navigationTitle(Text("Settings"))
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            NavigationLink {
                SettingsProfileView()
            } label: {
                HStack(spacing: 14) {
                    AvatarView(name: displayNameOrFallback,
                               imageURL: SelfProfilePhoto.url,
                               size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayNameOrFallback)
                            .font(.headline)
                        Text(phoneLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Profile. \(displayNameOrFallback). \(phoneLabel)"))
                .accessibilityHint(Text("Edit your name and profile photo"))
            }
        }
    }

    private var displayNameOrFallback: String {
        displayName.isEmpty ? String(localized: "Add your name") : displayName
    }

    private var phoneLabel: String {
        kad.myPhone.isEmpty ? String(localized: "Number not verified yet") : kad.myPhone
    }

    // MARK: - Privacy & notifications

    private var privacySection: some View {
        Section {
            NavigationLink {
                SettingsPrivacyView()
            } label: {
                Label("Privacy & Security", systemImage: "lock.shield")
            }

            NavigationLink {
                SettingsNotificationsView()
            } label: {
                Label("Notifications", systemImage: "bell.badge")
            }

            NavigationLink {
                SettingsMeshView()
            } label: {
                Label("Bluetooth mesh", systemImage: "dot.radiowaves.left.and.right")
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            NavigationLink {
                BackgroundThemeView()
            } label: {
                Label("Background colours", systemImage: "paintpalette")
            }
            NavigationLink {
                SettingsLanguageView()
            } label: {
                Label("Language", systemImage: "character.bubble")
            }
            if hasLavaBackground {
                Toggle(isOn: $animatedBackground) {
                    Text("Animated background")
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            if hasLavaBackground {
                Text("The background also stays still with Reduce Motion or Low Power Mode on.")
            }
        }
    }

    // MARK: - Translate

    private var translateSection: some View {
        Section {
            Label {
                Text("Auto-translate is set per chat: open a chat and tap \(Image(systemName: "translate")) at the top.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "translate")
            }
            .foregroundStyle(.secondary)
        } header: {
            Text("Translate")
        } footer: {
            Text("Translation happens on this device. Nothing is sent to a translation service.")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            NavigationLink {
                ChangeNumberView()
            } label: {
                Label("Change phone number", systemImage: "phone.arrow.up.right")
            }

            NavigationLink {
                DeleteAccountView()
            } label: {
                Label("Delete account", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .accessibilityHint(Text("Permanently deletes your account, messages and keys"))
        } header: {
            Text("Account")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(AppConfig.appVersion)
            } label: {
                Text("Version")
            }
            .accessibilityElement(children: .combine)

            Link(destination: AppConfig.privacyURL) {
                Label("Privacy policy", systemImage: "hand.raised")
            }
            Link(destination: AppConfig.termsURL) {
                Label("Terms of service", systemImage: "doc.text")
            }
            Link(destination: AppConfig.supportURL) {
                Label("Support", systemImage: "questionmark.circle")
            }

            ShareLink(item: AppConfig.inviteURL,
                      subject: Text("Join me on hoppin"),
                      message: Text("Let's chat on hoppin. Messages are end-to-end encrypted.")) {
                Label("Invite a friend", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint(Text("Opens the share sheet with a link to hoppin"))
        } header: {
            Text("About")
        }
    }

    // MARK: - Developer (DEBUG only)

    @ViewBuilder
    private var developerSection: some View {
        #if DEBUG
        Section {
            NavigationLink {
                SettingsDeveloperView()
            } label: {
                Label("Developer", systemImage: "hammer")
            }
        } footer: {
            Text("Debug builds only. Not present in the App Store build.")
        }
        #endif
    }
}

#Preview {
    SettingsView()
}
