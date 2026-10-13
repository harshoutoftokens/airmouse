import Foundation
import CoreGraphics

public enum CursorMode: String, Codable, Sendable, CaseIterable {
    /// Trackpad-style: hand *motion* moves the pointer, with pointer acceleration. Making a
    /// fist (or any non-pointing shape) is the "lift": reposition the hand, the pointer stays.
    case relative
    /// Direct: hand *position* inside a calibration box maps onto the screen.
    case absolute
}

/// Speed-dependent pointer gain, the same idea as macOS pointer acceleration: slow hand
/// motion gets low gain for precise targeting, fast motion gets high gain to cross the screen
/// without sweeping the arm.
public struct PointerAcceleration: Sendable, Equatable {
    /// Points of pointer travel per palm length of hand travel at gain 1.0.
    public var basePointsPerPalm: Double = 700
    public var speedMultiplier: Double = 1.0
    public var minGain: Double = 0.55
    public var maxGain: Double = 1.56
    /// Hand speed (palm lengths/s) where the gain starts rising.
    public var lowSpeed: Double = 0.5
    /// Hand speed (palm lengths/s) where the gain saturates.
    public var highSpeed: Double = 4.0

    public init() {}

    /// `acceleration` 0 = linear, 1 = strongest curve.
    public init(speed: Double, acceleration: Double) {
        let a = max(0.0, min(1.0, acceleration))
        speedMultiplier = max(0.1, speed)
        minGain = 1.0 - 0.65 * a
        maxGain = 1.0 + 0.80 * a
    }

    /// Points per palm length at hand speed `v` (palm lengths per second).
    public func gain(forSpeed v: Double) -> Double {
        let t = max(0.0, min(1.0, (v - lowSpeed) / max(highSpeed - lowSpeed, 1e-6)))
        let eased = t * t * (3 - 2 * t)
        return basePointsPerPalm * speedMultiplier * (minGain + (maxGain - minGain) * eased)
    }
}

/// Turns the pinch-stable hand anchor into pointer motion.
///
/// The engine always runs its filter (so it stays warm while the pointer is frozen) and
/// reports what the pointer *would* do; the gesture state machine decides when motion is
/// actually emitted and records it, which is what makes click rollback possible.
public final class CursorEngine: @unchecked Sendable {
    public struct Sample: Sendable {
        /// Filtered anchor in normalized image coordinates (x toward the user's right, y up).
        public var filteredAnchor: CGPoint
        /// Relative mode: pointer motion for this frame in points.
        public var delta: CGVector
        /// Absolute mode: pointer target in global points.
        public var target: CGPoint?
        /// Filtered hand speed in palm lengths per second.
        public var speed: Double
        /// Smoothed hand scale (normalized image units per palm length).
        public var scale: Double
    }

    public var mode: CursorMode = .relative
    public var acceleration = PointerAcceleration()
    public var filter = HandOneEuroFilter(minCutoff: 1.4, beta: 1.2)
    /// Relative mode: hand speeds below this (palm lengths/s) are treated as tremor.
    public var restSpeed: Double = 0.08
    /// Absolute mode mapping.
    public var mapper: ScreenMapper
    /// Absolute mode: stationary dead zone radius in points.
    public var leashRadius: Double = 1.5

    private var smoothedScale: Double?
    private var lastFiltered: CGPoint?
    private var lastTimestamp: TimeInterval?
    private var leashed: CGPoint?
    private var emitted: [(t: TimeInterval, dx: Double, dy: Double)] = []
    private var targets: [(t: TimeInterval, p: CGPoint)] = []
    private let historyWindow: TimeInterval = 0.6
    private let lock = NSLock()

    public init(mapper: ScreenMapper = ScreenMapper()) {
        self.mapper = mapper
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        filter.reset()
        smoothedScale = nil
        lastFiltered = nil
        lastTimestamp = nil
        leashed = nil
        emitted.removeAll()
        targets.removeAll()
    }

