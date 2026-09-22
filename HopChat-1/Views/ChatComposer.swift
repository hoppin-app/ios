//
//  ChatComposer.swift
//  HopChat-1
//
//  The message input bar: a growing multi-line field, a photo picker, and a
//  send button.
//
//  Two hard rules live here:
//   • Images are downscaled to ≤ 1600 px on the long edge and ≤ 600 KB of JPEG
//     *before* they reach `KademliaService.sendImage`. The transport rejects
//     anything larger (`ChatPayload.maxImageBytes`), so silently over-sized
//     picks would just vanish.
//   • Compression happens off the main actor; a 12-megapixel photo must not
//     stall the UI.
//

import SwiftUI
import PhotosUI
import Photos
import UIKit
import os

// MARK: - Composer

struct ChatComposer: View {

    @Binding var text: String

    /// Sending is blocked (unacknowledged key change, keys not ready, …).
    var isSendBlocked: Bool = false
    var blockedReason: String? = nil
    var placeholder: String = String(localized: "Message")
    /// The message being replied to, shown above the field.
    var replyContext: ReplyPreview? = nil
    var onCancelReply: () -> Void = {}
    /// The chat's auto-translate language, if the user set one. It is the
    /// strongest hint about what language the draft is being written in.
    var conversationLanguage: String? = nil

    var onSend: () -> Void
    var onImage: (Data) -> Void
    var onTyping: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPreparingImage = false
    @State private var imageError: String?
    @State private var lastTypingPing: Date = .distantPast

    // MARK: Typing suggestions (on device, see Services/TypingAssistant.swift)

    @AppStorage(AppConfig.Keys.typingSuggestions) private var typingSuggestionsEnabled = true
    @AppStorage(AppConfig.Keys.appLanguage) private var appLanguageRaw = ""

    @State private var suggestion: TypingSuggestion?
    /// The word the writer dismissed; the bar stays away until they move on.
    @State private var dismissedWord: String?
    @State private var suggestTask: Task<Void, Never>?

    private var suggestionLanguage: String {
        TypingAssistant.resolvedLanguage(conversationLanguage: conversationLanguage,
                                         appLanguage: appLanguageRaw.isEmpty ? nil : appLanguageRaw)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmed.isEmpty && !isSendBlocked
    }

