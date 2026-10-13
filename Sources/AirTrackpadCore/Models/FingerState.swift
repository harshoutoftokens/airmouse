import Foundation

public enum Finger: String, CaseIterable, Sendable, Codable {
    case thumb
    case index
    case middle
    case ring
    case little
}

public enum FingerState: String, Sendable, Codable {
    case extended
    case folded
    case partiallyExtended
    case uncertain

    /// Extended or partially extended.
    public var isUp: Bool { self == .extended || self == .partiallyExtended }
}

/// Extracted geometric metrics from a single hand observation.
///
/// All distances are normalized by `handScale` (≈ palm length), so thresholds work the same
/// whether the hand is close to or far from the camera.
public struct HandMetrics: Sendable, Codable {
    public var timestamp: TimeInterval
    public var extendedFingerCount: Int
    public var fingerStates: [Finger.RawValue: FingerState]
    /// Palm center: confidence-weighted mean of the wrist and the four MCP knuckles.
    /// Stable under finger motion, so it drives swipe detection.
    public var centroid: Landmark
    /// Mean fingertip distance from the fingertip centroid (Mission Control open/pinch metric).
    public var spread: Double
    /// Thumb tip ↔ index tip distance (left click / drag pinch).
    public var pinchDistance: Double
    public var handScale: Double
    /// Thumb tip ↔ middle tip distance (right click pinch).
    public var middlePinchDistance: Double
    /// Pointing anchor on the index knuckle / proximal joint. It barely moves when the
    /// fingertip curls into a pinch, which keeps clicks from dragging the cursor away.
    public var cursorAnchor: Landmark
    /// Fingertip → MCP distance per finger (thumb: tip → index MCP). Folded fingers read
    /// ≈0.3, extended fingers ≈0.7–0.9.
    public var fingerReach: [Finger.RawValue: Double]
    /// False when either fingertip of the pinch pair wasn't actually observed this frame
    /// (low confidence or extrapolated); the pinch detector then holds its state.
    public var pinchTracked: Bool
    public var middlePinchTracked: Bool

    public init(
        timestamp: TimeInterval,
        extendedFingerCount: Int,
        fingerStates: [Finger: FingerState],
        centroid: Landmark,
        spread: Double,
        pinchDistance: Double,
        handScale: Double,
        middlePinchDistance: Double = 1.0,
        cursorAnchor: Landmark? = nil,
        fingerReach: [Finger: Double]? = nil,
        pinchTracked: Bool = true,
        middlePinchTracked: Bool = true
    ) {
        self.timestamp = timestamp
        self.extendedFingerCount = extendedFingerCount
        var states: [Finger.RawValue: FingerState] = [:]
        for (f, s) in fingerStates {
            states[f.rawValue] = s
        }
        self.fingerStates = states
        self.centroid = centroid
        self.spread = spread
        self.pinchDistance = pinchDistance
        self.handScale = handScale
        self.middlePinchDistance = middlePinchDistance
        self.pinchTracked = pinchTracked
        self.middlePinchTracked = middlePinchTracked
        self.cursorAnchor = cursorAnchor ?? centroid
        if let reach = fingerReach {
            var raw: [Finger.RawValue: Double] = [:]
            for (f, r) in reach { raw[f.rawValue] = r }
            self.fingerReach = raw
        } else {
            self.fingerReach = HandMetrics.estimatedReach(from: states)
        }
    }

    public func state(for finger: Finger) -> FingerState {
        guard let raw = fingerStates[finger.rawValue] else { return .uncertain }
        return raw
    }

    public func reach(for finger: Finger) -> Double {
        if let r = fingerReach[finger.rawValue] { return r }
        return HandMetrics.estimatedReach(for: state(for: finger))
    }

    // MARK: - Codable (tolerates recordings made before the newer fields existed)

    private enum CodingKeys: String, CodingKey {
        case timestamp, extendedFingerCount, fingerStates, centroid, spread, pinchDistance, handScale
        case middlePinchDistance, cursorAnchor, fingerReach, pinchTracked, middlePinchTracked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        extendedFingerCount = try c.decode(Int.self, forKey: .extendedFingerCount)
        fingerStates = try c.decode([Finger.RawValue: FingerState].self, forKey: .fingerStates)
        centroid = try c.decode(Landmark.self, forKey: .centroid)
        spread = try c.decode(Double.self, forKey: .spread)
        pinchDistance = try c.decode(Double.self, forKey: .pinchDistance)
        handScale = try c.decode(Double.self, forKey: .handScale)
        middlePinchDistance = try c.decodeIfPresent(Double.self, forKey: .middlePinchDistance) ?? 1.0
        cursorAnchor = try c.decodeIfPresent(Landmark.self, forKey: .cursorAnchor) ?? centroid
        fingerReach = try c.decodeIfPresent([Finger.RawValue: Double].self, forKey: .fingerReach)
            ?? HandMetrics.estimatedReach(from: fingerStates)
        pinchTracked = try c.decodeIfPresent(Bool.self, forKey: .pinchTracked) ?? true
        middlePinchTracked = try c.decodeIfPresent(Bool.self, forKey: .middlePinchTracked) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(extendedFingerCount, forKey: .extendedFingerCount)
        try c.encode(fingerStates, forKey: .fingerStates)
        try c.encode(centroid, forKey: .centroid)
        try c.encode(spread, forKey: .spread)
        try c.encode(pinchDistance, forKey: .pinchDistance)
        try c.encode(handScale, forKey: .handScale)
        try c.encode(middlePinchDistance, forKey: .middlePinchDistance)
        try c.encode(cursorAnchor, forKey: .cursorAnchor)
        try c.encode(fingerReach, forKey: .fingerReach)
        try c.encode(pinchTracked, forKey: .pinchTracked)
        try c.encode(middlePinchTracked, forKey: .middlePinchTracked)
    }

    // MARK: - Reach estimates for synthetic / legacy metrics

    static func estimatedReach(for state: FingerState) -> Double {
        switch state {
        case .extended: return 0.80
        case .partiallyExtended: return 0.58
        case .folded: return 0.30
        case .uncertain: return 0.40
        }
    }

    static func estimatedReach(from states: [Finger.RawValue: FingerState]) -> [Finger.RawValue: Double] {
        var out: [Finger.RawValue: Double] = [:]
        for finger in Finger.allCases {
            out[finger.rawValue] = estimatedReach(for: states[finger.rawValue] ?? .uncertain)
        }
        return out
    }
}
