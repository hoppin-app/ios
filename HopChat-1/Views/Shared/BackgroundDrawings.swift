//
//  BackgroundDrawings.swift
//  HopChat-1
//
//  Drawings made in Settings › Background float behind every screen, small,
//  drifting like the lava's blobs. Each is a PencilKit drawing kept as its own
//  file inside the store directory, so it is excluded from backup with the
//  rest of the store and goes with it when the account is deleted. They never
//  leave the phone.
//

import SwiftUI
import UIKit
import Combine
import PencilKit
import os

@MainActor
final class BackgroundDrawings: ObservableObject {

    static let shared = BackgroundDrawings(
        directory: ConversationStore.defaultDirectory.appendingPathComponent("drawings", isDirectory: true))

    /// Enough to fill the background without crowding the chats.
    static let limit = 12

    struct Item: Identifiable {
        /// "<milliseconds>-<uuid>": the time it was made comes first, so file
        /// names sort oldest first.
        let id: String
        let drawing: PKDrawing
    }

    @Published private(set) var items: [Item] = []

    private let directory: URL
    /// Rendered images, per drawing and appearance.
    private var rendered: [String: UIImage] = [:]

    init(directory: URL) {
        self.directory = directory
        load()
    }

    var canAdd: Bool { items.count < Self.limit }

    /// Keeps a new drawing. False when the limit is reached or it could not
    /// be written.
    @discardableResult
    func add(_ drawing: PKDrawing) -> Bool {
        guard canAdd else { return false }
        let id = nextID()
        do {
            try ensureDirectory()
            try drawing.dataRepresentation().write(to: fileURL(id), options: StorageProtection.writingOptions)
        } catch {
            Log.store.error("could not save a background drawing: \(String(describing: error), privacy: .public)")
            return false
        }
        items.append(Item(id: id, drawing: drawing))
        return true
    }

    func remove(id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
        items.removeAll { $0.id == id }
        rendered = rendered.filter { !$0.key.hasPrefix(id + "|") }
    }

    /// Account deletion. The files also go with the store directory; this
    /// clears what is on screen as well.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        items = []
        rendered = [:]
    }

    /// The drawing rendered for light or dark mode. PencilKit adapts ink to
    /// the appearance it draws in (black ink comes out white in dark mode), so
    /// each appearance gets its own image.
    func image(for item: Item, dark: Bool) -> UIImage {
        let key = item.id + "|" + (dark ? "dark" : "light")
        if let cached = rendered[key] { return cached }
        let bounds = item.drawing.bounds
        // An empty drawing has null bounds; there is nothing to show.
        guard !bounds.isNull, !bounds.isEmpty else { return UIImage() }
        let scale = min(2, 480 / max(bounds.width, bounds.height, 1))
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            image = item.drawing.image(from: bounds, scale: scale)
        }
        rendered[key] = image
        return image
    }

    // MARK: Files

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("drawing")
    }

    /// The time now, nudged past the newest drawing if two land in the same
    /// millisecond, so the order on disk is the order they were made.
    private func nextID() -> String {
        var stamp = Int64(Date().timeIntervalSince1970 * 1000)
        if let newest = items.last?.id.split(separator: "-").first.flatMap({ Int64($0) }), stamp <= newest {
            stamp = newest + 1
        }
        return "\(stamp)-\(UUID().uuidString)"
    }

    private func ensureDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: StorageProtection.directoryAttributes)
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        items = files
            .filter { $0.pathExtension == "drawing" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let drawing = try? PKDrawing(data: data) else { return nil }
                return Item(id: url.deletingPathExtension().lastPathComponent, drawing: drawing)
            }
    }
}

// MARK: - Floating layer

/// The drawings, small and faint, drifting behind a screen the way the lava's
/// blobs do. Motion is a pure function of the clock, so every screen shows the
/// same frame; it holds still with Reduce Motion, in Low Power Mode, with the
/// Animated background switch off, or while the app is in the background.
struct FloatingDrawings: View {

    @StateObject private var drawings = BackgroundDrawings.shared
    @AppStorage(AppConfig.Keys.animatedBackground) private var animated = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var isPaused: Bool {
        !animated || reduceMotion || lowPower || scenePhase != .active
    }

    var body: some View {
        let dark = colorScheme == .dark
        let sprites = drawings.items.map { item in
            let image = drawings.image(for: item, dark: dark)
            return DrawingSprite(image: Image(uiImage: image), size: image.size, drift: .init(id: item.id))
        }
        Group {
            if !sprites.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { timeline in
                    let time = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
                    Canvas(rendersAsynchronously: true) { context, size in
                        FloatingDrawings.draw(sprites, in: &context, size: size, time: time, dark: dark)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    /// Each drawing fits a square a fifth of the screen's short side, wanders
    /// a slow Lissajous path of its own and rocks a little as it goes.
    nonisolated static func draw(_ sprites: [DrawingSprite],
                                 in context: inout GraphicsContext,
                                 size: CGSize,
                                 time: TimeInterval,
                                 dark: Bool) {
        let side = min(size.width, size.height) * 0.22
        context.opacity = dark ? 0.4 : 0.32
        for sprite in sprites {
            guard sprite.size.width > 0, sprite.size.height > 0 else { continue }
            let fit = side / max(sprite.size.width, sprite.size.height)
            let width = sprite.size.width * fit
            let height = sprite.size.height * fit
            let drift = sprite.drift
            let t = time / drift.period * 2 * .pi
            let x = size.width * (0.5 + 0.36 * sin(t + drift.phase))
            let y = size.height * (0.5 + 0.38 * sin(t * drift.ratio + drift.phase * 1.7))
            var layer = context
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .radians(drift.spin * sin(t * 1.3 + drift.phase)))
            layer.draw(sprite.image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        }
    }
}

/// One drawing as the background draws it.
nonisolated struct DrawingSprite {
    let image: Image
    let size: CGSize
    let drift: Drift

    /// Where it wanders: different for each drawing, the same every launch.
    nonisolated struct Drift {
        /// Seconds for one horizontal swing.
        let period: Double
        /// Vertical frequency relative to horizontal.
        let ratio: Double
        let phase: Double
        /// How far it rocks either way, in radians.
        let spin: Double

        init(id: String) {
            let seed = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
            func unit(_ shift: UInt32) -> Double { Double((seed >> shift) & 0xFF) / 255 }
            period = 36 + 30 * unit(0)
            ratio = 0.55 + 0.7 * unit(8)
            phase = 2 * .pi * unit(16)
            spin = 0.06 + 0.1 * unit(24)
        }
    }
}
