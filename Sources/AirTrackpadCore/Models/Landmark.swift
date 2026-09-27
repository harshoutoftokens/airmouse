import Foundation

/// The 21 standard anatomical hand joints supported by the tracking pipeline.
public enum JointName: String, CaseIterable, Sendable, Hashable {
    case wrist
    
    // Thumb
    case thumbCMC
    case thumbMP
    case thumbIP
    case thumbTip
    
    // Index Finger
    case indexMCP
    case indexPIP
    case indexDIP
    case indexTip
    
    // Middle Finger
    case middleMCP
    case middlePIP
    case middleDIP
    case middleTip
    
    // Ring Finger
    case ringMCP
    case ringPIP
    case ringDIP
    case ringTip
    
    // Little Finger (Pinky)
    case littleMCP
    case littlePIP
    case littleDIP
    case littleTip
}

/// A normalized 2D/3D hand landmark.
/// Coordinates are in normalized space [0.0, 1.0], where (0,0) is bottom-left and (1,1) is top-right.
public struct Landmark: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var confidence: Float
    
    public init(x: Double, y: Double, z: Double = 0.0, confidence: Float = 1.0) {
        self.x = x
        self.y = y
        self.z = z
        self.confidence = confidence
    }
    
    public var point: CGPoint {
        CGPoint(x: x, y: y)
    }
}
