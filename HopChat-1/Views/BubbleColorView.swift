//
//  BubbleColorView.swift
//  HopChat-1
//
//  Settings › Bubble colour: a few presets and a colour picker for your own
//  chat bubbles, under a two-line chat that shows the choice as it is made.
//  The choice is a plain preference (`hoppin.appearance.bubbleColor`).
//

import SwiftUI

struct BubbleColorView: View {

    @AppStorage(AppConfig.Keys.bubbleColor) private var bubbleHex = ""

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    private var selectedHex: String { BubbleColor.hex(from: bubbleHex) }

    var body: some View {
        Form {
            Group {
                Section {
                    preview
                }

                Section {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(BubbleColor.presets) { preset in
                            BubbleSwatch(preset: preset, isSelected: preset.hex == selectedHex) {
                                withAnimation(.snappy) { bubbleHex = preset.hex }
                            }
                        }
                    }
                    .padding(.vertical, 6)

                    ColorPicker(selection: customBinding, supportsOpacity: false) {
                        Text("Custom colour")
                    }
                } footer: {
                    Text("Text on your bubbles turns white or black, whichever is easier to read.")
                }
            }
            .backdropListRows()
        }
        .appBackground()
        .navigationTitle(Text("Bubble colour"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Their message and yours, as a chat will show them.
    private var preview: some View {
        VStack(spacing: 8) {
            Text("Did you make it to Sintra?")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.surface, in: BubbleShape(isFromMe: false))
                .overlay(BubbleShape(isFromMe: false).stroke(Palette.hairline, lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Just got in. The train was late again.")
                .foregroundStyle(BubbleColor.textColor(from: bubbleHex))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(BubbleColor.color(from: bubbleHex), in: BubbleShape(isFromMe: true))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of your chat bubbles"))
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { BubbleColor.color(from: bubbleHex) },
            set: { bubbleHex = $0.hexString }
        )
    }
}

private struct BubbleSwatch: View {
    let preset: BubbleColor.Preset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(BubbleColor.color(from: preset.hex))
                    .frame(width: 40, height: 40)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(BubbleColor.textColor(from: preset.hex))
                        }
                    }
                    .padding(3)
                    .overlay(
                        Circle().strokeBorder(isSelected ? Palette.ink : Color.clear, lineWidth: 2)
                    )

                Text(preset.name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(preset.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    NavigationStack { BubbleColorView() }
}
