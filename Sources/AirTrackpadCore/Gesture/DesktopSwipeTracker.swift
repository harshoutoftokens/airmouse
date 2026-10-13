import Foundation

/// One step of an interactive desktop swipe, in desktop terms: positive progress is toward the
/// desktop on the right, 1.0 is a whole desktop.
public enum DesktopSwipeUpdate: Sendable, Equatable {
    case began
    case changed(progress: Double)
    case ended(progress: Double, commit: Bool)
}

/// How the most recent swipe ended (HUD / log telemetry).
public struct DesktopSwipeSummary: Sendable, Equatable {
    public var progress: Double
    public var commit: Bool
    /// Progress per second at release, positive = toward the desktop on the right.
    public var releaseVelocity: Double
    public var reason: String
    public var duration: TimeInterval
}

/// Open-hand desktop swipe that behaves like the three/four-finger trackpad swipe: the desktop
/// follows the hand while it moves, and "letting go" either completes the switch or snaps back.
///
/// - Progress = sideways palm-center travel / `fullSwipeDistance` (palm lengths), so it is the
///   same near or far from the camera.
/// - Letting go = closing or lowering the hand (the trackpad "lift"), holding still, or the end
///   of a fast flick. A flick commits; otherwise it commits past `commitProgress` unless the hand
///   was moving back toward the start, like the trackpad's velocity-aware threshold.
/// - Direction is decided at release by the net travel, so a wind-up only makes the desktop
///   peek the other way.
/// - After a release the hand has to come to rest before a new swipe can start, and a swipe the
///   opposite way is held off for `returnLockout` after a switch: bringing the hand back to the
///   middle can't drag the desktop back.
public struct DesktopSwipeTracker: Sendable {
    /// Palm lengths of sideways travel that drag the desktop a full desktop width.
    public var fullSwipeDistance: Double = 1.5
    /// Palm lengths of sideways travel before the desktop starts to follow.
    public var startDistance: Double = 0.12
    public var commitProgress: Double = 0.5
    /// Progress per second that counts as a flick (≈ 2.5 palm lengths/s at the defaults).
    public var flickVelocity: Double = 1.7
    /// A flick has to have dragged the desktop at least this far to complete it on its own.
    public var flickMinProgress: Double = 0.25
    /// Releasing while moving this fast (progress/s) toward / away from the target commits / cancels.
    public var releaseVelocity: Double = 1.0
    public var dominance: Double = 1.3
    /// Palm lengths per second below which the hand counts as still.
    public var restSpeed: Double = 0.45
    public var holdToRelease: TimeInterval = 0.30
    public var rearmStill: TimeInterval = 0.10
    public var returnLockout: TimeInterval = 0.9
    public var maxDuration: TimeInterval = 4.0
    public var armFrames: Int = 2
    /// Pose dropouts shorter than this (motion blur mid-swipe) don't count as letting go.
    public var poseLatch: TimeInterval = 0.12
    /// +1: hand to the right drags toward the desktop on the right. −1: natural (content
    /// follows the hand, like the trackpad).
    public var directionSign: Double = 1.0

    public private(set) var isActive = false
    public private(set) var progress: Double = 0.0
    public private(set) var lastSummary: DesktopSwipeSummary?

    private var openFrames = 0
    private var lastOpenTime: TimeInterval = -.infinity
    private var anchorX: Double?
    private var anchorY: Double = 0
    private var needsRest = false
    private var stillSince: TimeInterval?
    private var lastX: Double?
    private var lastT: TimeInterval?
    /// Smoothed sideways hand velocity, palm lengths/s (+ = hand moving right).
    private var velocity: Double = 0.0
    private var beganAt: TimeInterval = 0
    /// Largest |progress| reached and the fastest progress rate toward it, this swipe.
    private var maxReach: Double = 0
    private var peakTowardTarget: Double = 0
    private var lastCommitTime: TimeInterval = -.infinity
    private var lastCommitHandSign: Double = 0
    /// Hand direction of the most recent swipe (+1 right, −1 left).
    private var lastSessionHandSign: Double = 0

    public init() {}

    public var isArmed: Bool { openFrames >= armFrames && !needsRest }

    /// Progress per second implied by the current hand velocity (+ = toward the right desktop).
    private var progressVelocity: Double { directionSign * velocity / fullSwipeDistance }

    /// Forgets in-flight tracking (hand left view, higher-priority gesture). Does not end an
    /// active swipe — call `finish` for that — and keeps the return lockout.
    public mutating func resetTracking() {
        openFrames = 0
        lastOpenTime = -.infinity
        anchorX = nil
        stillSince = nil
        lastX = nil
        lastT = nil
        velocity = 0
        if !isActive { needsRest = false }
    }

