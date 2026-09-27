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
    
    public init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        chirality: Chirality,
        confidence: Float,
        joints: [JointName: Landmark]
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
    }
    
    public func landmark(_ joint: JointName) -> Landmark? {
        joints[joint.rawValue]
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
}
