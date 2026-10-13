import Foundation
import CoreGraphics

public enum GestureState: String, Sendable, Codable {
    case idle = "IDLE"
    case pointing = "☝ POINTING"
    case scrolling = "✌ SCROLLING"
    case pressed = "🤏 PRESSED"
    case dragging = "✊ DRAGGING"
    case openHand = "🖐 OPEN HAND"
    case swipingDesktop = "🖐 SWIPING DESKTOP"
    case missionControlGesture = "🤏 MISSION CONTROL"
    case cooldown = "⏱ COOLDOWN"
    case handLost = "… HAND LOST"
}

/// Live values for the HUD and logs.
public struct GestureTelemetry: Sendable {
    public var pose: HandPose = .none
    public var rawPose: HandPose = .none
    public var pinchDistance: Double = 1.0
    public var pinchProgress: Double = 0.0
    public var isPinched: Bool = false
    public var handSpeed: Double = 0.0
    public var handScale: Double = 0.0
    public var swipeArmed: Bool = false
    /// Live drag progress of an interactive desktop swipe (0 when none).
    public var swipeProgress: Double = 0
    public var lastSwipe: DesktopSwipeSummary?
    public var fiveFingerPhase: FiveFingerDetector.Phase = .idle

    public init() {}
}

/// Turns per-frame hand observations into abstract input events.
///
/// Priority, highest first: desktop swipe → Mission Control → pinch (click / drag / right
/// click) → pose (pointing moves the pointer, ✌ scrolls). An active press or drag owns the
/// hand exclusively until the pinch opens. The pointer only moves while pointing or dragging;
/// every other shape is a "lift" that leaves it where it is.
public final class GestureStateMachine: @unchecked Sendable {
    public private(set) var currentState: GestureState = .idle
    public private(set) var telemetry = GestureTelemetry()
    public let cursor: CursorEngine
    public private(set) var config = GestureConfig()

    private var poseStabilizer = PoseStabilizer()
    private var leftPinch = PinchDetector()
    private var rightPinch = PinchDetector()
    private var swipe = DesktopSwipeTracker()
    private var fiveFinger = FiveFingerDetector()

    private var handLostSince: TimeInterval?
    private var lastFrameTime: TimeInterval?
    /// When the current hand came into view (survives short dropouts).
    private var handPresentSince: TimeInterval?
    private var cooldownUntil: TimeInterval = 0
    private var settleUntil: TimeInterval = 0
    private var lastOpenHandTime: TimeInterval = -.infinity
    private var previousPose: HandPose = .none

    // Press / click bookkeeping
    private var pressTime: TimeInterval = 0
    private var pressAnchor: CGPoint = .zero
    private var lastClickTime: TimeInterval = -.infinity
    private var clickCount: Int = 0
    /// Net pointer displacement since the last click (relative mode). Net, not path length, so
    /// jitter and click rollback don't break double clicks.
    private var netSinceClick = CGVector.zero
    /// Pointer target at the last click (absolute mode).
    private var lastClickTarget: CGPoint?

    // Scroll bookkeeping
    private var scrollBegan = false
    private var scrollPoseFrames = 0
    private var lastScrollAnchor: CGPoint?
    private var lastScrollTime: TimeInterval?
    private var railX: Double = 0
    private var railY: Double = 0

    private let lock = NSLock()

    public init(cursor: CursorEngine = CursorEngine()) {
        self.cursor = cursor
        apply(GestureConfig())
    }

    // MARK: - Configuration

    public func apply(_ newConfig: GestureConfig) {
        lock.lock()
        defer { lock.unlock() }
        config = newConfig
        leftPinch.pressThreshold = newConfig.pinchPressThreshold
        leftPinch.releaseThreshold = max(newConfig.pinchReleaseThreshold, newConfig.pinchPressThreshold + 0.03)
        // The middle finger is longer and curls less neatly onto the thumb, so give the
        // right-click pinch a little more room.
        rightPinch.pressThreshold = newConfig.pinchPressThreshold + 0.02
        rightPinch.releaseThreshold = max(newConfig.pinchReleaseThreshold + 0.02, rightPinch.pressThreshold + 0.03)
        swipe.fullSwipeDistance = newConfig.swipeFullDistance
        swipe.commitProgress = newConfig.swipeCommitProgress
        swipe.flickVelocity = newConfig.swipeFlickVelocity
        swipe.returnLockout = newConfig.swipeReturnLockout
        swipe.directionSign = newConfig.naturalSwipeDirection ? -1 : 1
        fiveFinger.openThreshold = newConfig.fiveFingerOpenThreshold
        fiveFinger.pinchThreshold = newConfig.fiveFingerPinchThreshold
        fiveFinger.maxSequenceDuration = newConfig.fiveFingerMaxSequenceDuration
    }

