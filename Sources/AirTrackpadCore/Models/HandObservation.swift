import Foundation

public enum Chirality: String, Sendable, Codable {
    case left
    case right
    case unknown
}

/// A detected hand instance in a single video frame.
public struct HandObservation: Sendable, Codable {
    public var id: UUID
    public var timestamp: TimeInterval
    public var chirality: Chirality
    public var confidence: Float
    public var joints: [JointName.RawValue: Landmark]
    /// Joints the tracker extrapolated instead of observing (e.g. a fingertip hidden behind the
    /// thumb). Fine for drawing and finger-state hints, not for precise distances like pinches.
    public var synthesizedJoints: [JointName.RawValue]

    public init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        chirality: Chirality,
        confidence: Float,
        joints: [JointName: Landmark],
        synthesizedJoints: Set<JointName> = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.chirality = chirality
        self.confidence = confidence
        var rawJoints: [JointName.RawValue: Landmark] = [:]
        for (k, v) in joints {
            rawJoints[k.rawValue] = v
        }
        self.joints = rawJoints
        self.synthesizedJoints = synthesizedJoints.map(\.rawValue).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, chirality, confidence, joints, synthesizedJoints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        chirality = try c.decode(Chirality.self, forKey: .chirality)
        confidence = try c.decode(Float.self, forKey: .confidence)
        joints = try c.decode([JointName.RawValue: Landmark].self, forKey: .joints)
        synthesizedJoints = try c.decodeIfPresent([JointName.RawValue].self, forKey: .synthesizedJoints) ?? []
    }

    public func isSynthesized(_ joint: JointName) -> Bool {
        synthesizedJoints.contains(joint.rawValue)
    }

    /// Trusted and actually observed (not extrapolated).
    public func observed(_ joint: JointName, minConfidence: Float = 0.3) -> Landmark? {
        guard !isSynthesized(joint) else { return nil }
        return trusted(joint, minConfidence: minConfidence)
    }

    public func landmark(_ joint: JointName) -> Landmark? {
        joints[joint.rawValue]
    }

    /// Returns the landmark only when its confidence clears `minConfidence`.
    public func trusted(_ joint: JointName, minConfidence: Float = 0.3) -> Landmark? {
        guard let point = joints[joint.rawValue], point.confidence > minConfidence else { return nil }
        return point
    }

    /// Distance from wrist to middle finger MCP — used as a scale-invariant denominator.
    public var palmScale: Double {
        guard let wrist = landmark(.wrist),
              let middleMCP = landmark(.middleMCP) else {
            return 0.15 // Safe fallback if joints are missing
        }
        let dx = wrist.x - middleMCP.x
        let dy = wrist.y - middleMCP.y
        let dist = hypot(dx, dy)
        return max(dist, 0.02)
    }

    /// Rotation-tolerant hand size.
    ///
    /// The projected palm length (wrist → middle MCP) collapses when the palm tilts toward
    /// or away from the camera, while the knuckle width (index MCP → little MCP) collapses
    /// when the hand turns sideways. Taking the larger of the two (width rescaled by the
    /// typical width/length ratio of ~0.72) keeps every normalized distance stable across
    /// both kinds of rotation.
    public var robustScale: Double {
        var best = 0.0
        if let wrist = trusted(.wrist, minConfidence: 0.2), let middleMCP = trusted(.middleMCP, minConfidence: 0.2) {
            best = max(best, hypot(wrist.x - middleMCP.x, wrist.y - middleMCP.y))
        }
        if let indexMCP = trusted(.indexMCP, minConfidence: 0.2), let littleMCP = trusted(.littleMCP, minConfidence: 0.2) {
            best = max(best, hypot(indexMCP.x - littleMCP.x, indexMCP.y - littleMCP.y) / 0.72)
        }
        if best <= 0 {
            return palmScale
        }
        return max(best, 0.02)
    }

    /// Confidence-weighted average of the given joints, or nil when none of them is trusted.
    public func weightedCenter(_ weightedJoints: [(JointName, Double)], minConfidence: Float = 0.3) -> Landmark? {
        var sumX = 0.0, sumY = 0.0, sumW = 0.0
        var minConf: Float = 1.0
        for (joint, weight) in weightedJoints {
            guard let p = trusted(joint, minConfidence: minConfidence) else { continue }
            let w = weight * Double(p.confidence)
            sumX += p.x * w
            sumY += p.y * w
            sumW += w
            minConf = min(minConf, p.confidence)
        }
        guard sumW > 1e-9 else { return nil }
        return Landmark(x: sumX / sumW, y: sumY / sumW, z: 0.0, confidence: minConf)
    }
}
