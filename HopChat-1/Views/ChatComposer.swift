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

    var onSend: () -> Void
    var onImage: (Data) -> Void
    var onTyping: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPreparingImage = false
    @State private var imageError: String?
    @State private var lastTypingPing: Date = .distantPast

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
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
        .onChange(of: text) { _, newValue in
            guard !newValue.isEmpty, !isSendBlocked else { return }
            // Local throttle (~1.5 s); the service throttles again at 3 s.
            let now = Date()
            guard now.timeIntervalSince(lastTypingPing) >= 1.5 else { return }
            lastTypingPing = now
            onTyping()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await prepare(item) }
        }
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
            return .failure(String(localized: "HopChat needs permission to add photos. Enable it in Settings."))
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
