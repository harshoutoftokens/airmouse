import Foundation
import CoreGraphics
@testable import AirTrackpadCore

/// Builds synthetic per-frame hand data for state-machine tests.
struct SyntheticHand {
    static let pointing: Set<Finger> = [.index]
    static let scroll: Set<Finger> = [.index, .middle]
    static let openHand: Set<Finger> = [.index, .middle, .ring, .little]
    static let openPalm: Set<Finger> = [.thumb, .index, .middle, .ring, .little]
    static let fist: Set<Finger> = []

    var fingers: Set<Finger> = SyntheticHand.pointing
    /// Fingers reported as partially extended (curled toward the thumb, still reaching out).
    var partial: Set<Finger> = []
    /// Palm center (normalized, x toward the user's right, y up).
    var palm = CGPoint(x: 0.5, y: 0.4)
    var pinch: Double = 0.6
    var middlePinch: Double = 0.8
    var spread: Double = 0.30
    var scale: Double = 0.15
    /// false = the thumb/index tips weren't actually observed this frame.
    var pinchTracked = true

    func frame(at t: TimeInterval) -> (HandObservation, HandMetrics) {
        var states: [Finger: FingerState] = [:]
        for finger in Finger.allCases {
            states[finger] = fingers.contains(finger) ? .extended : (partial.contains(finger) ? .partiallyExtended : .folded)
        }
        let anchor = Landmark(x: palm.x, y: palm.y + scale * 0.5)
        let hand = HandObservation(
            timestamp: t,
            chirality: .right,
            confidence: 0.95,
            joints: [
                .wrist: Landmark(x: palm.x, y: palm.y - scale * 0.5),
                .middleMCP: Landmark(x: palm.x, y: palm.y + scale * 0.5)
            ]
        )
        let metrics = HandMetrics(
            timestamp: t,
            extendedFingerCount: fingers.count,
            fingerStates: states,
            centroid: Landmark(x: palm.x, y: palm.y),
            spread: spread,
            pinchDistance: pinch,
            handScale: scale,
            middlePinchDistance: middlePinch,
            cursorAnchor: anchor,
            pinchTracked: pinchTracked
        )
        return (hand, metrics)
    }
}

/// Drives a state machine with synthetic frames at a fixed frame rate.
final class FrameDriver {
    let machine: GestureStateMachine
    private(set) var t: TimeInterval
    let dt: TimeInterval
    private(set) var events: [AbstractGestureEvent] = []

    init(machine: GestureStateMachine = GestureStateMachine(), start: TimeInterval = 10.0, fps: Double = 30.0) {
        self.machine = machine
        self.t = start
        self.dt = 1.0 / fps
    }

    /// Feeds `count` frames of `hand`, applying `change` before each one. Returns the events
    /// emitted during these frames.
    @discardableResult
    func feed(_ hand: SyntheticHand, frames count: Int = 1, change: ((inout SyntheticHand, Int) -> Void)? = nil) -> [AbstractGestureEvent] {
        var current = hand
        var out: [AbstractGestureEvent] = []
        for i in 0..<count {
            change?(&current, i)
            let (h, m) = current.frame(at: t)
            out += machine.process(hand: h, metrics: m, timestamp: t)
            t += dt
        }
        events += out
        return out
    }

    @discardableResult
    func feedNoHand(frames count: Int) -> [AbstractGestureEvent] {
        var out: [AbstractGestureEvent] = []
        for _ in 0..<count {
            out += machine.process(hand: nil, metrics: nil, timestamp: t)
            t += dt
        }
        events += out
        return out
    }

    func advance(by seconds: TimeInterval) {
        t += seconds
    }
}

extension Array where Element == AbstractGestureEvent {
    var clicks: [Int] {
        compactMap { if case .leftClick(let c) = $0 { return c } else { return nil } }
    }
    var switches: [SwipeDirection] {
        compactMap { if case .switchSpace(let d) = $0 { return d } else { return nil } }
    }
    var pointerTotal: CGVector {
        var dx = 0.0, dy = 0.0
        for e in self {
            if case .pointerDelta(let x, let y) = e {
                dx += x
                dy += y
            }
        }
        return CGVector(dx: dx, dy: dy)
    }
    var hasPointerMotion: Bool {
        contains { if case .pointerDelta = $0 { return true } else { return false } }
    }
    func count(_ match: AbstractGestureEvent) -> Int {
        filter { $0 == match }.count
    }
    var scrollPhases: [ScrollPhase] {
        compactMap { if case .scroll(_, _, let p) = $0 { return p } else { return nil } }
    }
    var scrollTotalY: Double {
        reduce(0.0) { acc, e in
            if case .scroll(_, let dy, _) = e { return acc + dy }
            return acc
        }
    }
}