    // MARK: - Lifecycle

    /// Returns to idle, emitting whatever is needed to leave the OS in a clean state.
    @discardableResult
    public func reset() -> [AbstractGestureEvent] {
        lock.lock()
        defer { lock.unlock() }
        return releaseEverything()
    }

    /// Emergency fail-safe release.
    public func emergencyRelease() -> [AbstractGestureEvent] {
        reset()
    }

    // MARK: - Frame processing

    public func process(
        hand: HandObservation?,
        metrics: HandMetrics?,
        timestamp t: TimeInterval
    ) -> [AbstractGestureEvent] {
        lock.lock()
        defer { lock.unlock() }
        lastFrameTime = t

        guard hand != nil, let m = metrics else {
            return handleHandLoss(at: t)
        }
        handLostSince = nil
        if handPresentSince == nil { handPresentSince = t }
        var events: [AbstractGestureEvent] = []

        // 1. Pose
        let rawPose = PoseClassifier.classify(m)
        let pose = poseStabilizer.update(rawPose)
        if pose == .openHand { lastOpenHandTime = t }
        defer { previousPose = pose }

        // 2. Pinches (left = thumb↔index, right = thumb↔middle)
        let isFree = currentState != .pressed && currentState != .dragging
        let pressAllowed = isFree
            && t >= cooldownUntil
            && pose != .openHand
            && t - lastOpenHandTime > 0.25
            && !fiveFinger.isGathering
            && !scrollBegan
        let leftTransition = leftPinch.update(
            distance: m.pinchTracked ? m.pinchDistance : nil,
            fingerReach: m.reach(for: .index),
            timestamp: t,
            allowPress: pressAllowed && !rightPinch.isPinched
        )
        let rightTransition = rightPinch.update(
            distance: m.middlePinchTracked ? m.middlePinchDistance : nil,
            fingerReach: m.reach(for: .middle),
            timestamp: t,
            allowPress: pressAllowed && config.rightClickEnabled && !leftPinch.isPinched
                && m.pinchDistance > config.pinchReleaseThreshold
        )

        // 3. Pointer: calm it down while a pinch is visibly closing, before the press is confirmed.
        var gainMultiplier = 1.0
        if isFree && leftPinch.closingSpeed > 0.8 && leftPinch.progress > 0.15 {
            gainMultiplier = max(0.15, 1.0 - (leftPinch.closingSpeed - 0.8) / 1.6)
        }
        // Absolute mode: widen the dead zone as a pinch closes (only before the press — during a
        // drag the pointer must follow the hand closely).
        let leashBoost = isFree ? 18.0 * leftPinch.progress * leftPinch.progress : 0.0
        let sample = cursor.update(
            anchor: m.cursorAnchor,
            scale: m.handScale,
            timestamp: t,
            gainMultiplier: gainMultiplier,
            leashBoost: leashBoost
        )

        telemetry.pose = pose
        telemetry.rawPose = rawPose
        telemetry.pinchDistance = leftPinch.distance
        telemetry.pinchProgress = leftPinch.progress
        telemetry.isPinched = leftPinch.isPinched
        telemetry.handSpeed = sample.speed
        telemetry.handScale = sample.scale
        defer {
            telemetry.swipeArmed = swipe.isArmed
            telemetry.swipeProgress = swipe.progress
            telemetry.fiveFingerPhase = fiveFinger.phase
        }

        // 4. An active press or drag owns the hand until the pinch opens.
        if currentState == .pressed {
            handlePressed(leftTransition, pose: pose, sample: sample, t: t, events: &events)
            return events
        }
        if currentState == .dragging {
            handleDragging(leftTransition, pose: pose, sample: sample, t: t, events: &events)
            return events
        }

        // 5. Desktop swipe: the desktop follows the open hand until it lets go. A hand sweeping
        // into view is already moving fast, so swipes only start once it has been in view a moment.
        if t - (handPresentSince ?? t) < 0.3 && !swipe.isActive {
            swipe.resetTracking()
        }
        if config.swipeEnabled {
            let updates = swipe.update(pose: pose, palm: m.centroid, scale: sample.scale, timestamp: t)
            if !updates.isEmpty || swipe.isActive {
                endScroll(&events)
                fiveFinger.reset()
                leftPinch.cancel()
                rightPinch.cancel()
                currentState = .swipingDesktop
                for update in updates {
                    switch update {
                    case .began:
                        events.append(.desktopSwipeBegan)
                    case .changed(let progress):
                        events.append(.desktopSwipeChanged(progress: progress))
                    case .ended(let progress, let commit):
                        events.append(.desktopSwipeEnded(progress: progress, commit: commit))
                        telemetry.lastSwipe = swipe.lastSummary
                        cooldownUntil = t + config.gestureCooldown
                        currentState = .cooldown
                    }
                }
                return events
            }
        }

        // 6. Mission Control
        if config.missionControlEnabled {
            let thumbUp = m.state(for: .thumb).isUp || m.extendedFingerCount >= 5
            if fiveFinger.update(pose: pose, thumbUp: thumbUp, spread: m.spread, timestamp: t) {
                endScroll(&events)
                events.append(.triggerMissionControl)
                swipe.resetTracking()
                leftPinch.cancel()
                rightPinch.cancel()
                cooldownUntil = t + max(config.gestureCooldown, 0.5)
                currentState = .cooldown
                return events
            }
            if fiveFinger.isGathering {
                // Gathering five fingertips brings thumb and index together too; make sure that
                // can't count as a pinch, even if the sequence is abandoned or times out.
                leftPinch.cancel()
                rightPinch.cancel()
            }
            if fiveFinger.isEngaged {
                endScroll(&events)
                currentState = .missionControlGesture
                return events
            }
        }

        if t < cooldownUntil {
            endScroll(&events)
            currentState = .cooldown
            return events
        }

        // 7. Pinch press → click / drag candidate
        if leftTransition == .pressed {
            endScroll(&events)
            events.append(.cancelMomentum)
            rollBackPointer(since: leftPinch.lastSteadyOpenTime ?? (t - 0.1), now: t, window: config.pressRollbackWindow, events: &events)
            pressTime = t
            pressAnchor = sample.filteredAnchor
            rightPinch.cancel()
            currentState = .pressed
            return events
        }
        if rightTransition == .pressed {
            endScroll(&events)
            events.append(.cancelMomentum)
            events.append(.rightClick)
            clickCount = 0
            settleUntil = t + config.postClickSettle
            return events
        }

        // 8. Pose-driven behaviour. While the raw pose is already heading to a different
        // gesture (the stabilizer hasn't switched yet), hold output instead of emitting the
        // stray motion of the hand changing shape.
        switch pose {
        case .scroll where config.scrollEnabled:
            scrollPoseFrames += 1
            currentState = .scrolling
            let leaving = rawPose == .pointing || rawPose == .openHand || rawPose == .fist
            if scrollPoseFrames >= 2 && !leaving {
                let step = scrollStep(sample: sample, t: t)
                if step.dx != 0 || step.dy != 0 {
                    events.append(.scroll(deltaX: step.dx, deltaY: step.dy, phase: scrollBegan ? .changed : .began))
                    scrollBegan = true
                }
            } else {
                lastScrollAnchor = sample.filteredAnchor
                lastScrollTime = t
            }
        case .pointing:
            if previousPose != .pointing {
                // Settling the index finger into a point (out of a fist, out of ✌) nudges the
                // knuckles; give it a beat before the pointer follows.
                settleUntil = max(settleUntil, t + 0.08)
            }
            endScroll(&events)
            currentState = .pointing
            let leaving = rawPose == .scroll || rawPose == .openHand || rawPose == .fist
            if t >= settleUntil && !leaving {
                emitMotion(sample, t: t, events: &events)
            }
        case .openHand:
            endScroll(&events)
            currentState = .openHand
        default:
            endScroll(&events)
            currentState = .idle
        }
        return events
    }