    var body: some View {
        VStack(spacing: 6) {
            if let imageError {
                Text(imageError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }

            if let replyContext {
                replyBar(replyContext)
            }

            if let suggestion, !suggestion.replacements.isEmpty {
                suggestionBar(suggestion)
            }

            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Group {
                        if isPreparingImage {
                            ProgressView()
                        } else {
                            Image(systemName: "photo.on.rectangle")
                                .font(.body)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .disabled(isSendBlocked || isPreparingImage)
                .accessibilityLabel(Text("Send a photo"))

                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .textInputAutocapitalization(.sentences)
                    .disabled(isSendBlocked)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel(Text(placeholder))

                Button {
                    onSend()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(canSend ? Color.blue : Color(.systemGray4), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canSend)
                .accessibilityLabel(Text("Send"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if let blockedReason, isSendBlocked {
                Text(blockedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: text) { _, newValue in
            scheduleSuggestion(for: newValue)
            guard !newValue.isEmpty, !isSendBlocked else { return }
            // Local throttle (~1.5 s); the service throttles again at 3 s.
            let now = Date()
            guard now.timeIntervalSince(lastTypingPing) >= 1.5 else { return }
            lastTypingPing = now
            onTyping()
        }
        .onChange(of: replyContext?.messageID) { _, id in
            if id != nil { isFocused = true }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await prepare(item) }
        }
        .onChange(of: typingSuggestionsEnabled) { _, enabled in
            if !enabled { clearSuggestion() } else { scheduleSuggestion(for: text) }
        }
        .onDisappear {
            suggestTask?.cancel()
            suggestTask = nil
        }
    }

    // MARK: Suggestion bar

    /// Slim, quiet row of corrections above the field. It never takes focus
    /// and never blocks sending — the send button is unaffected by it.
    private func suggestionBar(_ suggestion: TypingSuggestion) -> some View {
        HStack(spacing: 8) {
            Text("Did you mean")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestion.replacements, id: \.self) { replacement in
                        Button {
                            applySuggestion(suggestion, replacement: replacement)
                        } label: {
                            Text(replacement)
                                .font(.callout)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 30)
                                .background(Color(.tertiarySystemBackground),
                                            in: Capsule())
                                .frame(minHeight: 44)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Replace with \(replacement)"))
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            Button {
                dismissSuggestion(suggestion)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss suggestions"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    // MARK: Suggestion logic

    /// Debounced ~0.3 s so the bar doesn't flicker mid-word.
    private func scheduleSuggestion(for value: String) {
        suggestTask?.cancel()
        guard typingSuggestionsEnabled,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSuggestion()
            return
        }
        // Moving on to another word revives a dismissed bar.
        if let dismissedWord,
           TypingAssistant.currentWord(in: value)?.text != dismissedWord {
            self.dismissedWord = nil
        }
        suggestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, value == text else { return }
            let found = TypingAssistant.shared.suggestion(for: value, language: suggestionLanguage)
            guard found?.original != dismissedWord else {
                withAnimation(.snappy) { suggestion = nil }
                return
            }
            withAnimation(.snappy) { suggestion = found }
        }
    }

    private func applySuggestion(_ suggestion: TypingSuggestion, replacement: String) {
        text = TypingSuggestion.apply(suggestion, replacement: replacement, to: text)
        clearSuggestion()
    }

    private func dismissSuggestion(_ suggestion: TypingSuggestion) {
        dismissedWord = suggestion.original
        clearSuggestion()
    }

    private func clearSuggestion() {
        suggestTask?.cancel()
        suggestTask = nil
        withAnimation(.snappy) { suggestion = nil }
    }

    // MARK: Reply bar

    private func replyBar(_ preview: ReplyPreview) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.footnote)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            ReplyQuote(preview: preview)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Replying to \(preview.author): \(preview.snippet)"))

            Button(action: onCancelReply) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel reply"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.top, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Photo handling

    private func prepare(_ item: PhotosPickerItem) async {
        isPreparingImage = true
        imageError = nil
        defer {
            isPreparingImage = false
            pickerItem = nil
        }

        guard let raw = try? await item.loadTransferable(type: Data.self), !raw.isEmpty else {
            imageError = String(localized: "That photo couldn't be loaded.")
            Log.ui.error("PhotosPicker returned no data")
            return
        }

        let prepared = await Task.detached(priority: .userInitiated) {
            ImageDownscaler.prepareForSending(raw)
        }.value

        guard let prepared else {
            imageError = String(localized: "That photo couldn't be prepared for sending.")
            return
        }
        onImage(prepared)
    }
}

// MARK: - Downscaling

nonisolated enum ImageDownscaler {

    /// Contract §4: ≤ 1600 px on the long edge and ≤ 600 KB decoded JPEG.
    static let maxDimension: CGFloat = 1600
    static var maxBytes: Int { ChatPayload.maxImageBytes }

    /// Returns JPEG data guaranteed to satisfy both limits, or `nil` when the
    /// input can't be decoded (or can't be squeezed small enough at all).
    static func prepareForSending(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return prepareForSending(image)
    }

    static func prepareForSending(_ image: UIImage) -> Data? {
        var dimension = maxDimension
        // Try progressively smaller geometries; within each, walk the quality
        // down. Four rounds takes 1600 → 200 px, which always fits.
        for _ in 0..<4 {
            let scaled = LocalImageCache.downscale(image, maxPixel: dimension)
            for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
                guard let jpeg = scaled.jpegData(compressionQuality: CGFloat(quality)) else { continue }
                if jpeg.count <= maxBytes { return jpeg }
            }
            dimension /= 2
        }
        return nil
    }

    /// Avatars: 256 px, ≤ 64 KB (contract §4). Shared with the settings screen.
    static func prepareAvatar(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = LocalImageCache.downscale(image, maxPixel: 256)
        for quality in stride(from: 0.8, through: 0.2, by: -0.1) {
            guard let jpeg = scaled.jpegData(compressionQuality: CGFloat(quality)) else { continue }
            if jpeg.count <= ChatPayload.maxAvatarBytes { return jpeg }
        }
        return nil
    }
}

// MARK: - Saving to Photos

nonisolated enum PhotoSaver {

    enum Result: Equatable {
        case success
        case failure(String)
    }

    /// Adds a local JPEG to the user's library. Uses the add-only entitlement
    /// (`NSPhotoLibraryAddUsageDescription`) — we never read the library.
    static func save(fileURL: URL) async -> Result {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            return .failure(String(localized: "hoppin needs permission to add photos. Enable it in Settings."))
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .photo, fileURL: fileURL, options: nil)
            }
            return .success
        } catch {
            return .failure(String(localized: "Couldn't save that photo."))
        }
    }
}
