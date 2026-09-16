//
//  HorizontalPanGesture.swift
//  HopChat-1
//
//  A pan that only begins when the finger moves mostly sideways. A SwiftUI
//  `DragGesture` inside a `ScrollView` either steals vertical scrolling or
//  fights it; a UIKit recognizer can decline at the start instead, so the
//  thread keeps scrolling normally and sideways swipes still register.
//

import SwiftUI
import UIKit

struct HorizontalPanGesture: UIGestureRecognizerRepresentable {

    /// Horizontal translation in points while the finger is down.
    var onChange: (CGFloat) -> Void
    /// Final horizontal translation when the finger lifts (or the pan is cancelled → 0).
    var onEnd: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChange(x)
        case .ended:
            onEnd(x)
        case .cancelled, .failed:
            onEnd(0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}