    public mutating func update(
        pose: HandPose,
        palm: Landmark,
        scale: Double,
        timestamp t: TimeInterval
    ) -> [DesktopSwipeUpdate] {
        let s = max(scale, 0.02)
        if let lx = lastX, let lt = lastT, t > lt, t - lt < 0.25 {
            let v = (palm.x - lx) / (t - lt) / s
            velocity = 0.5 * v + 0.5 * velocity
        } else {
            velocity = 0
        }
        lastX = palm.x
        lastT = t

        if abs(velocity) < restSpeed {
            if stillSince == nil { stillSince = t }
        } else {
            stillSince = nil
        }
        let stillFor = stillSince.map { t - $0 } ?? 0

        if pose == .openHand {
            openFrames += 1
            lastOpenTime = t
        } else if t - lastOpenTime > poseLatch {
            // Hand closed or dropped: the trackpad "lift".
            openFrames = 0
            anchorX = nil
            needsRest = false
            if isActive { return [finish(at: t, reason: "let go")] }
            return []
        }

        if isActive {
            let travel = (palm.x - (anchorX ?? palm.x)) / s
            progress = max(-1.2, min(1.2, directionSign * travel / fullSwipeDistance))
            let side: Double = progress >= 0 ? 1 : -1
            if abs(progress) > maxReach {
                maxReach = abs(progress)
            }
            peakTowardTarget = max(peakTowardTarget, progressVelocity * side)

            if peakTowardTarget >= flickVelocity
                && maxReach >= flickMinProgress
                && progressVelocity * side < 0.3 * peakTowardTarget {
                return [finish(at: t, reason: "flick", forceCommit: abs(progress) >= flickMinProgress * 0.6)]
            }
            if stillFor >= holdToRelease {
                return [finish(at: t, reason: "hold")]
            }
            if t - beganAt > maxDuration {
                return [finish(at: t, reason: "timeout")]
            }
            return [.changed(progress: progress)]
        }

        guard openFrames >= armFrames else {
            anchorX = nil
            return []
        }
        if needsRest {
            // Re-arm once the hand settles, or as soon as it heads back the other way (the
            // return stroke, which the lockout below then ignores) — so hopping several
            // desktops doesn't need a pause, while an overshoot can't start another swipe.
            let reversed = velocity * lastSessionHandSign < -restSpeed
            guard stillFor >= rearmStill || reversed else { return [] }
            needsRest = false
            anchorX = nil
        }
        guard let ax = anchorX else {
            anchorX = palm.x
            anchorY = palm.y
            return []
        }
        let dx = (palm.x - ax) / s
        let dy = (palm.y - anchorY) / s
        // A resting hand drifts; keep the start point under it so drift never starts a swipe.
        if stillFor > 0.3 || abs(dy) > max(startDistance * 2, abs(dx) * dominance) {
            anchorX = palm.x
            anchorY = palm.y
            return []
        }
        guard abs(dx) >= startDistance, abs(dx) >= dominance * abs(dy) else { return [] }

        let handSign: Double = dx > 0 ? 1 : -1
        if handSign == -lastCommitHandSign && t - lastCommitTime < returnLockout {
            // Bringing the hand back after a switch: follow it without dragging the desktop.
            anchorX = palm.x
            anchorY = palm.y
            return []
        }

        isActive = true
        beganAt = t
        maxReach = 0
        peakTowardTarget = 0
        progress = max(-1.2, min(1.2, directionSign * dx / fullSwipeDistance))
        return [.began, .changed(progress: progress)]
    }

    /// Ends the active swipe now (hand lost, gesture interrupted) and decides whether it switches.
    public mutating func finish(at t: TimeInterval, reason: String, forceCommit: Bool = false) -> DesktopSwipeUpdate {
        let side: Double = progress >= 0 ? 1 : -1
        let along = progressVelocity * side
        var commit = abs(progress) >= commitProgress
        if along >= releaseVelocity && abs(progress) >= flickMinProgress * 0.6 { commit = true }
        if along <= -releaseVelocity { commit = false }
        if forceCommit { commit = true }

        lastSummary = DesktopSwipeSummary(
            progress: progress,
            commit: commit,
            releaseVelocity: progressVelocity,
            reason: reason,
            duration: t - beganAt
        )
        if commit {
            lastCommitTime = t
            lastCommitHandSign = side * directionSign
        }
        lastSessionHandSign = side * directionSign
        let final = progress
        isActive = false
        progress = 0
        needsRest = true
        anchorX = nil
        stillSince = nil
        return .ended(progress: final, commit: commit)
    }
}
