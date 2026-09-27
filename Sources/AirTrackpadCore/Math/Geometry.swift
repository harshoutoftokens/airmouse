import Foundation

public enum Geometry {
    /// Euclidean distance between two landmarks.
    @inlinable
    public static func distance(_ p1: Landmark, _ p2: Landmark) -> Double {
        hypot(p1.x - p2.x, p1.y - p2.y)
    }
    
    /// Normalized distance scaled by the palm size.
    @inlinable
    public static func normalizedDistance(_ p1: Landmark, _ p2: Landmark, palmScale: Double) -> Double {
        let raw = distance(p1, p2)
        let scale = max(palmScale, 0.02)
        return raw / scale
    }
    
    /// Computes the centroid of a collection of landmarks.
    public static func centroid(of points: [Landmark]) -> Landmark {
        guard !points.isEmpty else {
            return Landmark(x: 0.5, y: 0.5, z: 0.0, confidence: 0.0)
        }
        var sumX = 0.0
        var sumY = 0.0
        var sumZ = 0.0
        var sumConf: Float = 0.0
        
        for pt in points {
            sumX += pt.x
            sumY += pt.y
            sumZ += pt.z
            sumConf += pt.confidence
        }
        let count = Double(points.count)
        return Landmark(
            x: sumX / count,
            y: sumY / count,
            z: sumZ / count,
            confidence: sumConf / Float(points.count)
        )
    }
    
    /// Computes the normalized spread: average distance of all provided landmarks from their centroid, divided by palmScale.
    public static func spread(of points: [Landmark], palmScale: Double) -> Double {
        guard points.count >= 2 else { return 0.0 }
        let c = centroid(of: points)
        var sumDist = 0.0
        for pt in points {
            sumDist += distance(pt, c)
        }
        let avgDist = sumDist / Double(points.count)
        let scale = max(palmScale, 0.02)
        return avgDist / scale
    }
}
