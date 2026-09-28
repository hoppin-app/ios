//
//  BubbleColor.swift
//  HopChat-1
//
//  The colour of your own chat bubbles, picked in Settings › Bubble colour.
//  Stored as "#RRGGBB" under `hoppin.appearance.bubbleColor`; empty (or
//  anything unreadable) means the icon's violet. The text on a bubble is
//  white or ink, whichever contrasts more with the colour, so any pick stays
//  readable. The send button follows the same colour.
//

import Foundation
import SwiftUI

nonisolated enum BubbleColor {

    /// The icon's violet: bubbles are this until someone picks another.
    static let defaultHex = "#5A3FCF"

    nonisolated struct Preset: Identifiable {
        let hex: String
        let name: String
        var id: String { hex }
    }

    /// A handful of starting points; any other colour comes from the picker.
    static var presets: [Preset] {
        [
            Preset(hex: defaultHex, name: String(localized: "Violet")),
            Preset(hex: "#AB9CFF", name: String(localized: "Lavender")),
            Preset(hex: "#1F6FEB", name: String(localized: "Blue")),
            Preset(hex: "#0E8388", name: String(localized: "Teal")),
            Preset(hex: "#2F9E44", name: String(localized: "Green")),
            Preset(hex: "#E8590C", name: String(localized: "Orange")),
            Preset(hex: "#D6336C", name: String(localized: "Pink")),
            Preset(hex: "#3A3A45", name: String(localized: "Graphite")),
        ]
    }

    /// The stored choice as "#RRGGBB", or the default when there is none.
    static func hex(from stored: String) -> String {
        RGB(hex: stored)?.hex ?? defaultHex
    }

    static func color(from stored: String) -> Color {
        let rgb = resolved(stored)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// White or ink, whichever reads better on the bubble.
    static func textColor(from stored: String) -> Color {
        prefersDarkText(stored)
            ? Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x16 / 255)
            : .white
    }

    /// True when ink contrasts more than white with the colour, by the WCAG
    /// contrast ratio.
    static func prefersDarkText(_ stored: String) -> Bool {
        let bubble = resolved(stored).luminance
        let ink = inkLuminance
        return (bubble + 0.05) / (ink + 0.05) > (1.0 + 0.05) / (bubble + 0.05)
    }

    private static let inkLuminance = RGB(red: 0x12 / 255, green: 0x12 / 255, blue: 0x16 / 255).luminance

    private static func resolved(_ stored: String) -> RGB {
        RGB(hex: stored) ?? RGB(red: 0x5A / 255, green: 0x3F / 255, blue: 0xCF / 255)
    }

    /// An sRGB colour read from "#RRGGBB" or "RRGGBB".
    nonisolated struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init?(hex: String) {
            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }

        var hex: String {
            func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
            return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        }

        /// Relative luminance, as WCAG defines it.
        var luminance: Double {
            func linear(_ c: Double) -> Double {
                c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }
}
