//
//  AvatarView.swift
//  HopChat-1
//
//  Shared avatar + presence components. Other feature views (people, settings,
//  chat) all render identities through these two types, so a change to how a
//  contact looks happens in exactly one place.
//
//  Dynamic Type note: the circle itself is a fixed geometric size (an avatar is
//  an image, not text), but the initials inside scale with the user's text size
//  through `.font(.headline)` + `minimumScaleFactor`, so they never clip.
//

import SwiftUI
import UIKit

// MARK: - Avatar

struct AvatarView: View {

    private let name: String
    private let imageURL: URL?
    private let size: CGFloat

    init(name: String, imageURL: URL?, size: CGFloat = 52) {
        self.name = name
        self.imageURL = imageURL
        self.size = size
    }

    var body: some View {
        ZStack {
            // As the website draws a person: initials in the accent on a wash
            // of it.
            Circle()
                .fill(Palette.accentSoft)

            if let imageURL {
                CachedFileImage(url: imageURL, maxPixel: size * 3)
                    .clipShape(Circle())
            } else {
                Text(AvatarView.initials(for: name))
                    .font(.headline)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(Color.accentColor)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        // The avatar is decoration; the surrounding row supplies the real label.
        .accessibilityHidden(true)
    }

    // MARK: Derivations

    /// Up to two initials, falling back to the first character.
    nonisolated static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .filter { $0.first?.isLetter == true }
            .prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        if !letters.isEmpty { return letters }
        let first = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
        return first ?? "#"
    }
}

// MARK: - Presence

struct PresenceDot: View {

    private let status: PresenceStatus

    init(status: PresenceStatus) {
        self.status = status
    }

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Palette.canvas, lineWidth: 2))
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch status {
        case .online:   return .green
        case .recently: return .yellow
        case .offline:  return Color(.systemGray4)
        }
    }
}

// MARK: - File-backed image with a small memory cache

/// Loads a local JPEG off the main thread, downsampled to what the view
/// actually needs, and keeps it in an `NSCache` so scrolling a long list does
/// not re-decode the same avatar over and over.
struct CachedFileImage: View {
    let url: URL
    var maxPixel: CGFloat = 256

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: url.path) {
            image = await LocalImageCache.shared.image(at: url, maxPixel: maxPixel)
        }
    }
}

nonisolated final class LocalImageCache: @unchecked Sendable {

    static let shared = LocalImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 120
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.path)#\(Int(maxPixel))" as NSString
    }

    func image(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        let cacheKey = key(url, maxPixel)
        if let hit = cache.object(forKey: cacheKey) { return hit }

        let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url),
                  let raw = UIImage(data: data) else { return nil }
            return LocalImageCache.downscale(raw, maxPixel: maxPixel)
        }.value

        if let loaded { cache.setObject(loaded, forKey: cacheKey) }
        return loaded
    }

    func purge() {
        cache.removeAllObjects()
    }

    nonisolated static func downscale(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixel, longest > 0 else { return image }
        let scale = maxPixel / longest
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
