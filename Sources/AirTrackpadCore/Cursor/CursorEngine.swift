import Foundation
import CoreGraphics

/// Engine translating raw index fingertip landmarks into smooth, jitter-free cursor events.
public final class CursorEngine: @unchecked Sendable {
    public var mapper: ScreenMapper
    public var filter: OneEuroFilter
    public var deadZonePixels: Double
    
    private var lastScreenPoint: CGPoint?
    private let lock = NSLock()
    
    public init(
        mapper: ScreenMapper = ScreenMapper(),
        filter: OneEuroFilter = OneEuroFilter(minCutoff: 0.6, beta: 0.008),
        deadZonePixels: Double = 2.2
    ) {
        self.mapper = mapper
        self.filter = filter
        self.deadZonePixels = deadZonePixels
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        filter.reset()
        lastScreenPoint = nil
    }
    
    /// Processes a tracking point (e.g. index fingertip or two-finger midpoint) and produces a cursor move event.
    public func process(
        trackingPoint: Landmark,
        timestamp: TimeInterval,
        speedMultiplier: Double = 1.0
    ) -> AbstractGestureEvent? {
        lock.lock()
        defer { lock.unlock() }
        
        // 1. Map normalized camera landmark to target screen pixels
        let rawScreenPoint = mapper.mapToScreen(normalizedX: trackingPoint.x, normalizedY: trackingPoint.y)
        
        // 2. Filter coordinate using adaptive One Euro Filter
        let filteredPoint = filter.filter(point: rawScreenPoint, timestamp: timestamp)
        
        guard let prev = lastScreenPoint else {
            lastScreenPoint = filteredPoint
            return .cursorMoved(to: filteredPoint)
        }
        
        // 3. Compute pixel displacement from last emitted position
        let rawDx = Double(filteredPoint.x - prev.x)
        let rawDy = Double(filteredPoint.y - prev.y)
        let rawDisplacement = hypot(rawDx, rawDy)
        
        // 4. Dead-zone test — suppresses camera sensor noise and finger micro-tremors
        guard rawDisplacement >= deadZonePixels else {
            return nil
        }
        
        // 5. Apply dynamic speed multiplier (1.0 for single finger; distance-scaled for two fingers)
        let dx = rawDx * speedMultiplier
        let dy = rawDy * speedMultiplier
        
        let newX = prev.x + dx
        let newY = prev.y + dy
        
        // 6. Clamp to screen boundary
        let clampedX = max(mapper.screenBounds.minX, min(mapper.screenBounds.maxX, newX))
        let clampedY = max(mapper.screenBounds.minY, min(mapper.screenBounds.maxY, newY))
        let targetPoint = CGPoint(x: clampedX, y: clampedY)
        
        self.lastScreenPoint = targetPoint
        return .cursorMoved(to: targetPoint)
    }
    
    /// Convenience wrapper for index fingertip observations.
    public func process(indexTip: Landmark, timestamp: TimeInterval) -> AbstractGestureEvent? {
        process(trackingPoint: indexTip, timestamp: timestamp)
    }
}
