import Foundation
import CoreGraphics

/// Engine translating raw index fingertip landmarks into smooth, accelerated cursor events.
public final class CursorEngine: @unchecked Sendable {
    public var mapper: ScreenMapper
    public var filter: OneEuroFilter
    public var sensitivity: Double
    public var accelerationFactor: Double
    public var deadZonePixels: Double
    
    private var lastScreenPoint: CGPoint?
    private let lock = NSLock()
    
    public init(
        mapper: ScreenMapper = ScreenMapper(),
        filter: OneEuroFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.007),
        sensitivity: Double = 1.0,
        accelerationFactor: Double = 1.15,
        deadZonePixels: Double = 1.2
    ) {
        self.mapper = mapper
        self.filter = filter
        self.sensitivity = sensitivity
        self.accelerationFactor = accelerationFactor
        self.deadZonePixels = deadZonePixels
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        filter.reset()
        lastScreenPoint = nil
    }
    
    /// Processes an index fingertip observation and produces a cursor move event if movement exceeds dead-zone.
    public func process(indexTip: Landmark, timestamp: TimeInterval) -> AbstractGestureEvent? {
        lock.lock()
        defer { lock.unlock() }
        
        // 1. Map normalized camera landmark to target screen pixels
        let rawScreenPoint = mapper.mapToScreen(normalizedX: indexTip.x, normalizedY: indexTip.y)
        
        // 2. Filter coordinate using adaptive One Euro Filter
        let filteredPoint = filter.filter(point: rawScreenPoint, timestamp: timestamp)
        
        guard let prev = lastScreenPoint else {
            lastScreenPoint = filteredPoint
            return .cursorMoved(to: filteredPoint)
        }
        
        // 3. Compute pixel displacement
        let dx = Double(filteredPoint.x - prev.x)
        let dy = Double(filteredPoint.y - prev.y)
        let displacement = hypot(dx, dy)
        
        // 4. Dead-zone test — suppresses microscopic hand tremor
        guard displacement >= deadZonePixels else {
            return nil
        }
        
        // 5. Apply acceleration curve: scale displacement non-linearly
        let accelMultiplier = sensitivity * pow(displacement, accelerationFactor - 1.0)
        let finalX = prev.x + CGFloat(dx * accelMultiplier)
        let finalY = prev.y + CGFloat(dy * accelMultiplier)
        
        // 6. Clamp to screen boundary
        let clampedX = max(mapper.screenBounds.minX, min(mapper.screenBounds.maxX, finalX))
        let clampedY = max(mapper.screenBounds.minY, min(mapper.screenBounds.maxY, finalY))
        let targetPoint = CGPoint(x: clampedX, y: clampedY)
        
        self.lastScreenPoint = targetPoint
        return .cursorMoved(to: targetPoint)
    }
}
