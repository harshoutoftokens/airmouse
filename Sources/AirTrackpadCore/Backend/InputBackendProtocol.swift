import Foundation
import CoreGraphics

/// `kCGScrollWheelEventScrollPhase` values (trackpad gesture phase of a scroll event).
public enum ScrollEventPhase: Int64, Sendable {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
    case mayBegin = 128
}

/// `kCGScrollWheelEventMomentumPhase` values (inertial scrolling after the fingers lift).
public enum ScrollMomentumPhase: Int64, Sendable {
    case none = 0
    case begin = 1
    case `continue` = 2
    case end = 3
}

/// Platform input execution backend. Positions are global Quartz points.
public protocol InputBackendProtocol: AnyObject, Sendable {
    func currentPointerLocation() -> CGPoint
    /// Moves the pointer; posts a drag instead of a move while the left button is held.
    func moveCursor(to point: CGPoint, delta: CGVector, buttonDown: Bool)
    func mouseDown(at point: CGPoint, clickCount: Int)
    func mouseUp(at point: CGPoint, clickCount: Int)
    func rightClick(at point: CGPoint)
    /// Continuous (pixel) scroll. `deltaY > 0` moves content down, `deltaX > 0` moves it right.
    func scroll(deltaX: Double, deltaY: Double, phase: ScrollEventPhase, momentumPhase: ScrollMomentumPhase)
    func switchSpace(direction: SwipeDirection)
    /// Interactive desktop swipe (see `AbstractGestureEvent.desktopSwipeBegan`).
    func beginDesktopSwipe()
    func updateDesktopSwipe(progress: Double)
    func endDesktopSwipe(progress: Double, commit: Bool)
    func triggerMissionControl()
    func emergencyRelease()
}
