import Foundation

public struct Vector2D: Sendable, Hashable {
    public var dx: Double
    public var dy: Double
    
    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
    
    public init(from start: Landmark, to end: Landmark) {
        self.dx = end.x - start.x
        self.dy = end.y - start.y
    }
    
    public var magnitude: Double {
        hypot(dx, dy)
    }
    
    public var normalized: Vector2D {
        let mag = magnitude
        guard mag > 1e-7 else { return Vector2D(dx: 0, dy: 0) }
        return Vector2D(dx: dx / mag, dy: dy / mag)
    }
    
    public func dot(_ other: Vector2D) -> Double {
        (dx * other.dx) + (dy * other.dy)
    }
    
    public func cosine(with other: Vector2D) -> Double {
        let denom = magnitude * other.magnitude
        guard denom > 1e-7 else { return 0.0 }
        return max(-1.0, min(1.0, dot(other) / denom))
    }
}
