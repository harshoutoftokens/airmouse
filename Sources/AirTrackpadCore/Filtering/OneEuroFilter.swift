import Foundation

/// 1D One Euro Filter implementation based on Casiez et al. (CHI 2012).
public struct OneEuroFilter1D {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double
    
    private var xPrev: Double?
    private var dxPrev: Double = 0.0
    private var tPrev: TimeInterval?
    
    public init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }
    
    public mutating func reset() {
        xPrev = nil
        dxPrev = 0.0
        tPrev = nil
    }
    
    public mutating func filter(value: Double, timestamp: TimeInterval) -> Double {
        guard let tPrev = tPrev, let xPrev = xPrev else {
            self.xPrev = value
            self.tPrev = timestamp
            return value
        }
        
        let dt = timestamp - tPrev
        guard dt > 1e-5 else { return xPrev }
        
        // Compute discrete derivative (velocity)
        let dx = (value - xPrev) / dt
        let aD = alpha(cutoff: dCutoff, dt: dt)
        let dxHat = aD * dx + (1.0 - aD) * dxPrev
        self.dxPrev = dxHat
        
        // Filter signal using adaptive cutoff
        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(cutoff: cutoff, dt: dt)
        let xHat = a * value + (1.0 - a) * xPrev
        
        self.xPrev = xHat
        self.tPrev = timestamp
        return xHat
    }
    
    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * max(cutoff, 1e-4))
        return 1.0 / (1.0 + tau / dt)
    }
}

/// 2D One Euro Filter for smooth, low-latency cursor tracking.
public struct OneEuroFilter: SignalFilter {
    public var filterX: OneEuroFilter1D
    public var filterY: OneEuroFilter1D
    
    public init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.filterX = OneEuroFilter1D(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        self.filterY = OneEuroFilter1D(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }
    
    public mutating func reset() {
        filterX.reset()
        filterY.reset()
    }
    
    public mutating func updateCoefficients(minCutoff: Double, beta: Double) {
        filterX.minCutoff = minCutoff
        filterX.beta = beta
        filterY.minCutoff = minCutoff
        filterY.beta = beta
    }
    
    public mutating func filter(point: CGPoint, timestamp: TimeInterval) -> CGPoint {
        let x = filterX.filter(value: Double(point.x), timestamp: timestamp)
        let y = filterY.filter(value: Double(point.y), timestamp: timestamp)
        return CGPoint(x: x, y: y)
    }
}

/// Isotropic 2D One Euro filter for hand landmarks.
///
/// Differences from running two 1D filters:
/// - One cutoff for both axes, driven by the 2D speed, so diagonal motion isn't distorted.
/// - Speed is divided by `speedScale` (the hand size in normalized image units) before it
///   adapts the cutoff, which makes `beta` mean "per palm length per second" — the same feel
///   whether the hand is 40 cm or 90 cm from the camera.
public struct HandOneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    public private(set) var value: CGPoint?
    /// Filtered speed in palm lengths per second.
    public private(set) var speed: Double = 0.0
    private var dx: Double = 0.0
    private var dy: Double = 0.0
    private var lastTimestamp: TimeInterval?

    public init(minCutoff: Double = 1.4, beta: Double = 1.2, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public mutating func reset() {
        value = nil
        speed = 0.0
        dx = 0.0
        dy = 0.0
        lastTimestamp = nil
    }

    public mutating func filter(_ point: CGPoint, speedScale: Double, timestamp: TimeInterval) -> CGPoint {
        guard let previous = value, let lastT = lastTimestamp else {
            value = point
            lastTimestamp = timestamp
            return point
        }
        let dt = timestamp - lastT
        guard dt > 1e-5 else { return previous }
        // Drop the derivative history across long gaps (hand reacquired) instead of treating
        // the jump as a flick.
        if dt > 0.25 {
            value = point
            lastTimestamp = timestamp
            dx = 0
            dy = 0
            speed = 0
            return point
        }

        let aD = HandOneEuroFilter.alpha(cutoff: dCutoff, dt: dt)
        dx = aD * (Double(point.x - previous.x) / dt) + (1 - aD) * dx
        dy = aD * (Double(point.y - previous.y) / dt) + (1 - aD) * dy
        speed = hypot(dx, dy) / max(speedScale, 0.02)

        let cutoff = minCutoff + beta * speed
        let a = HandOneEuroFilter.alpha(cutoff: cutoff, dt: dt)
        let filtered = CGPoint(
            x: a * Double(point.x) + (1 - a) * Double(previous.x),
            y: a * Double(point.y) + (1 - a) * Double(previous.y)
        )
        value = filtered
        lastTimestamp = timestamp
        return filtered
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * max(cutoff, 1e-4))
        return 1.0 / (1.0 + tau / dt)
    }
}
