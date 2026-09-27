import Foundation

public enum SwipeDirection: String, Sendable, Codable {
    case left
    case right
    case up
    case down
}

/// Abstract logical events produced by the gesture recognition state machine.
/// Has zero dependency on CoreGraphics or macOS event loops.
public enum AbstractGestureEvent: Sendable, Equatable {
    case cursorMoved(to: CGPoint)
    case leftClick(at: CGPoint)
    case leftMouseDown(at: CGPoint)
    case leftMouseDragged(to: CGPoint)
    case leftMouseUp(at: CGPoint)
    case switchSpace(direction: SwipeDirection)
    case triggerMissionControl
    case trackingPaused
    case trackingResumed
    case emergencyStop
}
