import Foundation
import CoreGraphics

/// Protocol defining the platform input execution backend.
public protocol InputBackendProtocol: AnyObject, Sendable {
    func moveCursor(to screenPoint: CGPoint)
    func mouseClick(at screenPoint: CGPoint)
    func mouseDown(at screenPoint: CGPoint)
    func mouseDragged(to screenPoint: CGPoint)
    func mouseUp(at screenPoint: CGPoint)
    func switchSpace(direction: SwipeDirection)
    func triggerMissionControl()
    func emergencyRelease()
}
