import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// Maps normalized camera landmarks to macOS screen coordinates with configurable sensitivity and reach margins.
public struct ScreenMapper: Sendable {
    public var minX: Double
    public var maxX: Double
    public var minY: Double
    public var maxY: Double
    public var screenBounds: CGRect
    public var sensitivity: Double
    
    public init(
        minX: Double = 0.15,
        maxX: Double = 0.85,
        minY: Double = 0.15,
        maxY: Double = 0.85,
        screenBounds: CGRect = CGRect(x: 0, y: 0, width: 1470, height: 956),
        sensitivity: Double = 1.0
    ) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.screenBounds = screenBounds
        self.sensitivity = max(0.5, min(3.0, sensitivity))
    }
    
    /// Updates screen bounds dynamically from the main screen.
    public mutating func updateScreenBounds() {
        #if canImport(AppKit)
        if let frame = NSScreen.main?.frame {
            self.screenBounds = frame
        } else {
            self.screenBounds = CGDisplayBounds(CGMainDisplayID())
        }
        #endif
    }
    
    /// Converts a normalized landmark (x, y in [0, 1]) to screen pixel coordinates.
    public func mapToScreen(normalizedX: Double, normalizedY: Double) -> CGPoint {
        // Sensitivity narrows or widens the effective active region around the center (0.5, 0.5)
        let baseSpanX = (maxX - minX) / sensitivity
        let baseSpanY = (maxY - minY) / sensitivity
        
        let centerX = (minX + maxX) / 2.0
        let centerY = (minY + maxY) / 2.0
        
        let effMinX = centerX - baseSpanX / 2.0
        let effMaxX = centerX + baseSpanX / 2.0
        let effMinY = centerY - baseSpanY / 2.0
        let effMaxY = centerY + baseSpanY / 2.0
        
        // 1. Clamp to effective interaction window
        let clampedX = max(effMinX, min(effMaxX, normalizedX))
        let clampedY = max(effMinY, min(effMaxY, normalizedY))
        
        // 2. Normalize within active window to [0.0, 1.0]
        let widthSpan = max(effMaxX - effMinX, 0.05)
        let heightSpan = max(effMaxY - effMinY, 0.05)
        let normX = (clampedX - effMinX) / widthSpan
        let normY = (clampedY - effMinY) / heightSpan
        
        // 3. Scale to screen dimensions (inverting Y because Vision Y=0 is bottom, Screen Y=0 is top)
        let screenX = screenBounds.minX + normX * screenBounds.width
        let screenY = screenBounds.minY + (1.0 - normY) * screenBounds.height
        
        return CGPoint(x: screenX, y: screenY)
    }
}
