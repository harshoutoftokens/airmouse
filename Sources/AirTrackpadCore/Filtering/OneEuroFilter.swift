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
    
    public mutating func filter(point: CGPoint, timestamp: TimeInterval) -> CGPoint {
        let x = filterX.filter(value: Double(point.x), timestamp: timestamp)
        let y = filterY.filter(value: Double(point.y), timestamp: timestamp)
        return CGPoint(x: x, y: y)
    }
}
