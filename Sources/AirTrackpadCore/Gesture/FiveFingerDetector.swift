import Foundation

/// 🖐 → 🤏 → 🖐 Mission Control recognizer (open palm, gather all fingertips, open again).
///
/// The sequence clock starts when the hand starts contracting, not when the open palm first
/// appears, so resting an open hand (e.g. before a swipe) never times out into a false start.
/// After the open phase only the fingertip spread is used: bunching the fingers together
/// changes the finger classification, so the pose cannot be relied on mid-sequence. Moving
/// on to a different deliberate pose (pointing, scrolling) abandons the sequence at once.
public struct FiveFingerDetector: Sendable {
    public enum Phase: String, Sendable {
        case idle, open, contracting, armed, expanding
    }

    public var openThreshold: Double = 0.40
    public var pinchThreshold: Double = 0.22
    public var maxSequenceDuration: TimeInterval = 1.4
    public var minSequenceDuration: TimeInterval = 0.12

    public private(set) var phase: Phase = .idle
    private var sequenceStart: TimeInterval?
    private var lastOpenTime: TimeInterval = 0
    private var smoothedSpread: Double?

    public init() {}

    /// True once the fingertips have been gathered; other gestures stand down until the
    /// sequence completes or times out.
    public var isEngaged: Bool {
        phase == .armed || phase == .expanding
    }

    /// True from the moment an open palm starts closing. Pinch-clicks are held off during this
    /// window because gathering five fingertips also brings the thumb and index together.
    public var isGathering: Bool {
        phase == .contracting || isEngaged
    }

    public mutating func reset() {
        phase = .idle
        sequenceStart = nil
        smoothedSpread = nil
    }

    /// Returns true on the frame the sequence completes.
    public mutating func update(
        pose: HandPose,
        thumbUp: Bool,
        spread rawSpread: Double,
        timestamp t: TimeInterval
    ) -> Bool {
        let spread = smoothedSpread.map { 0.6 * rawSpread + 0.4 * $0 } ?? rawSpread
        smoothedSpread = spread

        if let start = sequenceStart, t - start > maxSequenceDuration {
            reset()
            smoothedSpread = spread
        }

        let isOpenPalm = pose == .openHand && thumbUp
        let abandons = pose == .pointing || pose == .scroll

        switch phase {
        case .idle:
            if isOpenPalm && spread >= openThreshold {
                phase = .open
                lastOpenTime = t
            }
        case .open:
            if abandons {
                reset()
                smoothedSpread = spread
            } else if spread >= openThreshold - 0.06 {
                lastOpenTime = t
            } else {
                phase = .contracting
                sequenceStart = lastOpenTime
            }
        case .contracting:
            if abandons {
                reset()
                smoothedSpread = spread
            } else if spread <= pinchThreshold {
                phase = .armed
            } else if spread >= openThreshold {
                phase = .open
                sequenceStart = nil
                lastOpenTime = t
            }
        case .armed:
            if spread > pinchThreshold + 0.06 {
                phase = .expanding
            }
        case .expanding:
            if spread >= openThreshold {
                let duration = t - (sequenceStart ?? t)
                reset()
                smoothedSpread = spread
                if duration >= minSequenceDuration {
                    return true
                }
            } else if spread <= pinchThreshold {
                phase = .armed
            }
        }
        return false
    }
}