    // MARK: - Press / drag

    private func handlePressed(
        _ transition: PinchTransition,
        pose: HandPose,
        sample: CursorEngine.Sample,
        t: TimeInterval,
        events: inout [AbstractGestureEvent]
    ) {
        if transition == .released {
            let travel: Double
            switch cursor.mode {
            case .relative:
                travel = hypot(Double(netSinceClick.dx), Double(netSinceClick.dy))
            case .absolute:
                if let last = lastClickTarget, let now = cursor.target(at: t) {
                    travel = hypot(Double(now.x - last.x), Double(now.y - last.y))
                } else {
                    travel = 0
                }
            }
            let isRepeat = t - lastClickTime <= config.doubleClickInterval
                && travel <= config.doubleClickMaxTravel
                && clickCount > 0
            clickCount = isRepeat ? min(clickCount + 1, 3) : 1
            lastClickTime = t
            netSinceClick = .zero
            lastClickTarget = cursor.target(at: t)
            events.append(.leftClick(count: clickCount))
            settleUntil = t + config.postClickSettle
            currentState = pose == .pointing ? .pointing : .idle
            return
        }
        // The knuckles move while the fingers finish closing and again as they open; neither is
        // the hand moving. Re-base while the pinch is still closing, and never turn a pinch that
        // is opening into a drag: that's the release of a click (live logs showed quick clicks
        // becoming two-frame drags).
        if t - pressTime < 0.15 && leftPinch.closingSpeed > 0.5 {
            pressAnchor = sample.filteredAnchor
            return
        }
        let opening = leftPinch.closingSpeed < -0.5
            || leftPinch.releaseOnsetTime.map { t - $0 < 0.2 } == true
        if opening { return }
        let moved = hypot(Double(sample.filteredAnchor.x - pressAnchor.x), Double(sample.filteredAnchor.y - pressAnchor.y)) / max(sample.scale, 0.02)
        if moved >= config.dragStartDistance || t - pressTime >= config.dragHoldDelay {
            events.append(.leftMouseDown)
            clickCount = 0
            currentState = .dragging
            if cursor.mode == .absolute {
                cursor.resetLeash()
            }
        }
    }

