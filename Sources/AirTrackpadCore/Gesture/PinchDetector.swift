import Foundation

public enum PinchTransition: Sendable, Equatable {
    case none
    case pressed
    case released
}

/// Hysteresis pinch detector for one thumb ↔ fingertip pair.
///
/// - Separate press / release thresholds (a gap of ~0.1 palm lengths) so landmark noise
///   near a single threshold can't chatter.
/// - Two consecutive confirming frames on both edges, so a single glitched landmark frame can
///   neither fire a click nor drop a drag.
/// - "Freshness": a press only counts after the fingers were seen clearly apart, so a hand
///   that enters the frame already pinched doesn't click.
/// - Reach guard: in a fist the curled fingertip sits next to the thumb, so presses require
///   the finger to stick out from its knuckle.
public struct PinchDetector: Sendable {
    public var pressThreshold: Double
    public var releaseThreshold: Double
    public var confirmFrames: Int = 2
    public var releaseFrames: Int = 2
    public var minFingerReach: Double = 0.35

    public private(set) var isPinched: Bool = false
    /// Lightly smoothed pinch distance.
    public private(set) var distance: Double = 1.0
    /// Positive while the fingers are closing (palm lengths per second).
    public private(set) var closingSpeed: Double = 0.0
    /// Last moment the fingers were clearly open.
    public private(set) var lastOpenTime: TimeInterval?
    /// Last moment the fingers were open *and not closing*. Hand motion after this point is
    /// attributed to the pinch itself and rolled back when the press registers.
    public private(set) var lastSteadyOpenTime: TimeInterval?
    /// Moment the most recent release began (distance started opening past the press level).
    public private(set) var releaseOnsetTime: TimeInterval?

    private var armed = false
    private var belowCount = 0
    private var aboveCount = 0
    private var lastTimestamp: TimeInterval?
    private var hasValue = false

    public init(pressThreshold: Double = 0.22, releaseThreshold: Double = 0.32) {
        self.pressThreshold = pressThreshold
        self.releaseThreshold = max(releaseThreshold, pressThreshold + 0.03)
    }

    public mutating func reset() {
        isPinched = false
        distance = 1.0
        closingSpeed = 0.0
        lastOpenTime = nil
        lastSteadyOpenTime = nil
        releaseOnsetTime = nil
        armed = false
        belowCount = 0
        aboveCount = 0
        lastTimestamp = nil
        hasValue = false
    }

    /// 0 when clearly open, 1 at the press threshold.
    public var progress: Double {
        if isPinched { return 1.0 }
        let open = releaseThreshold + 0.12
        return max(0.0, min(1.0, (open - distance) / max(open - pressThreshold, 1e-6)))
    }

    /// - Parameter raw: pinch distance, or nil when the fingertips weren't actually observed this
    ///   frame. Untracked frames hold the current state and don't count toward a press or release:
    ///   one occluded fingertip must not drop a drag or fire a click.
    public mutating func update(
        distance raw: Double?,
        fingerReach: Double,
        timestamp: TimeInterval,
        allowPress: Bool = true
    ) -> PinchTransition {
        guard let raw else { return .none }
        let previous = distance
        let smoothed = hasValue ? (0.6 * raw + 0.4 * distance) : raw
        var instantaneous = 0.0
        if hasValue, let lastT = lastTimestamp, timestamp > lastT {
            instantaneous = (previous - smoothed) / (timestamp - lastT)
            closingSpeed = 0.5 * instantaneous + 0.5 * closingSpeed
        }
        hasValue = true
        distance = smoothed
        lastTimestamp = timestamp

        if !isPinched {
            if smoothed > releaseThreshold {
                armed = true
            }
            if smoothed > pressThreshold + 0.10 {
                lastOpenTime = timestamp
            }
            if smoothed > pressThreshold + 0.06 && instantaneous < 0.5 {
                lastSteadyOpenTime = timestamp
            }
            guard armed, allowPress, smoothed < pressThreshold, fingerReach >= minFingerReach else {
                belowCount = 0
                return .none
            }
            belowCount += 1
            if belowCount >= confirmFrames {
                isPinched = true
                belowCount = 0
                aboveCount = 0
                releaseOnsetTime = nil
                return .pressed
            }
            return .none
        }

        if smoothed > pressThreshold + 0.03 {
            if releaseOnsetTime == nil { releaseOnsetTime = timestamp }
        } else {
            releaseOnsetTime = nil
        }
        if smoothed > releaseThreshold {
            aboveCount += 1
            if aboveCount >= releaseFrames {
                isPinched = false
                aboveCount = 0
                armed = true
                lastOpenTime = timestamp
                return .released
            }
        } else {
            aboveCount = 0
        }
        return .none
    }

    /// Forces the detector into the released state without emitting anything (used when a
    /// higher-priority gesture takes over or tracking is lost). Requires a fresh open before
    /// the next press.
    public mutating func cancel() {
        isPinched = false
        armed = false
        belowCount = 0
        aboveCount = 0
    }
}
