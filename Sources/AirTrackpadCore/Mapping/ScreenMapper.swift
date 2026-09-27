import Foundation
import CoreGraphics

/// Maps normalized camera landmarks to macOS screen coordinates with active interaction margins.
public struct ScreenMapper: Sendable {
    public var minX: Double
    public var maxX: Double
    public var minY: Double
    public var maxY: Double
    public var screenBounds: CGRect
    
    public init(
        minX: Double = 0.15,
        maxX: Double = 0.85,
        minY: Double = 0.15,
        maxY: Double = 0.85,
        screenBounds: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
    ) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.screenBounds = screenBounds
    }
    
    /// Converts a normalized landmark (x, y in [0, 1]) to screen pixel coordinates.
    public func mapToScreen(normalizedX: Double, normalizedY: Double) -> CGPoint {
        // 1. Clamp to interaction window
        let clampedX = max(minX, min(maxX, normalizedX))
        let clampedY = max(minY, min(maxY, normalizedY))
        
        // 2. Normalize within active window to [0.0, 1.0]
        let widthSpan = max(maxX - minX, 0.05)
        let heightSpan = max(maxY - minY, 0.05)
        let normX = (clampedX - minX) / widthSpan
        let normY = (clampedY - minY) / heightSpan
        
        // 3. Scale to screen dimensions (inverting Y because Vision Y=0 is bottom, Screen Y=0 is top)
        let screenX = screenBounds.minX + normX * screenBounds.width
        let screenY = screenBounds.minY + (1.0 - normY) * screenBounds.height
        
        return CGPoint(x: screenX, y: screenY)
    }
}
