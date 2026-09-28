//
//  LavaBackground.swift
//  HopChat-1
//
//  What sits behind every screen. By default that is the website's plain page
//  colour (`AppBackground`); anyone who picks a colour theme in Settings ›
//  Background colours gets the lava instead: a few large, softly coloured
//  blobs drifting slowly behind a heavy blur, like a lava lamp seen through
//  frosted glass.
//
//  Cost is kept low on purpose:
//   • the blobs are drawn into a canvas a quarter of the screen's size and
//     scaled up — after a big blur nobody can tell, and the GPU does 1/16 of
//     the work;
//   • 30 fps, and the timeline pauses when the app isn't active, under
//     Reduce Motion, in Low Power Mode, or when the user turns it off;
//   • motion is a pure function of the clock, so every screen that shows the
//     background shows the same frame and switching tabs never "jumps".
//

import SwiftUI

struct LavaBackground: View {

    @AppStorage(AppConfig.Keys.animatedBackground) private var animated = true
    @AppStorage(AppConfig.Keys.backgroundTheme) private var themeRaw = BackgroundTheme.plain.rawValue
    @AppStorage(AppConfig.Keys.backgroundCustomColors) private var customHex = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Rendering happens at 1/`downscale` of the view size.
    private static let downscale: CGFloat = 4

    private var isPaused: Bool {
        !animated || reduceMotion || lowPower || scenePhase != .active
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let small = CGSize(width: max(size.width / Self.downscale, 1),
                               height: max(size.height / Self.downscale, 1))

            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { timeline in
                let time = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
                Canvas(opaque: true, rendersAsynchronously: true) { context, canvasSize in
                    draw(in: &context, size: canvasSize, time: time)
                }
                .frame(width: small.width, height: small.height)
                .scaleEffect(Self.downscale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .overlay(scrim)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    // MARK: Drawing

    private var isDark: Bool { colorScheme == .dark }

    private var baseColor: Color {
        isDark ? Color(red: 0.04, green: 0.03, blue: 0.09) : Color(red: 0.96, green: 0.95, blue: 0.99)
    }

    /// A translucent wash on top that keeps text readable over the colours.
    private var scrim: some View {
        (isDark ? Color.black.opacity(0.28) : Color.white.opacity(0.35))
    }

    /// Palette for this mode: as chosen in dark mode, lightened to pastels in light mode.
    private var palette: [Color] {
        let base = BackgroundTheme.current(from: themeRaw).colors(customHex: customHex)
        return isDark ? base : base.map { $0.mix(with: .white, by: 0.45) }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let palette = self.palette
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(baseColor))

        let unit = min(size.width, size.height)
        context.addFilter(.blur(radius: unit * 0.16))

        context.drawLayer { layer in
            for blob in Self.blobs {
                let t = time / blob.period * 2 * .pi
                let x = size.width  * (0.5 + blob.amplitude.width  * sin(t + blob.phase))
                let y = size.height * (0.5 + blob.amplitude.height * sin(t * blob.ratio + blob.phase * 1.7))
                // Radius breathes a little, which makes neighbours merge and split.
                let r = unit * blob.radius * (1 + 0.12 * sin(t * 1.9 + blob.phase))
                let rect = CGRect(x: x - r, y: y - r * 1.1, width: r * 2, height: r * 2.2)
                let color = palette[blob.paletteIndex % palette.count]
                layer.fill(Path(ellipseIn: rect),
                           with: .color(color.opacity(isDark ? 0.75 : 0.55)))
            }
        }
    }

    // MARK: Blobs

    private struct Blob {
        let paletteIndex: Int
        /// Fraction of the short side.
        let radius: CGFloat
        /// Seconds for one horizontal swing.
        let period: TimeInterval
        /// Vertical frequency relative to horizontal (Lissajous path).
        let ratio: Double
        let phase: Double
        /// Swing as a fraction of the view size.
        let amplitude: CGSize
    }

    /// Each blob takes one colour from the chosen palette.
    private static let blobs: [Blob] = [
        Blob(paletteIndex: 0, radius: 0.55, period: 34, ratio: 0.63, phase: 0.0, amplitude: CGSize(width: 0.35, height: 0.38)),
        Blob(paletteIndex: 1, radius: 0.45, period: 27, ratio: 0.81, phase: 2.1, amplitude: CGSize(width: 0.40, height: 0.33)),
        Blob(paletteIndex: 2, radius: 0.38, period: 41, ratio: 1.27, phase: 4.0, amplitude: CGSize(width: 0.30, height: 0.42)),
        Blob(paletteIndex: 3, radius: 0.50, period: 30, ratio: 0.52, phase: 5.3, amplitude: CGSize(width: 0.38, height: 0.30)),
        Blob(paletteIndex: 4, radius: 0.32, period: 23, ratio: 1.12, phase: 1.2, amplitude: CGSize(width: 0.33, height: 0.40)),
    ]
}

// MARK: - The page behind every screen

/// The website's plain page colour, or the lava for anyone who picked a
/// colour theme.
struct AppBackground: View {

    @AppStorage(AppConfig.Keys.backgroundTheme) private var themeRaw = BackgroundTheme.plain.rawValue

    var body: some View {
        if BackgroundTheme.current(from: themeRaw) == .plain {
            Palette.canvas
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            LavaBackground()
        }
    }
}

/// A grouped list row's background: a solid surface on the plain page, the
/// way the website's cards sit on it, and frosted glass over the lava.
private struct BackdropRowBackground: View {

    @AppStorage(AppConfig.Keys.backgroundTheme) private var themeRaw = BackgroundTheme.plain.rawValue

    var body: some View {
        if BackgroundTheme.current(from: themeRaw) == .plain {
            Palette.surface
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

extension View {
    /// Puts the app's backdrop behind a screen and clears the system
    /// list/scroll background so it shows through.
    func appBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
    }

    /// Row backgrounds for grouped lists and forms shown over the backdrop.
    /// Apply to the list *content* (row backgrounds are per row).
    func backdropListRows() -> some View {
        listRowBackground(BackdropRowBackground())
    }
}

#Preview("Dark") {
    LavaBackground().preferredColorScheme(.dark)
}

#Preview("Light") {
    LavaBackground().preferredColorScheme(.light)
}
