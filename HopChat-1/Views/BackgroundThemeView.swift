//
//  BackgroundThemeView.swift
//  HopChat-1
//
//  What sits behind every screen: Plain, the website's page colour, by
//  default, or the lava backdrop in one of a handful of presets or a custom
//  palette of five colours. The choice is a plain preference
//  (`hoppin.appearance.backgroundTheme` / `…customColors`); custom colours
//  are stored as "#RRGGBB" strings joined by commas.
//

import SwiftUI
import UIKit

// MARK: - Theme model

nonisolated enum BackgroundTheme: String, CaseIterable, Identifiable {
    case plain, aurora, sunset, ocean, forest, candy, mono, custom

    var id: String { rawValue }

    static let colorCount = 5

    var title: String {
        switch self {
        case .plain:  return String(localized: "Plain")
        case .aurora: return String(localized: "Aurora")
        case .sunset: return String(localized: "Sunset")
        case .ocean:  return String(localized: "Ocean")
        case .forest: return String(localized: "Forest")
        case .candy:  return String(localized: "Candy")
        case .mono:   return String(localized: "Graphite")
        case .custom: return String(localized: "Custom")
        }
    }

    /// Five base colours, as hex. Dark mode uses them as-is; light mode
    /// lightens them (see `LavaBackground`). Plain draws none; custom starts
    /// from Aurora's.
    var presetHex: [String] {
        switch self {
        case .plain, .aurora, .custom: return ["#5C29D9", "#E6338C", "#FA7324", "#1473F2", "#1ABFB3"]
        case .sunset: return ["#F24A2E", "#FF9A1F", "#D6246E", "#8A2BE2", "#FFC94D"]
        case .ocean:  return ["#0A5CD6", "#12B5CB", "#2340A8", "#3DD6C4", "#6A4CE0"]
        case .forest: return ["#1F8A4C", "#7CC242", "#0F6E6E", "#C9A227", "#2E5E3A"]
        case .candy:  return ["#FF6FB5", "#9B6DFF", "#56CCF2", "#FFB86B", "#F25F9E"]
        case .mono:   return ["#5B6270", "#8A93A6", "#3A3F4B", "#AEB6C8", "#6E7687"]
        }
    }

    /// The colours currently in effect for this theme. Plain is the page
    /// colour throughout, which is also what its swatch shows.
    func colors(customHex: String) -> [Color] {
        if self == .plain {
            return Array(repeating: Palette.canvas, count: BackgroundTheme.colorCount)
        }
        let hex = self == .custom ? BackgroundTheme.parseCustom(customHex) : presetHex
        return hex.map { Color(hex: $0) ?? .gray }
    }

    static func current(from raw: String) -> BackgroundTheme {
        BackgroundTheme(rawValue: raw) ?? .plain
    }

    /// Always returns exactly `colorCount` entries, falling back to Aurora.
    static func parseCustom(_ stored: String) -> [String] {
        let parts = stored.split(separator: ",").map { String($0) }
        let fallback = BackgroundTheme.aurora.presetHex
        return (0..<colorCount).map { i in
            i < parts.count && Color(hex: parts[i]) != nil ? parts[i] : fallback[i]
        }
    }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    nonisolated init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}

// MARK: - Picker screen

struct BackgroundThemeView: View {

    @AppStorage(AppConfig.Keys.backgroundTheme) private var themeRaw = BackgroundTheme.plain.rawValue
    @AppStorage(AppConfig.Keys.backgroundCustomColors) private var customHex = ""

    private var theme: BackgroundTheme { .current(from: themeRaw) }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        Form {
            Group {
                Section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(BackgroundTheme.allCases) { option in
                            ThemeSwatch(title: option.title,
                                        colors: option.colors(customHex: customHex),
                                        isSelected: option == theme) {
                                withAnimation(.snappy) { themeRaw = option.rawValue }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Theme")
                }

                if theme == .custom {
                    Section {
                        ForEach(0..<BackgroundTheme.colorCount, id: \.self) { index in
                            ColorPicker(selection: customBinding(index), supportsOpacity: false) {
                                Text("Colour \(index + 1)")
                            }
                        }
                        Button("Reset to Aurora") {
                            customHex = ""
                        }
                    } header: {
                        Text("Your colours")
                    } footer: {
                        Text("Pick five colours. They blend into each other behind the blur.")
                    }
                }
            }
            .backdropListRows()
        }
        .appBackground()
        .navigationTitle(Text("Background"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func customBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { Color(hex: BackgroundTheme.parseCustom(customHex)[index]) ?? .gray },
            set: { color in
                var hex = BackgroundTheme.parseCustom(customHex)
                hex[index] = color.hexString
                customHex = hex.joined(separator: ",")
            }
        )
    }
}

private struct ThemeSwatch: View {
    let title: String
    let colors: [Color]
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    // A cheap static stand-in for the animated backdrop.
                    MeshGradient(width: 3, height: 3, points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [0.45, 0.55], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1],
                    ], colors: [
                        colors[0], colors[1], colors[2],
                        colors[3], colors[4], colors[0],
                        colors[2], colors[3], colors[1],
                    ])
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.onAccent, Color.accentColor)
                            .shadow(radius: 3)
                    }
                }
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Palette.hairlineStrong,
                                      lineWidth: isSelected ? 3 : 1)
                )

                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    NavigationStack { BackgroundThemeView() }
        .preferredColorScheme(.dark)
}
