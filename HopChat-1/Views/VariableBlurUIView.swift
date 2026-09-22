//
//  VariableBlurUIView.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 18/09/2026.
//


import SwiftUI
import UIKit

/// A blur whose radius varies per-pixel, driven by a gradient mask —
/// the same private CAFilter Apple's own apps use for edge-of-scroll
/// dissolve effects. Falls back to a plain blur if the filter is
/// unavailable (e.g. a future OS removes it).
final class VariableBlurUIView: UIVisualEffectView {

    init(maxBlurRadius: CGFloat = 20, direction: GradientDirection = .topToBottom) {
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))

        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let variableBlur = filterClass.perform(
                  NSSelectorFromString("filterWithType:"),
                  with: "variableBlur"
              )?.takeUnretainedValue() as? NSObject
        else {
            // Private API missing — leave a uniform blur rather than crash.
            return
        }

        variableBlur.setValue(maxBlurRadius, forKey: "inputRadius")
        variableBlur.setValue(Self.maskImage(direction: direction), forKey: "inputMaskImage")
        variableBlur.setValue(true, forKey: "inputNormalizeEdges")

        // The backdrop layer is the one actually compositing the blur.
        if let backdropLayer = subviews.first?.layer {
            backdropLayer.filters = [variableBlur]
        }
    }

    required init?(coder: NSCoder) { nil }

    enum GradientDirection {
        case topToBottom, bottomToTop
    }

    /// White = full blur radius, black = no blur. UIKit reads this as a
    /// per-pixel multiplier on inputRadius.
    private static func maskImage(direction: GradientDirection) -> CGImage? {
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let colors = [UIColor.white.cgColor, UIColor.black.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                       colors: colors,
                                       locations: [0, 1])!
            let start = direction == .topToBottom ? CGPoint(x: 50, y: 0) : CGPoint(x: 50, y: 100)
            let end = direction == .topToBottom ? CGPoint(x: 50, y: 100) : CGPoint(x: 50, y: 0)
            ctx.cgContext.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
        return image.cgImage
    }
}

struct VariableBlur: UIViewRepresentable {
    var maxBlurRadius: CGFloat = 20

    func makeUIView(context: Context) -> VariableBlurUIView {
        VariableBlurUIView(maxBlurRadius: maxBlurRadius, direction: .topToBottom)
    }

    func updateUIView(_ uiView: VariableBlurUIView, context: Context) {}
}