    /// Processes one frame.
    /// - Parameters:
    ///   - gainMultiplier: scales relative motion (used to calm the pointer while a pinch closes).
    ///   - leashBoost: extra absolute-mode dead zone in points (grows as a pinch closes).
    public func update(
        anchor: Landmark,
        scale rawScale: Double,
        timestamp: TimeInterval,
        gainMultiplier: Double = 1.0,
        leashBoost: Double = 0.0
    ) -> Sample {
        lock.lock()
        defer { lock.unlock() }

        // Hand size changes slowly; smoothing it keeps it from injecting jitter into the gain.
        let s: Double
        if let prev = smoothedScale, let lastT = lastTimestamp, timestamp > lastT, timestamp - lastT < 0.5 {
            let a = 1.0 - exp(-(timestamp - lastT) / 0.4)
            s = prev + a * (max(rawScale, 0.02) - prev)
        } else {
            s = max(rawScale, 0.02)
        }
        smoothedScale = s

        let filtered = filter.filter(CGPoint(x: anchor.x, y: anchor.y), speedScale: s, timestamp: timestamp)
        defer {
            lastFiltered = filtered
            lastTimestamp = timestamp
        }

        var delta = CGVector.zero
        var target: CGPoint?

        switch mode {
        case .relative:
            if let prev = lastFiltered, let lastT = lastTimestamp, timestamp > lastT, timestamp - lastT < 0.25 {
                let dt = timestamp - lastT
                let ux = Double(filtered.x - prev.x) / s
                let uy = Double(filtered.y - prev.y) / s
                let instantaneous = hypot(ux, uy) / dt
                // Soft speed dead zone: subtracting (rather than gating) keeps motion
                // continuous right at the threshold.
                let keep = instantaneous > restSpeed ? (instantaneous - restSpeed) / instantaneous : 0.0
                let g = acceleration.gain(forSpeed: filter.speed) * keep * max(0.0, gainMultiplier)
                // Image y grows upward, screen y grows downward.
                delta = CGVector(dx: ux * g, dy: -uy * g)
            }
        case .absolute:
            let raw = mapper.mapToScreen(normalizedX: Double(filtered.x), normalizedY: Double(filtered.y))
            let radius = leashRadius + max(0.0, leashBoost)
            if let current = leashed {
                let d = hypot(raw.x - current.x, raw.y - current.y)
                if d > radius {
                    let k = radius / d
                    leashed = CGPoint(x: raw.x + (current.x - raw.x) * k, y: raw.y + (current.y - raw.y) * k)
                }
            } else {
                leashed = raw
            }
            target = leashed
        }

        return Sample(filteredAnchor: filtered, delta: delta, target: target, speed: filter.speed, scale: s)
    }

    /// Records relative motion that was actually sent to the pointer.
    public func recordEmitted(_ delta: CGVector, at t: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        emitted.append((t, Double(delta.dx), Double(delta.dy)))
        emitted.removeAll { t - $0.t > historyWindow }
    }

    /// Records an absolute target that was actually sent to the pointer.
    public func recordTarget(_ p: CGPoint, at t: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        targets.append((t, p))
        targets.removeAll { t - $0.t > historyWindow }
    }

    /// Sum of the relative motion emitted after `t`.
    public func emittedMotion(since t: TimeInterval) -> CGVector {
        lock.lock()
        defer { lock.unlock() }
        var dx = 0.0, dy = 0.0
        for e in emitted where e.t > t {
            dx += e.dx
            dy += e.dy
        }
        return CGVector(dx: dx, dy: dy)
    }

    /// Most recent absolute target emitted at or before `t`.
    public func target(at t: TimeInterval) -> CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        return targets.last(where: { $0.t <= t })?.p ?? targets.first?.p
    }

    /// Forgets the absolute-mode leash so the next frame snaps straight to the hand.
    public func resetLeash() {
        lock.lock()
        defer { lock.unlock() }
        leashed = nil
    }

    public var currentScale: Double {
        lock.lock()
        defer { lock.unlock() }
        return smoothedScale ?? 0.15
    }
}
