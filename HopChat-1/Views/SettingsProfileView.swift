//
//  SettingsProfileView.swift
//  HopChat-1
//
//  Display name + profile photo. Both are broadcast to contacts through
//  `KademliaService.updateProfile(displayName:avatarJPEG:)` (contract §4
//  `profile` payload: avatar ≤ 64 KB, 256 px).
//

import SwiftUI
import PhotosUI
import UIKit
import os

/// Where our own avatar JPEG lives. It sits in the conversation store's
/// avatars directory so account deletion wipes it with everything else.
nonisolated enum SelfProfilePhoto {

    static let filename = "self-profile.jpg"

    @MainActor
    static var url: URL? {
        let url = ConversationStore.shared.avatarURL(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @MainActor
    static func write(_ jpeg: Data) {
        let url = ConversationStore.shared.avatarURL(filename)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try jpeg.write(to: url,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.ui.error("Could not save profile photo: \(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    static func remove() {
        try? FileManager.default.removeItem(at: ConversationStore.shared.avatarURL(filename))
    }

    /// Scales to a 256 px square-ish image and compresses until it fits the
    /// contract's 64 KB avatar budget. Returns `nil` when the data is not an
    /// image or cannot be squeezed small enough.
    nonisolated static func prepare(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let maxEdge: CGFloat = 256
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(width: max(1, (image.size.width * scale).rounded()),
                            height: max(1, (image.size.height * scale).rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let jpeg = resized.jpegData(compressionQuality: quality),
               jpeg.count <= ChatPayload.maxAvatarBytes {
                return jpeg
            }
        }
        return nil
    }
}

struct SettingsProfileView: View {

    @StateObject private var kad = KademliaService.shared
    @AppStorage(AppConfig.Keys.displayName) private var displayName = ""

    @State private var editedName = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var avatarURL: URL?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    AvatarView(name: displayName.isEmpty ? "?" : displayName,
                               imageURL: avatarURL,
                               size: 96)
                        .accessibilityLabel(Text(avatarURL == nil
                                                 ? "No profile photo"
                                                 : "Your profile photo"))

                    PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                        Text(avatarURL == nil ? "Add photo" : "Change photo")
                            .font(.body)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(isBusy)

                    if avatarURL != nil {
                        Button(role: .destructive) {
                            removePhoto()
                        } label: {
                            Text("Remove photo")
                                .font(.body)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .disabled(isBusy)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                TextField("Your name", text: $editedName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .accessibilityLabel(Text("Display name"))
            } header: {
                Text("Name")
            } footer: {
                Text("Your name and photo are sent, encrypted, to people in your contacts. They are never stored on the relay server.")
            }

            Section {
                LabeledContent {
                    Text(kad.myPhone.isEmpty ? String(localized: "Not verified") : kad.myPhone)
                        .foregroundStyle(kad.myPhone.isEmpty ? .secondary : .primary)
                } label: {
                    Text("Phone number")
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Verified number")
            } footer: {
                Text("This is the number your contacts see. Change it from Settings › Account.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(Text("Profile"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isBusy || trimmedName == displayName)
            }
        }
        .task {
            editedName = displayName
            avatarURL = SelfProfilePhoto.url
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await handlePicked(item) }
        }
    }

    private var trimmedName: String {
        editedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func save() {
        nameFocused = false
        let name = trimmedName
        guard name != displayName else { return }
        displayName = name
        broadcast(avatar: nil)
    }

    private func handlePicked(_ item: PhotosPickerItem) async {
        isBusy = true
        errorMessage = nil
        defer {
            isBusy = false
            pickedItem = nil
        }

        let loaded: Data?
        do {
            loaded = try await item.loadTransferable(type: Data.self)
        } catch {
            Log.ui.error("Photo load failed: \(String(describing: error), privacy: .public)")
            loaded = nil
        }

        guard let raw = loaded, let jpeg = SelfProfilePhoto.prepare(raw) else {
            errorMessage = String(localized: "That photo could not be used. Try a different one.")
            return
        }

        SelfProfilePhoto.write(jpeg)
        avatarURL = SelfProfilePhoto.url
        await kad.updateProfile(displayName: displayName, avatarJPEG: jpeg)
        Log.ui.info("Profile photo updated (\(jpeg.count, privacy: .public) bytes)")
    }

    private func removePhoto() {
        SelfProfilePhoto.remove()
        avatarURL = nil
        broadcast(avatar: nil)
    }

    private func broadcast(avatar: Data?) {
        isBusy = true
        Task {
            await kad.updateProfile(displayName: displayName, avatarJPEG: avatar)
            isBusy = false
        }
    }
}

#Preview {
    NavigationStack { SettingsProfileView() }
}
