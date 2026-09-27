import Foundation

/// Protocol for 2D position signal filters.
public protocol SignalFilter {
    mutating func filter(point: CGPoint, timestamp: TimeInterval) -> CGPoint
    mutating func reset()
}
