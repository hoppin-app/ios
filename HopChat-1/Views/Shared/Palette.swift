//
//  Palette.swift
//  HopChat-1
//
//  The website's look (website/app/globals.css), so the app and hoppin.chat
//  read as one thing: a cool near-white page (near-black in dark mode), ink
//  buttons and links, and the icon's violet kept rare. Every colour here is a
//  colour set in Assets.xcassets holding the website's light and dark values.
//
//  The catalogue's AccentColor, which every system tint follows (list
//  buttons, links, the text cursor), is the ink, so nothing turns violet by
//  accident. The violet is used on purpose and only for marks: your own
//  bubbles until you pick another colour, unread counts, the hoppin mark.
//  Never for text.
//

import SwiftUI

nonisolated enum Palette {
    /// The page behind every screen.
    static let canvas = Color("HopCanvas")
    /// What sits on the page: list rows, incoming bubbles, the composer field.
    static let surface = Color("HopSurface")
    /// Set into the page, like the day separator in a chat.
    static let surfaceSunken = Color("HopSurfaceSunken")
    /// Primary buttons and the selected tab: the text colour, filled in.
    static let ink = Color("HopInk")
    /// Text and icons on ink.
    static let onInk = Color("HopOnInk")
    /// The icon's violet, for marks only: the hoppin mark, onboarding's
    /// icons. Lavender in dark mode. Never for text.
    static let accent = Color("HopAccent")
    /// A wash of violet behind a violet mark. Never a background.
    static let accentSoft = Color("HopAccentSoft")
    /// The light-mode violet in both modes, for fills that carry white:
    /// unread counts, swipe actions.
    static let violet = Color("HopViolet")
    /// Quiet labels, like the tabs that aren't selected.
    static let muted = Color("HopMuted")
    /// One-point borders round surfaces.
    static let hairline = Color("HopHairline")
    static let hairlineStrong = Color("HopHairlineStrong")
    /// Only for a warning the app itself shows, like a changed security code.
    static let warn = Color("HopWarn")
    static let warnSoft = Color("HopWarnSoft")
    /// Shadows carry a trace of the violet, as on the website.
    static let shadow = Color("HopShadow")
}

// MARK: - Buttons

/// The website's primary button: an ink capsule with the page colour for its
/// label. The label brings its own size; most are full width and 52 pt tall.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.onInk)
            .background(Palette.ink, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
}

// MARK: - Type

extension View {
    /// Headlines as the website sets them: semibold, a little tight, and not
    /// rounded.
    func hopTitle(_ style: Font.TextStyle = .title) -> some View {
        font(.system(style, weight: .semibold))
            .tracking(style == .title2 ? -0.3 : -0.5)
    }
}
