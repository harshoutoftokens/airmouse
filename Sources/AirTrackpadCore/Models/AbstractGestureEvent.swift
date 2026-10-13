import Foundation
import CoreGraphics

public enum SwipeDirection: String, Sendable, Codable {
    case left
    case right
    case up
    case down
}

/// Phase of a continuous (trackpad-style) scroll gesture.
public enum ScrollPhase: String, Sendable, Codable {
    case began
    case changed
    /// Fingers lifted: the output stage may continue with momentum.
    case ended
}

/// Abstract logical events produced by the gesture recognition state machine.
/// Has zero dependency on macOS event APIs; the `ActionRouter` turns them into input.
public enum AbstractGestureEvent: Sendable, Equatable {
    /// Relative pointer motion in points. Becomes a drag while the left button is held.
    case pointerDelta(dx: Double, dy: Double)
    /// Absolute pointer target in global points (absolute cursor mode).
    case pointerWarp(to: CGPoint)
    /// Left click at the current pointer position; `count` 2/3 produce double/triple clicks.
    case leftClick(count: Int)
    case rightClick
    case leftMouseDown
    case leftMouseUp
    case scroll(deltaX: Double, deltaY: Double, phase: ScrollPhase)
    /// Stops inertial scrolling — the equivalent of touching a trackpad (sent when a pinch lands).
    case cancelMomentum
    case switchSpace(direction: SwipeDirection)
    case triggerMissionControl
    case trackingPaused
    case trackingResumed
    case emergencyStop
}
