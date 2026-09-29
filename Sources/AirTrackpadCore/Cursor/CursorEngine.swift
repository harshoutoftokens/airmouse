import Foundation
import CoreGraphics

/// Engine translating raw index fingertip landmarks into smooth, jitter-free cursor events.
public final class CursorEngine: @unchecked Sendable {
    public var mapper: ScreenMapper
    public var filter: OneEuroFilter
    public var deadZonePixels: Double
    
    private var lastFilteredPoint: CGPoint?
    private var currentCursorPoint: CGPoint?
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
        lastFilteredPoint = nil
        currentCursorPoint = nil
    }
    
    /// Processes an index fingertip observation and produces a cursor move event.
    /// When speedMultiplier == 1.0 (single finger), direct 1:1 screen mapping is preserved without drift.
    /// When speedMultiplier < 1.0 (fingers close in precision mode), displacement is scaled down smoothly without feedback drift.
    public func process(
        indexTip: Landmark,
        timestamp: TimeInterval,
        speedMultiplier: Double = 1.0
    ) -> AbstractGestureEvent? {
        lock.lock()
        defer { lock.unlock() }
        
        // 1. Map normalized camera landmark to target screen pixels
        let rawScreenPoint = mapper.mapToScreen(normalizedX: indexTip.x, normalizedY: indexTip.y)
        
        // 2. Filter coordinate using adaptive One Euro Filter
        let filteredPoint = filter.filter(point: rawScreenPoint, timestamp: timestamp)
        
        guard let prevFiltered = lastFilteredPoint, let prevCursor = currentCursorPoint else {
            lastFilteredPoint = filteredPoint
            currentCursorPoint = filteredPoint
            return .cursorMoved(to: filteredPoint)
        }
        
        // 3. Compute real physical movement of the hand between consecutive frames
        let deltaX = Double(filteredPoint.x - prevFiltered.x)
        let deltaY = Double(filteredPoint.y - prevFiltered.y)
        let displacement = hypot(deltaX, deltaY)
        
        self.lastFilteredPoint = filteredPoint
        
        // 4. Dead-zone test — suppresses camera sensor noise and finger micro-tremors
        guard displacement >= deadZonePixels else {
            return nil
        }
        
        // 5. Target point calculation:
        // - At 1.0x (normal pointing): absolute mapping directly to filteredPoint (no drift)
        // - In precision slow mode (< 1.0): scales delta to dampen hand tremor
        let targetX: CGFloat
        let targetY: CGFloat
        if abs(speedMultiplier - 1.0) < 0.01 {
            targetX = filteredPoint.x
            targetY = filteredPoint.y
        } else {
            let clampedMultiplier = max(0.10, min(1.0, speedMultiplier))
            targetX = prevCursor.x + deltaX * clampedMultiplier
            targetY = prevCursor.y + deltaY * clampedMultiplier
        }
        
        // 6. Clamp to screen boundary
        let clampedX = max(mapper.screenBounds.minX, min(mapper.screenBounds.maxX, targetX))
        let clampedY = max(mapper.screenBounds.minY, min(mapper.screenBounds.maxY, targetY))
        let targetPoint = CGPoint(x: clampedX, y: clampedY)
        
        self.currentCursorPoint = targetPoint
        return .cursorMoved(to: targetPoint)
    }
    
    /// Overload for backwards compatibility
    public func process(trackingPoint: Landmark, timestamp: TimeInterval, speedMultiplier: Double = 1.0) -> AbstractGestureEvent? {
        process(indexTip: trackingPoint, timestamp: timestamp, speedMultiplier: speedMultiplier)
    }
    
    public func process(trackingPoint: Landmark, timestamp: TimeInterval) -> AbstractGestureEvent? {
        process(indexTip: trackingPoint, timestamp: timestamp, speedMultiplier: 1.0)
    }
    
    public func process(indexTip: Landmark, timestamp: TimeInterval) -> AbstractGestureEvent? {
        process(indexTip: indexTip, timestamp: timestamp, speedMultiplier: 1.0)
    }
}