    private func handleDragging(
        _ transition: PinchTransition,
        pose: HandPose,
        sample: CursorEngine.Sample,
        t: TimeInterval,
        events: inout [AbstractGestureEvent]
    ) {
        if transition == .released {
            let onset = leftPinch.releaseOnsetTime ?? t
            rollBackPointer(since: onset - 0.04, now: t, window: config.releaseRollbackWindow, events: &events)
            events.append(.leftMouseUp)
            settleUntil = t + config.postClickSettle
            currentState = pose == .pointing ? .pointing : .idle
            return
        }
        emitMotion(sample, t: t, events: &events)
    }

    // MARK: - Pointer output

    private func emitMotion(_ sample: CursorEngine.Sample, t: TimeInterval, events: inout [AbstractGestureEvent]) {
        switch cursor.mode {
        case .relative:
            let d = sample.delta
            let length = hypot(Double(d.dx), Double(d.dy))
            guard length > 1e-3 else { return }
            events.append(.pointerDelta(dx: Double(d.dx), dy: Double(d.dy)))
            cursor.recordEmitted(d, at: t)
            netSinceClick.dx += d.dx
            netSinceClick.dy += d.dy
        case .absolute:
            guard let p = sample.target else { return }
            events.append(.pointerWarp(to: p))
            cursor.recordTarget(p, at: t)
        }
    }

    /// Undoes pointer motion emitted since `onset` (clamped to `window`), which is the motion
    /// produced by the fingers themselves while pinching or un-pinching.
    private func rollBackPointer(
        since onset: TimeInterval,
        now t: TimeInterval,
        window: TimeInterval,
        events: inout [AbstractGestureEvent]
    ) {
        let from = min(max(onset, t - window), t - 0.02)
        switch cursor.mode {
        case .relative:
            let back = cursor.emittedMotion(since: from)
            let length = hypot(Double(back.dx), Double(back.dy))
            // Large motion means the user was deliberately moving; leave it alone.
            guard length > 0.5, length < 90 else { return }
            let undo = CGVector(dx: -back.dx, dy: -back.dy)
            events.append(.pointerDelta(dx: Double(undo.dx), dy: Double(undo.dy)))
            cursor.recordEmitted(undo, at: t)
            netSinceClick.dx += undo.dx
            netSinceClick.dy += undo.dy
        case .absolute:
            guard let p = cursor.target(at: from) else { return }
            events.append(.pointerWarp(to: p))
            cursor.recordTarget(p, at: t)
        }
    }

