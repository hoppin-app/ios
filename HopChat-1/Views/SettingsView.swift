//
//  SettingsView.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 08/04/2026.
//
//  Settings page — Invite a Friend & Translate toggle.
//


import SwiftUI

struct SettingsView: View {
    @StateObject private var kad = KademliaService.shared
    @AppStorage("hopchat.phone")            private var myPhone       = ""
    @AppStorage("hopchat.displayName")      private var displayName   = ""
    @AppStorage("hopchat.autoTranslate")    private var autoTranslate = false
    @AppStorage("hopchat.translateLang")    private var translateLang = "en"
    @AppStorage("hopchat.bootstrap.ip")    private var bootstrapIP   = ""
    @State private var showBootstrapEditor = false
    @State private var editedBootstrapIP   = ""

    @State private var showInviteSheet    = false
    @State private var showNameEditor     = false
    @State private var editedName         = ""
    @State private var showLangPicker     = false
    @State private var selectedTab        = 2

    // Available translation target languages
    private let languages: [(code: String, name: String, flag: String)] = [
        ("en", "English",    "🇬🇧"),
        ("pt", "Portuguese", "🇵🇹"),
        ("es", "Spanish",    "🇪🇸"),
        ("fr", "French",     "🇫🇷"),
        ("de", "German",     "🇩🇪"),
        ("it", "Italian",    "🇮🇹"),
        ("zh", "Chinese",    "🇨🇳"),
        ("ja", "Japanese",   "🇯🇵"),
        ("ar", "Arabic",     "🇸🇦"),
        ("hi", "Hindi",      "🇮🇳"),
    ]

    private var currentLang: (code: String, name: String, flag: String) {
        languages.first { $0.code == translateLang } ?? languages[0]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: Header
                HStack {
                    Image(systemName: "gearshape")
                        .font(.system(size: 22))
                        .foregroundStyle(.blue)
                    Text("Settings")
                        .font(.system(size: 28, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

                List {

                    // MARK: Profile Section
                    Section {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 60, height: 60)
                                Image(systemName: "person.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.blue)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName.isEmpty ? "Set your name" : displayName)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(displayName.isEmpty ? .secondary : .primary)
                                Text(myPhone.isEmpty ? "No phone set" : myPhone)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                editedName = displayName
                                showNameEditor = true
                            } label: {
                                Text("Edit")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 6)
                    } header: {
                        Text("My Profile")
                    }

                    // MARK: Invite a Friend
                    Section {
                        Button {
                            showInviteSheet = true
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.green)
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "person.badge.plus")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Invite a Friend")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.primary)
                                    Text("Share HopChat via message or link")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text("Share")
                    }

                    // MARK: Translate Section
                    Section {
                        // Auto-translate toggle
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.blue)
                                    .frame(width: 32, height: 32)
                                Image(systemName: "character.bubble")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-Translate")
                                    .font(.system(size: 16))
                                Text("Translate incoming messages")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $autoTranslate)
                                .labelsHidden()
                                .tint(.blue)
                        }

                        // Language picker — only shown when translate is on
                        if autoTranslate {
                            Button {
                                showLangPicker = true
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.indigo)
                                            .frame(width: 32, height: 32)
                                        Image(systemName: "globe")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.white)
                                    }
                                    Text("Target Language")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    HStack(spacing: 6) {
                                        Text(currentLang.flag)
                                        Text(currentLang.name)
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    } header: {
                        Text("Translate")
                    } footer: {
                        if autoTranslate {
                            Text("Incoming messages will be automatically translated to \(currentLang.name). Requires an internet connection.")
                        } else {
                            Text("Enable to automatically translate messages from other languages.")
                        }
                    }


