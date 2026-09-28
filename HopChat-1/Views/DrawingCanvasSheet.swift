//
//  DrawingCanvasSheet.swift
//  HopChat-1
//
//  The panel for drawing something to float behind your chats: a blank card,
//  a few inks and an eraser. Done keeps the drawing; the background then shows
//  it small, drifting with the rest (see `BackgroundDrawings`).
//

import SwiftUI
import UIKit
import Combine
import PencilKit

struct DrawingCanvasSheet: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var canvas = DrawingCanvasModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DrawingCanvasView(model: canvas)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 1)
                    )
                    .accessibilityLabel(Text("Drawing area"))

                tools
            }
            .padding(16)
            .appBackground()
            .navigationTitle(Text("New drawing"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        BackgroundDrawings.shared.add(canvas.view.drawing)
                        dismiss()
                    }
                    .disabled(canvas.isEmpty)
                }
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(DrawingInk.allCases) { ink in
                let isSelected = canvas.ink == ink && !canvas.isErasing
                Button {
                    canvas.select(ink)
                } label: {
                    Circle()
                        .fill(ink.swatch)
                        .frame(width: 26, height: 26)
                        .padding(3)
                        .overlay(Circle().strokeBorder(isSelected ? Palette.ink : Color.clear, lineWidth: 2))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ink.name))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }

            Spacer(minLength: 0)

            Button {
                canvas.toggleEraser()
            } label: {
                Image(systemName: canvas.isErasing ? "eraser.fill" : "eraser")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Eraser"))
            .accessibilityAddTraits(canvas.isErasing ? [.isButton, .isSelected] : .isButton)

            Button {
                canvas.view.undoManager?.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .disabled(canvas.isEmpty)
            .accessibilityLabel(Text("Undo"))

            Button {
                canvas.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .disabled(canvas.isEmpty)
            .accessibilityLabel(Text("Clear"))
        }
    }
}

// MARK: - Inks

/// The inks on offer. PencilKit takes colours as they look in light mode and
/// adapts them to dark mode itself, so the black turns white there.
enum DrawingInk: String, CaseIterable, Identifiable {
    case black, violet, blue, green, orange, pink

    var id: String { rawValue }

    var name: String {
        switch self {
        case .black:  return String(localized: "Black")
        case .violet: return String(localized: "Violet")
        case .blue:   return String(localized: "Blue")
        case .green:  return String(localized: "Green")
        case .orange: return String(localized: "Orange")
        case .pink:   return String(localized: "Pink")
        }
    }

    var color: UIColor {
        switch self {
        case .black:  return UIColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x16 / 255, alpha: 1)
        case .violet: return UIColor(red: 0x5A / 255, green: 0x3F / 255, blue: 0xCF / 255, alpha: 1)
        case .blue:   return UIColor(red: 0x1F / 255, green: 0x6F / 255, blue: 0xEB / 255, alpha: 1)
        case .green:  return UIColor(red: 0x2F / 255, green: 0x9E / 255, blue: 0x44 / 255, alpha: 1)
        case .orange: return UIColor(red: 0xE8 / 255, green: 0x59 / 255, blue: 0x0C / 255, alpha: 1)
        case .pink:   return UIColor(red: 0xD6 / 255, green: 0x33 / 255, blue: 0x6C / 255, alpha: 1)
        }
    }

    /// How the swatch shows it: the black is the page's ink, so it turns light
    /// in dark mode just as the strokes do.
    var swatch: Color {
        self == .black ? Palette.ink : Color(uiColor: color)
    }
}

// MARK: - Canvas

/// Holds the PencilKit canvas so the buttons around it can reach it.
@MainActor
final class DrawingCanvasModel: ObservableObject {

    let view: PKCanvasView = {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        return canvas
    }()

    @Published var isEmpty = true
    @Published private(set) var ink: DrawingInk = .black
    @Published private(set) var isErasing = false

    func select(_ ink: DrawingInk) {
        self.ink = ink
        isErasing = false
        applyTool()
    }

    func toggleEraser() {
        isErasing.toggle()
        applyTool()
    }

    func clear() {
        view.drawing = PKDrawing()
        isEmpty = true
    }

    /// A pen broad enough to survive being shrunk for the background.
    func applyTool() {
        if isErasing {
            view.tool = PKEraserTool(.bitmap)
        } else {
            view.tool = PKInkingTool(.pen, color: ink.color, width: 9)
        }
    }
}

private struct DrawingCanvasView: UIViewRepresentable {
    let model: DrawingCanvasModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> PKCanvasView {
        model.view.delegate = context.coordinator
        model.applyTool()
        return model.view
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let model: DrawingCanvasModel

        init(model: DrawingCanvasModel) {
            self.model = model
        }

        nonisolated func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            MainActor.assumeIsolated {
                model.isEmpty = canvasView.drawing.strokes.isEmpty
            }
        }
    }
}

#Preview {
    DrawingCanvasSheet()
}
