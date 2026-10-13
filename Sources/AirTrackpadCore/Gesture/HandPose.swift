import Foundation

/// Coarse hand shape used to pick the active gesture family.
public enum HandPose: String, Sendable, Codable {
    /// No hand in view.
    case none
    /// ☝ Index up, middle/ring/little down — moves the cursor.
    case pointing
    /// ✌ Index + middle up, ring/little down — scrolls.
    case scroll
    /// 🖐 Index, middle, ring and little up — desktop swipes and Mission Control.
    case openHand
    /// ✊ Nothing up — "clutch": the cursor stays put while the hand repositions.
    case fist
    /// Anything else (transitional or ambiguous shapes). Freezes the cursor.
    case other
}

/// Frame-level pose classification from finger states plus fingertip reach.
///
/// Reach (tip ↔ knuckle distance in palm lengths) backs up the state classifier: a loosely
/// half-curled middle finger can read as "partially extended", and treating that as "up"
/// would turn every relaxed pointing hand into a scroll gesture.
public enum PoseClassifier {
    public static func classify(_ m: HandMetrics) -> HandPose {
        let index = m.state(for: .index)
        let middle = m.state(for: .middle)
        let ring = m.state(for: .ring)
        let little = m.state(for: .little)

        let indexUp = index.isUp && m.reach(for: .index) >= 0.45
        let middleUp = middle.isUp && m.reach(for: .middle) >= 0.45
        let middleClearlyUp = middle == .extended && m.reach(for: .middle) >= 0.50
        let ringUp = ring.isUp && m.reach(for: .ring) >= 0.40
        let littleUp = little.isUp && m.reach(for: .little) >= 0.35

        let extendedOfFour = [index, middle, ring, little].filter { $0 == .extended }.count

        if indexUp && middleUp && ringUp && littleUp && extendedOfFour >= 3 {
            return .openHand
        }
        if indexUp && middleClearlyUp && ring != .extended && little != .extended {
            return .scroll
        }
        if indexUp && !middleClearlyUp && ring != .extended && little != .extended {
            return .pointing
        }
        if !indexUp && !middleUp && !ringUp && !littleUp {
            return .fist
        }
        return .other
    }
}

/// Debounces pose changes: a new pose must persist for a few consecutive frames before it
/// replaces the stable one. Transitions that would be costly to get wrong (pointing ↔ scroll,
/// leaving the open hand mid-swipe when motion blur smears the fingers) need more evidence.
public struct PoseStabilizer: Sendable {
    public private(set) var stable: HandPose = .none
    public private(set) var framesInStable: Int = 0
    private var candidate: HandPose = .none
    private var candidateFrames: Int = 0

    public init() {}

    public mutating func reset() {
        stable = .none
        framesInStable = 0
        candidate = .none
        candidateFrames = 0
    }

    @discardableResult
    public mutating func update(_ raw: HandPose) -> HandPose {
        if raw == stable {
            candidate = raw
            candidateFrames = 0
            framesInStable += 1
            return stable
        }
        if raw == candidate {
            candidateFrames += 1
        } else {
            candidate = raw
            candidateFrames = 1
        }
        if candidateFrames >= PoseStabilizer.requiredFrames(from: stable, to: raw) {
            stable = raw
            framesInStable = 1
            candidateFrames = 0
        }
        return stable
    }

    static func requiredFrames(from: HandPose, to: HandPose) -> Int {
        switch (from, to) {
        case (.pointing, .scroll), (.scroll, .pointing):
            return 3
        case (.openHand, _):
            return 3
        case (.none, _):
            return 2
        default:
            return 2
        }
    }
}