                    // MARK: Developer Section
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bootstrap Node")
                                    .font(.system(size: 16))
                                Text(bootstrapIP.isEmpty ? AppConfig.bootstrapIP : bootstrapIP)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                editedBootstrapIP = bootstrapIP.isEmpty ? AppConfig.bootstrapIP : bootstrapIP
                                showBootstrapEditor = true
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.blue)
                        }
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text("Custom bootstrap node IP. Leave empty to use the default.")
                    }
                    // MARK: About Section
                    Section {
                        LabeledContent("Version", value: "1.0.0")
                        LabeledContent("Node ID") {
                            Text(nodeIDShort)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.orange)
                                    .frame(width: 32, height: 32)
                                Image(systemName: "wifi")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Network Status")
                                    .font(.system(size: 16))
                                Text(kad.status)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("About HopChat")
                    }
                }
                .listStyle(.insetGrouped)
                .animation(.easeInOut(duration: 0.2), value: autoTranslate)
            }
            .background(Color(.systemGroupedBackground))
            // MARK: Invite Sheet
            .sheet(isPresented: $showInviteSheet) {
                InviteSheet()
            }
            // MARK: Name Editor

            // Bootstrap editor alert
            .alert("Bootstrap Node IP", isPresented: $showBootstrapEditor) {
                TextField("e.g. 34.14.80.215", text: $editedBootstrapIP)
                    .keyboardType(.numbersAndPunctuation)
                Button("Save") {
                    let trimmed = editedBootstrapIP.trimmingCharacters(in: .whitespaces)
                    bootstrapIP = trimmed
                }
                Button("Reset") { bootstrapIP = "" }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Display Name", isPresented: $showNameEditor) {
                TextField("Your name", text: $editedName)
                Button("Save") {
                    displayName = editedName.trimmingCharacters(in: .whitespaces)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This name is visible to people you chat with.")
            }
            // MARK: Language Picker
            .sheet(isPresented: $showLangPicker) {
                LanguagePickerSheet(selected: $translateLang, languages: languages)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        TabBarItem(icon: "bubble.left",  label: "CHATS",    isSelected: selectedTab == 0) { selectedTab = 0 }
                        TabBarItem(icon: "person",        label: "PEOPLE",   isSelected: selectedTab == 1) { selectedTab = 1 }
                        TabBarItem(icon: "gearshape",     label: "SETTINGS", isSelected: selectedTab == 2) { selectedTab = 2 }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemBackground))
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedTab == 0 },
                set: { if !$0 { selectedTab = 2 } }
            )) {
                ChatListView().navigationBarBackButtonHidden(true)
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedTab == 1 },
                set: { if !$0 { selectedTab = 2 } }
            )) {
                PeopleView().navigationBarBackButtonHidden(true)
            }
        }
    }

    private var nodeIDShort: String {
        if let uuid = UserDefaults.standard.string(forKey: "hopchat.uuid") {
            return String(uuid.prefix(8)) + "…"
        }
        return "Unknown"
    }
}

// MARK: - Invite Sheet

struct InviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    private let appLink = "https://hopchat.app/join"

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Hero
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 90, height: 90)
                        Image(systemName: "wifi")
                            .font(.system(size: 40))
                            .foregroundStyle(.green)
                    }
                    VStack(spacing: 6) {
                        Text("Invite a Friend")
                            .font(.system(size: 24, weight: .bold))
                        Text("HopChat works best with people around you.\nShare the app so they can join!")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 12)

                // Link row
                HStack(spacing: 10) {
                    Text(appLink)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = appLink
                        withAnimation { didCopy = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { didCopy = false }
                        }
                    } label: {
                        Label(didCopy ? "Copied!" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(didCopy ? .green : .blue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)

                // Share sheet button
                ShareLink(
                    item: URL(string: appLink)!,
                    subject: Text("Join me on HopChat!"),
                    message: Text("Chat with me on HopChat — no servers, totally private, works over WiFi! \(appLink)")
                ) {
                    Label("Share via…", systemImage: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Language Picker Sheet

struct LanguagePickerSheet: View {
    @Binding var selected: String
    let languages: [(code: String, name: String, flag: String)]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(languages, id: \.code) { lang in
                Button {
                    selected = lang.code
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        Text(lang.flag).font(.system(size: 22))
                        Text(lang.name)
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                        Spacer()
                        if lang.code == selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Target Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
