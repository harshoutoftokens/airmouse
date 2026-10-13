import Foundation

/// Tunable gesture parameters. Distances are in palm lengths unless noted.
public struct GestureConfig: Sendable, Equatable {
    // MARK: Pinch → click / drag
    public var pinchPressThreshold: Double = 0.22
    public var pinchReleaseThreshold: Double = 0.32
    /// Hand travel while pinched that turns a click into a drag.
    public var dragStartDistance: Double = 0.16
    /// Holding a pinch this long without moving also starts a drag (press-and-hold).
    public var dragHoldDelay: TimeInterval = 0.45
    public var doubleClickInterval: TimeInterval = 0.5
    /// Max pointer travel between clicks (points) for them to count as a double click.
    public var doubleClickMaxTravel: Double = 8.0
    /// Pointer stays still this long after a click / release so un-pinching can't nudge it.
    public var postClickSettle: TimeInterval = 0.12
    /// Max look-back when undoing pointer motion caused by the fingers closing.
    public var pressRollbackWindow: TimeInterval = 0.25
    /// Look-back when undoing pointer motion caused by the fingers opening at the end of a drag.
    public var releaseRollbackWindow: TimeInterval = 0.10
    public var rightClickEnabled: Bool = true
    /// Brief tracking dropouts (blur, occlusion) shorter than this don't end a drag or scroll.
    public var handLossGrace: TimeInterval = 0.25

    // MARK: Scroll (✌)
    public var scrollEnabled: Bool = true
    public var scrollPointsPerPalm: Double = 900
    public var scrollSensitivity: Double = 1.0
    /// true: content follows the hand, like a trackpad with natural scrolling.
    public var naturalScrolling: Bool = true
    public var scrollRestSpeed: Double = 0.12

    // MARK: Desktop swipe (🖐 ← →)
    public var swipeEnabled: Bool = true
    /// Palm lengths of sideways hand travel that drag the desktop one full desktop width.
    public var swipeFullDistance: Double = 1.5
    /// Letting go past this fraction of a desktop switches (like the trackpad's halfway point).
    public var swipeCommitProgress: Double = 0.5
    /// Progress per second that counts as a flick: switches even short of the halfway point.
    public var swipeFlickVelocity: Double = 1.7
    /// After a switch, a swipe back the other way is ignored for this long (return stroke).
    public var swipeReturnLockout: TimeInterval = 0.9
    /// false: moving the hand right goes to the desktop on the right.
    /// true: content follows the hand like a trackpad (moving right reveals the desktop on the left).
    public var naturalSwipeDirection: Bool = false

    // MARK: Mission Control (🖐 → 🤏 → 🖐)
    public var missionControlEnabled: Bool = true
    public var fiveFingerOpenThreshold: Double = 0.40
    public var fiveFingerPinchThreshold: Double = 0.22
    public var fiveFingerMaxSequenceDuration: TimeInterval = 1.4

    /// Quiet period after a desktop switch or Mission Control.
    public var gestureCooldown: TimeInterval = 0.30

    public init() {}
}
