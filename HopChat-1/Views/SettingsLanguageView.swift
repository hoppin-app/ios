//
//  SettingsLanguageView.swift
//  HopChat-1
//
//  App language (contract §6, `hoppin.appLanguage`) plus the on-device
//  typing-suggestion switch (`hoppin.typingSuggestions`).
//
//  The choice is written through to the standard `AppleLanguages` default,
//  which is what picks the bundle's `.lproj` at launch. A running app keeps
//  the bundle it started with — SwiftUI cannot re-render its way into another
//  language — so the screen says plainly that it takes effect on restart, and
//  offers the iOS Settings page where the same choice lives per app.
//
//  Deliberately no `Bundle` swizzling and no forced exit.
//

import SwiftUI
import UIKit

// MARK: - Choice

nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case portuguese = "pt-PT"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:     return String(localized: "System default")
        case .english:    return String(localized: "English")
        case .portuguese: return String(localized: "Português")
        }
    }

    /// Shown under the title: what the system would pick, or the native name.
    var subtitle: String? {
        switch self {
        case .system:
            let code = Locale.preferredLanguages.first ?? Locale.current.identifier
            let name = Locale.current.localizedString(forIdentifier: code) ?? code
            return name
        case .english, .portuguese:
            return nil
        }
    }

    /// What goes into `AppleLanguages`; `nil` removes the key.
    var appleLanguages: [String]? {
        switch self {
        case .system:     return nil
        case .english:    return ["en"]
        case .portuguese: return ["pt-PT"]
        }
    }

    static func current(from raw: String) -> AppLanguage {
        AppLanguage(rawValue: raw) ?? .system
    }

    /// Applies the choice to `AppleLanguages`. Takes effect at next launch.
    static func apply(_ language: AppLanguage, to defaults: UserDefaults = .standard) {
        if let codes = language.appleLanguages {
            defaults.set(codes, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}

// MARK: - Screen

struct SettingsLanguageView: View {

    @AppStorage(AppConfig.Keys.appLanguage) private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(AppConfig.Keys.typingSuggestions) private var typingSuggestions = true

    /// Set once the user changes the language in this session.
    @State private var didChange = false

    private var selection: AppLanguage { .current(from: languageRaw) }

    var body: some View {
        Form {
            Group {
                Section {
                    ForEach(AppLanguage.allCases) { option in
                        Button {
                            choose(option)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .foregroundStyle(.primary)
                                    if let subtitle = option.subtitle {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 12)
                                if option == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == selection ? [.isButton, .isSelected] : .isButton)
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("The new language appears the next time you open hoppin. iOS keeps the language an app started with.")
                }

                if didChange {
                    Section {
                        Label {
                            Text("Language saved. Close hoppin and open it again to see it.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        openAppSettings()
                    } label: {
                        Label("Open hoppin in iOS Settings", systemImage: "gear")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint(Text("Opens the iOS Settings page for hoppin"))
                } footer: {
                    Text("iOS also has a Preferred Language for each app, on hoppin's own Settings page.")
                }

                Section {
                    Toggle(isOn: $typingSuggestions) {
                        Text("Typing suggestions")
                    }
                } header: {
                    Text("Writing")
                } footer: {
                    Text("Offers spelling corrections as you write, using the dictionaries already on this device. Nothing you type is sent anywhere.")
                }
            }
            .glassListRows()
        }
        .lavaBackground()
        .navigationTitle(Text("Language"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ option: AppLanguage) {
        guard option != selection else { return }
        languageRaw = option.rawValue
        AppLanguage.apply(option)
        withAnimation(.snappy) { didChange = true }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    NavigationStack { SettingsLanguageView() }
        .preferredColorScheme(.dark)
}
