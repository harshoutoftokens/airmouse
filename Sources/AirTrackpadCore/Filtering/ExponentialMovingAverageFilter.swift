import Foundation

/// Exponential Moving Average filter.
public struct ExponentialMovingAverageFilter: SignalFilter {
    public var alpha: Double
    private var lastPoint: CGPoint?
    
    public init(alpha: Double = 0.5) {
        self.alpha = max(0.01, min(0.99, alpha))
    }
    
    public mutating func reset() {
        lastPoint = nil
    }
    
    public mutating func filter(point: CGPoint, timestamp: TimeInterval) -> CGPoint {
        guard let prev = lastPoint else {
            lastPoint = point
            return point
        }
        let filteredX = alpha * Double(point.x) + (1.0 - alpha) * Double(prev.x)
        let filteredY = alpha * Double(point.y) + (1.0 - alpha) * Double(prev.y)
        let result = CGPoint(x: filteredX, y: filteredY)
        lastPoint = result
        return result
    }
}
