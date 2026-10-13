import Foundation

/// Measurements of a recognized swipe stroke (palm lengths / seconds).
public struct SwipeStroke: Sendable, Equatable {
    public var direction: SwipeDirection
    public var distance: Double
    public var peakSpeed: Double
    public var duration: TimeInterval
}

/// Open-hand horizontal swipe recognizer for switching desktops.
///
/// Design notes (behaviour borrowed from Gstrl's velocity swipe and trackpad semantics):
/// - Tracks the palm center, not fingertips: fast strokes smear the fingers (motion blur at
///   30 fps) but the palm stays well localized.
/// - Requires a *fast* stroke (peak speed) that covers enough ground (distance) mostly
///   sideways (dominance) within a short window. Slow drifts and repositioning never fire.
/// - Fires mid-stroke as soon as the thresholds are crossed, so the desktop starts moving
///   while the hand is still moving.
/// - Direction-aware lockout: after a swipe, the *opposite* direction is blocked for ~1 s so
///   bringing the hand back to center can't immediately undo the switch, while the *same*
///   direction re-arms quickly to allow hopping several desktops (swipe, return, swipe).
/// - Latches through brief pose dropouts, since blur often makes the open hand read as
///   something else for a frame or two mid-swipe.
public struct SwipeDetector: Sendable {
    public var minDistance: Double = 0.75
    public var minPeakSpeed: Double = 2.6
    public var maxDuration: TimeInterval = 0.45
    public var dominance: Double = 1.6
    public var sameDirectionGap: TimeInterval = 0.40
    public var oppositeDirectionGap: TimeInterval = 0.95
    public var armFrames: Int = 2
    public var latchDuration: TimeInterval = 0.35

    private struct Sample: Sendable {
        var t: TimeInterval
        var x: Double
        var y: Double
    }

    private var samples: [Sample] = []
    private var openFrames: Int = 0
    private var lastOpenTime: TimeInterval = -.infinity
    public private(set) var lastSwipeTime: TimeInterval = -.infinity
    public private(set) var lastSwipeDirection: SwipeDirection?
    /// Short reason for the most recent rejected candidate (HUD / log telemetry).
    public private(set) var lastRejection: String?

    public init() {}

    public var isArmed: Bool { openFrames >= armFrames }

    /// Clears in-flight tracking but keeps the post-swipe lockout, so losing the hand for a
    /// moment right after a swipe can't be used to bypass return-stroke suppression.
    public mutating func reset() {
        samples.removeAll()
        openFrames = 0
        lastOpenTime = -.infinity
    }

    public mutating func update(
        pose: HandPose,
        palm: Landmark,
        scale: Double,
        timestamp t: TimeInterval
    ) -> SwipeStroke? {
        if pose == .openHand {
            openFrames += 1
            lastOpenTime = t
        } else if t - lastOpenTime > latchDuration {
            if !samples.isEmpty || openFrames > 0 {
                samples.removeAll()
                openFrames = 0
            }
            return nil
        }

        samples.append(Sample(t: t, x: palm.x, y: palm.y))
        samples.removeAll { t - $0.t > maxDuration }

        guard isArmed, samples.count >= 3, let end = samples.last else { return nil }
        let s = max(scale, 0.02)

        // Start of the stroke: the sample farthest behind the current position.
        var startIndex = 0
        var bestDx = 0.0
        for i in 0..<(samples.count - 1) {
            let dx = end.x - samples[i].x
            if abs(dx) > abs(bestDx) {
                bestDx = dx
                startIndex = i
            }
        }
        let start = samples[startIndex]
        let distance = bestDx / s
        let vertical = (end.y - start.y) / s
        guard abs(distance) >= minDistance else { return nil }
        guard abs(distance) >= dominance * abs(vertical) else {
            lastRejection = "vertical"
            return nil
        }

        // Peak horizontal speed across the stroke (central differences tame landmark noise).
        var peak = 0.0
        let lastIndex = samples.count - 1
        for i in startIndex..<lastIndex {
            let a = samples[max(startIndex, i - 1)]
            let b = samples[min(lastIndex, i + 1)]
            let dt = b.t - a.t
            guard dt > 1e-4 else { continue }
            let v = (b.x - a.x) / dt / s
            if distance > 0 { peak = max(peak, v) } else { peak = max(peak, -v) }
        }
        guard peak >= minPeakSpeed else {
            lastRejection = "slow"
            return nil
        }

        let direction: SwipeDirection = distance > 0 ? .right : .left
        if let last = lastSwipeDirection {
            let gap = t - lastSwipeTime
            let blocked = (direction == last) ? gap < sameDirectionGap : gap < oppositeDirectionGap
            if blocked {
                // Swallow this stroke entirely so it can't fire once the lockout expires.
                lastRejection = direction == last ? "repeat-lockout" : "return-stroke"
                samples = [end]
                return nil
            }
        }

        lastSwipeTime = t
        lastSwipeDirection = direction
        lastRejection = nil
        samples = [end]
        return SwipeStroke(direction: direction, distance: abs(distance), peakSpeed: peak, duration: end.t - start.t)
    }
}
