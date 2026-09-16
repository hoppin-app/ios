//
//  FluidScroll.swift
//  HopChat-1
//
//  The springy bubble effect: while a thread scrolls, rows trail behind in
//  proportion to their distance from the middle of the screen, so the list
//  gently compresses ahead of the motion and spreads behind it, then wobbles
//  back into place when scrolling stops.
//
//  One under-damped spring is simulated per thread (not per row) on a display
//  link that only runs while there is motion. Rows read the spring's value and
//  apply it as a pure visual offset, so layout and hit-testing are untouched.
//

import SwiftUI
import QuartzCore
import Observation

@Observable
final class FluidScrollModel {

    /// Current spring displacement in points; rows scale it by distance.
    private(set) var displacement: CGFloat = 0

    @ObservationIgnored var viewportHeight: CGFloat = 1
    /// Off under Reduce Motion.
    @ObservationIgnored var isEnabled = true

    @ObservationIgnored private var springVelocity: CGFloat = 0
    @ObservationIgnored private var scrollVelocity: CGFloat = 0
    @ObservationIgnored private var lastOffset: CGFloat?
    @ObservationIgnored private var lastOffsetTime: CFTimeInterval = 0
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var link: CADisplayLink?

    /// Points of displacement per point/second of scroll speed.
    private static let gain: CGFloat = 0.009
    private static let maxDisplacement: CGFloat = 22
    private static let stiffness: CGFloat = 170
    /// Below critical damping (2·√170 ≈ 26) so it overshoots a little.
    private static let damping: CGFloat = 15
    /// Offset jumps larger than this are programmatic (scroll-to-bottom,
    /// keyboard) rather than a finger, and don't excite the spring.
    private static let maxFrameJump: CGFloat = 250

    /// Feed every content-offset change here.
    func scrolled(to offset: CGFloat) {
        let now = CACurrentMediaTime()
        defer {
            lastOffset = offset
            lastOffsetTime = now
        }
        guard isEnabled, let last = lastOffset else { return }
        let delta = offset - last
        let dt = now - lastOffsetTime
        guard dt > 0.001, abs(delta) < Self.maxFrameJump else { return }

        let instant = delta / CGFloat(dt)
        scrollVelocity = scrollVelocity * 0.5 + instant * 0.5
        startLink()
    }

    func stop() {
        link?.invalidate()
        link = nil
        displacement = 0
        springVelocity = 0
        scrollVelocity = 0
    }

    // MARK: Simulation

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(self),
                                 selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        lastTick = CACurrentMediaTime()
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(min(max(now - lastTick, 1.0 / 240), 1.0 / 30))
        lastTick = now

        // No offset change for a few frames: the scroll has come to rest.
        if CACurrentMediaTime() - lastOffsetTime > 0.04 { scrollVelocity = 0 }

        let limit = Self.maxDisplacement
        let target = min(max(scrollVelocity * Self.gain, -limit), limit)
        let force = -Self.stiffness * (displacement - target) - Self.damping * springVelocity
        springVelocity += force * dt
        let next = min(max(displacement + springVelocity * dt, -limit * 1.3), limit * 1.3)

        if scrollVelocity == 0, abs(next) < 0.05, abs(springVelocity) < 0.5 {
            stop()
            return
        }
        displacement = next
    }
}

/// CADisplayLink retains its target; this keeps the model free to deallocate
/// and shuts the link down if it does.
private final class DisplayLinkTarget: NSObject {
    weak var model: FluidScrollModel?

    init(_ model: FluidScrollModel) { self.model = model }

    @objc func tick(_ link: CADisplayLink) {
        guard let model else {
            link.invalidate()
            return
        }
        model.tick(link)
    }
}

// MARK: - Row modifier

private struct FluidScrollOffset: ViewModifier {
    let model: FluidScrollModel

    func body(content: Content) -> some View {
        let displacement = model.displacement
        let half = max(model.viewportHeight / 2, 1)
        return content.visualEffect { effect, proxy in
            let distance = min(abs(proxy.frame(in: .scrollView).midY - half) / half, 1.25)
            return effect.offset(y: displacement * distance)
        }
    }
}

extension View {
    /// Makes this row part of a thread's springy scroll.
    func fluidScrollRow(_ model: FluidScrollModel) -> some View {
        modifier(FluidScrollOffset(model: model))
    }

    /// Feeds a scroll view's motion into `model`.
    func fluidScrollSource(_ model: FluidScrollModel, enabled: Bool) -> some View {
        self
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in
                model.scrolled(to: offset)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, height in
                model.viewportHeight = height
            }
            .onAppear { model.isEnabled = enabled }
            .onChange(of: enabled) { _, on in
                model.isEnabled = on
                if !on { model.stop() }
            }
            .onDisappear { model.stop() }
    }
}