    // MARK: - Scroll

    private func scrollStep(sample: CursorEngine.Sample, t: TimeInterval) -> (dx: Double, dy: Double) {
        let f = sample.filteredAnchor
        defer {
            lastScrollAnchor = f
            lastScrollTime = t
        }
        guard let prev = lastScrollAnchor, let lastT = lastScrollTime, t > lastT, t - lastT < 0.25 else {
            return (0, 0)
        }
        let dt = t - lastT
        let s = max(sample.scale, 0.02)
        let ux = Double(f.x - prev.x) / s
        let uy = Double(f.y - prev.y) / s
        let v = hypot(ux, uy) / dt
        let keep = v > config.scrollRestSpeed ? (v - config.scrollRestSpeed) / v : 0.0
        let ramp = max(0.0, min(1.0, (v - 1.0) / 4.0))
        let accel = 1.0 + 0.8 * ramp * ramp * (3 - 2 * ramp)
        let gain = config.scrollPointsPerPalm * config.scrollSensitivity * accel * keep

        // Rails: lock onto the dominant axis so vertical scrolling doesn't wobble sideways.
        railX = 0.7 * railX + 0.3 * abs(ux)
        railY = 0.7 * railY + 0.3 * abs(uy)
        var sx = ux * gain
        var sy = uy * gain
        if railX < 0.4 * railY { sx = 0 } else if railY < 0.4 * railX { sy = 0 }

        // Scroll-wheel convention: +deltaY moves content down, +deltaX moves content right.
        // Image y grows upward, so a rising hand has uy > 0.
        if config.naturalScrolling {
            return (sx, -sy)
        } else {
            return (-sx, sy)
        }
    }

    private func endScroll(_ events: inout [AbstractGestureEvent]) {
        if scrollBegan {
            events.append(.scroll(deltaX: 0, deltaY: 0, phase: .ended))
            // Dropping the middle finger to go back to pointing nudges the knuckles.
            settleUntil = max(settleUntil, (lastScrollTime ?? 0) + 0.10)
        }
        scrollBegan = false
        scrollPoseFrames = 0
        lastScrollAnchor = nil
        lastScrollTime = nil
        railX = 0
        railY = 0
    }

    // MARK: - Hand loss

    private func handleHandLoss(at t: TimeInterval) -> [AbstractGestureEvent] {
        if currentState == .handLost {
            return []
        }
        if handLostSince == nil { handLostSince = t }
        let lostFor = t - (handLostSince ?? t)
        if lostFor < config.handLossGrace {
            // Ride out short dropouts (blur, occlusion): keep any button held and any scroll
            // open, keep swipe tracking alive, and just freeze the pointer.
            telemetry.rawPose = .none
            return []
        }
        let events = releaseEverything()
        currentState = .handLost
        return events
    }

    private func releaseEverything() -> [AbstractGestureEvent] {
        var events: [AbstractGestureEvent] = []
        if currentState == .dragging {
            events.append(.leftMouseUp)
        }
        if swipe.isActive {
            // Hand gone mid-swipe (often swept out of view): decide like letting go.
            if case .ended(let progress, let commit) = swipe.finish(at: lastFrameTime ?? 0, reason: "hand lost") {
                events.append(.desktopSwipeEnded(progress: progress, commit: commit))
            }
        }
        endScroll(&events)
        currentState = .idle
        handPresentSince = nil
        poseStabilizer.reset()
        leftPinch.reset()
        rightPinch.reset()
        swipe.resetTracking()
        fiveFinger.reset()
        cursor.reset()
        previousPose = .none
        telemetry = GestureTelemetry()
        telemetry.lastSwipe = swipe.lastSummary
        return events
    }
}
