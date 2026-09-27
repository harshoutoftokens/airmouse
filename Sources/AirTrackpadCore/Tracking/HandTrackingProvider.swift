import Foundation
import CoreVideo

/// Protocol abstracting hand tracking providers (Apple Vision, MediaPipe, Mock, etc.)
public protocol HandTrackingProvider: AnyObject, Sendable {
    func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [HandObservation]
    func reset()
}
