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
}

/// Extracted geometric metrics from a single hand observation.
public struct HandMetrics: Sendable, Codable {
    public var timestamp: TimeInterval
    public var extendedFingerCount: Int
    public var fingerStates: [Finger.RawValue: FingerState]
    public var centroid: Landmark
    public var spread: Double
    public var pinchDistance: Double
    public var handScale: Double
    
    public init(
        timestamp: TimeInterval,
        extendedFingerCount: Int,
        fingerStates: [Finger: FingerState],
        centroid: Landmark,
        spread: Double,
        pinchDistance: Double,
        handScale: Double
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
    }
    
    public func state(for finger: Finger) -> FingerState {
        guard let raw = fingerStates[finger.rawValue] else { return .uncertain }
        return raw
    }
}
