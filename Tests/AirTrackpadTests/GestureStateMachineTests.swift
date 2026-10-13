import XCTest
@testable import AirTrackpadCore

final class GestureStateMachineTests: XCTestCase {

    // MARK: - Pointer

    func testPointingMovesPointerWithHandMotion() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        let events = driver.feed(SyntheticHand(), frames: 15) { hand, i in
            hand.palm.x = 0.5 + Double(i) * 0.006
        }
        XCTAssertEqual(driver.machine.currentState, .pointing)
        XCTAssertGreaterThan(events.pointerTotal.dx, 20, "moving the hand right should move the pointer right")
        XCTAssertLessThan(abs(events.pointerTotal.dy), 5)
    }

    func testHandMovingUpMovesPointerUp() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        let events = driver.feed(SyntheticHand(), frames: 15) { hand, i in
            hand.palm.y = 0.4 + Double(i) * 0.006
        }
        XCTAssertLessThan(events.pointerTotal.dy, -20, "screen y grows downward")
    }

    func testStillHandWithTremorDoesNotDrift() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        let events = driver.feed(SyntheticHand(), frames: 90) { hand, i in
            // ±0.0015 jitter (≈2 px at 720p), typical for a hand held still
            hand.palm.x = 0.5 + 0.0015 * sin(Double(i) * 2.1)
            hand.palm.y = 0.4 + 0.0015 * cos(Double(i) * 1.7)
        }
        let drift = hypot(events.pointerTotal.dx, events.pointerTotal.dy)
        XCTAssertLessThan(drift, 4, "tremor must not walk the pointer away")
    }

    func testFistLiftsTheTrackpad() {
        let driver = FrameDriver()
        var fist = SyntheticHand()
        fist.fingers = SyntheticHand.fist
        driver.feed(fist, frames: 6)
        let events = driver.feed(fist, frames: 15) { hand, i in
            hand.palm.x = 0.5 + Double(i) * 0.01
        }
        XCTAssertFalse(events.hasPointerMotion, "a fist repositions the hand without moving the pointer")
    }

    func testFastMotionTravelsFurtherThanSlowMotion() {
        func travel(step: Double, frames: Int) -> Double {
            let driver = FrameDriver()
            driver.feed(SyntheticHand(), frames: 8)
            let events = driver.feed(SyntheticHand(), frames: frames) { hand, i in
                hand.palm.x = 0.4 + Double(i + 1) * step
            }
            return events.pointerTotal.dx
        }
        // Same hand travel (0.12), different speeds.
        let slow = travel(step: 0.003, frames: 40)
        let fast = travel(step: 0.015, frames: 8)
        XCTAssertGreaterThan(fast, slow * 1.3, "pointer acceleration: fast flicks cover more ground")
    }

    // MARK: - Click

    func testQuickPinchProducesSingleClick() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        let down = driver.feed(pinched, frames: 4)
        XCTAssertEqual(driver.machine.currentState, .pressed)
        XCTAssertTrue(down.clicks.isEmpty)
        let up = driver.feed(SyntheticHand(), frames: 4)
        XCTAssertEqual(up.clicks, [1])
        XCTAssertEqual(driver.events.count(.leftMouseDown), 0, "a quick pinch is a click, not a drag")
    }

    func testPointerFrozenWhilePressed() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 4)
        // Small wobble below the drag threshold
        let wobble = driver.feed(pinched, frames: 5) { hand, i in
            hand.palm.x = 0.5 + 0.002 * Double(i % 2)
        }
        XCTAssertFalse(wobble.hasPointerMotion)
    }

    func testDoublePinchProducesDoubleClick() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 4)
        driver.feed(SyntheticHand(), frames: 3)
        driver.feed(pinched, frames: 4)
        driver.feed(SyntheticHand(), frames: 3)
        XCTAssertEqual(driver.events.clicks, [1, 2])
    }

    func testSlowSecondPinchIsANewSingleClick() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 4)
        driver.feed(SyntheticHand(), frames: 30) // 1 s apart
        driver.feed(pinched, frames: 4)
        driver.feed(SyntheticHand(), frames: 3)
        XCTAssertEqual(driver.events.clicks, [1, 1])
    }

    func testHandEnteringAlreadyPinchedDoesNotClick() {
        let driver = FrameDriver()
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 10)
        driver.feed(SyntheticHand(), frames: 4)
        XCTAssertTrue(driver.events.clicks.isEmpty, "a pinch must start from an open hand")
    }

    func testFistDoesNotClick() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var fist = SyntheticHand()
        fist.fingers = SyntheticHand.fist
        fist.pinch = 0.12 // curled index tip sits next to the thumb
        driver.feed(fist, frames: 10)
        driver.feed(SyntheticHand(), frames: 6)
        XCTAssertTrue(driver.events.clicks.isEmpty)
    }

    func testPinchRollsBackPointerMotionCausedByClosingFingers() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        // Fingers start closing: distance drops while the knuckles drift right a little.
        var hand = SyntheticHand()
        let closing = driver.feed(hand, frames: 3) { h, i in
            h.pinch = [0.40, 0.30, 0.20][i]
            h.palm.x = 0.5 + 0.004 * Double(i + 1)
        }
        hand.palm.x = 0.512
        hand.pinch = 0.06
        let pressFrames = driver.feed(hand, frames: 3)
        XCTAssertEqual(driver.machine.currentState, .pressed)
        let net = closing.pointerTotal.dx + pressFrames.pointerTotal.dx
        XCTAssertLessThan(abs(net), 1.0, "motion caused by pinching is undone so the click lands where you pointed")
    }

    // MARK: - Drag

    func testHoldingPinchStartsDragAndReleaseDrops() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 20) // ≈0.66 s > hold delay
        XCTAssertEqual(driver.machine.currentState, .dragging)
        XCTAssertEqual(driver.events.count(.leftMouseDown), 1)
        let release = driver.feed(SyntheticHand(), frames: 4)
        XCTAssertEqual(release.count(.leftMouseUp), 1)
        XCTAssertTrue(driver.events.clicks.isEmpty)
    }

    func testMovingWhilePinchedStartsDragImmediately() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 3)
        XCTAssertEqual(driver.machine.currentState, .pressed)
        let move = driver.feed(pinched, frames: 8) { hand, i in
            hand.palm.x = 0.5 + Double(i + 1) * 0.008
        }
        XCTAssertEqual(move.count(.leftMouseDown), 1, "moving while pinched should not wait for the hold delay")
        XCTAssertEqual(driver.machine.currentState, .dragging)
        XCTAssertGreaterThan(move.pointerTotal.dx, 0, "the dragged item follows the hand")
    }

    func testDragSurvivesShortTrackingDropout() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 20)
        XCTAssertEqual(driver.machine.currentState, .dragging)
        let gap = driver.feedNoHand(frames: 4) // ≈130 ms
        XCTAssertEqual(gap.count(.leftMouseUp), 0, "a dropped frame or two must not drop what you're dragging")
        driver.feed(pinched, frames: 3)
        XCTAssertEqual(driver.machine.currentState, .dragging)
    }

    func testDragReleasedWhenHandIsGone() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 20)
        let gone = driver.feedNoHand(frames: 15) // 0.5 s
        XCTAssertEqual(gone.count(.leftMouseUp), 1, "safety: never leave the button stuck down")
    }

    func testEmergencyReleaseDuringDrag() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 20)
        let events = driver.machine.emergencyRelease()
        XCTAssertEqual(events, [.leftMouseUp])
        XCTAssertEqual(driver.machine.currentState, .idle)
    }

    // MARK: - Right click

    func testThumbMiddlePinchRightClicks() {
        let driver = FrameDriver()
        var hand = SyntheticHand()
        hand.partial = [.middle]
        driver.feed(hand, frames: 8)
        hand.middlePinch = 0.08
        driver.feed(hand, frames: 5)
        hand.middlePinch = 0.8
        driver.feed(hand, frames: 4)
        XCTAssertEqual(driver.events.count(.rightClick), 1)
        XCTAssertTrue(driver.events.clicks.isEmpty)
    }

    func testRightClickCanBeDisabled() {
        let machine = GestureStateMachine()
        var config = GestureConfig()
        config.rightClickEnabled = false
        machine.apply(config)
        let driver = FrameDriver(machine: machine)
        var hand = SyntheticHand()
        hand.partial = [.middle]
        driver.feed(hand, frames: 8)
        hand.middlePinch = 0.08
        driver.feed(hand, frames: 5)
        XCTAssertEqual(driver.events.count(.rightClick), 0)
    }

    // MARK: - Scroll

    func testTwoFingersScrollWithPhases() {
        let driver = FrameDriver()
        var v = SyntheticHand()
        v.fingers = SyntheticHand.scroll
        driver.feed(v, frames: 6)
        let scrolling = driver.feed(v, frames: 12) { hand, i in
            hand.palm.y = 0.4 + Double(i + 1) * 0.006
        }
        XCTAssertEqual(driver.machine.currentState, .scrolling)
        XCTAssertEqual(scrolling.scrollPhases.first, .began)
        XCTAssertTrue(scrolling.scrollPhases.dropFirst().allSatisfy { $0 == .changed })
        XCTAssertLessThan(scrolling.scrollTotalY, 0, "natural scrolling: raising the hand pushes content up")
        XCTAssertFalse(scrolling.hasPointerMotion, "the pointer stays put while scrolling")

        let back = driver.feed(SyntheticHand(), frames: 5)
        XCTAssertEqual(back.scrollPhases, [.ended])
    }

    func testTraditionalScrollingInvertsDirection() {
        let machine = GestureStateMachine()
        var config = GestureConfig()
        config.naturalScrolling = false
        machine.apply(config)
        let driver = FrameDriver(machine: machine)
        var v = SyntheticHand()
        v.fingers = SyntheticHand.scroll
        driver.feed(v, frames: 6)
        let events = driver.feed(v, frames: 12) { hand, i in
            hand.palm.y = 0.4 + Double(i + 1) * 0.006
        }
        XCTAssertGreaterThan(events.scrollTotalY, 0)
    }

    func testScrollPoseNeverClicks() {
        let driver = FrameDriver()
        var v = SyntheticHand()
        v.fingers = SyntheticHand.scroll
        v.pinch = 0.9 // thumb tucked away; index and middle side by side
        driver.feed(v, frames: 30) { hand, i in
            hand.palm.y = 0.4 + 0.05 * sin(Double(i) / 4)
        }
        XCTAssertTrue(driver.events.clicks.isEmpty)
        XCTAssertEqual(driver.events.count(.leftMouseDown), 0)
    }

    func testBriefMiddleFingerFlickerDoesNotLeaveScroll() {
        let driver = FrameDriver()
        var v = SyntheticHand()
        v.fingers = SyntheticHand.scroll
        driver.feed(v, frames: 8) { hand, i in hand.palm.y = 0.4 + Double(i) * 0.005 }
        XCTAssertEqual(driver.machine.currentState, .scrolling)
        driver.feed(SyntheticHand(), frames: 1) // one misclassified frame
        driver.feed(v, frames: 3)
        XCTAssertEqual(driver.machine.currentState, .scrolling)
        XCTAssertEqual(driver.events.scrollPhases.filter { $0 == .ended }.count, 0)
    }

    // MARK: - Desktop swipes

    private func openHand(x: Double = 0.5) -> SyntheticHand {
        var h = SyntheticHand()
        h.fingers = SyntheticHand.openHand
        h.palm.x = x
        h.spread = 0.30
        return h
    }

    /// Fast horizontal stroke (0.03 normalized per frame ≈ 6 palm lengths per second), then the
    /// hand stops where it ended.
    @discardableResult
    private func stroke(_ driver: FrameDriver, from x: Double, step: Double, frames: Int = 7, settle: Int = 6) -> [AbstractGestureEvent] {
        var out = driver.feed(openHand(x: x), frames: frames) { hand, i in
            hand.palm.x = x + Double(i + 1) * step
        }
        out += driver.feed(openHand(x: x + Double(frames) * step), frames: settle)
        return out
    }

    /// Slow drag to `to` (≈ 1.3 palm lengths per second) — the desktop just follows.
    @discardableResult
    private func drag(_ driver: FrameDriver, from x: Double, to end: Double) -> [AbstractGestureEvent] {
        let step = (end > x ? 1.0 : -1.0) * 0.006
        let frames = Int((abs(end - x) / 0.006).rounded())
        return driver.feed(openHand(x: x), frames: frames) { hand, i in
            hand.palm.x = x + Double(i + 1) * step
        }
    }

    private func letGo(_ driver: FrameDriver, at x: Double) -> [AbstractGestureEvent] {
        var fist = SyntheticHand()
        fist.fingers = SyntheticHand.fist
        fist.palm.x = x
        return driver.feed(fist, frames: 8)
    }

    func testDesktopFollowsTheHand() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.35), frames: 12)
        let events = drag(driver, from: 0.35, to: 0.45)
        XCTAssertEqual(events.count(.desktopSwipeBegan), 1)
        let progress = events.swipeProgress
        XCTAssertGreaterThan(progress.count, 8, "an update every frame")
        XCTAssertEqual(progress, progress.sorted(), "moves steadily with the hand")
        XCTAssertEqual(progress.last ?? 0, 0.10 / 0.15 / 1.5, accuracy: 0.08)
        XCTAssertTrue(events.switches.isEmpty, "nothing switches until the hand lets go")
        XCTAssertEqual(driver.machine.currentState, .swipingDesktop)
    }

    func testLettingGoPastHalfwaySwitches() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.30), frames: 12)
        drag(driver, from: 0.30, to: 0.45) // ≈ 0.67 of a desktop
        letGo(driver, at: 0.45)
        XCTAssertEqual(driver.events.switches, [.right])
    }

    func testLettingGoBeforeHalfwaySnapsBack() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.30), frames: 12)
        drag(driver, from: 0.30, to: 0.36) // ≈ 0.27 of a desktop
        letGo(driver, at: 0.36)
        XCTAssertTrue(driver.events.switches.isEmpty)
        XCTAssertEqual(driver.events.cancelledSwipes, 1)
    }

    func testDraggingBackBeforeLettingGoCancels() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.30), frames: 12)
        drag(driver, from: 0.30, to: 0.45)
        drag(driver, from: 0.45, to: 0.33)
        letGo(driver, at: 0.33)
        XCTAssertTrue(driver.events.switches.isEmpty)
        XCTAssertEqual(driver.events.cancelledSwipes, 1)
    }

    func testHoldingStillCountsAsLettingGo() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.30), frames: 12)
        drag(driver, from: 0.30, to: 0.45)
        driver.feed(openHand(x: 0.45), frames: 15)
        XCTAssertEqual(driver.events.switches, [.right])
    }

    func testFlickShortOfHalfwaySwitches() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.40), frames: 12)
        stroke(driver, from: 0.40, step: 0.03, frames: 3) // ≈ 0.4 of a desktop, fast
        XCTAssertEqual(driver.events.switches, [.right])
    }

    func testFastSwipeRightSwitchesRight() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.35), frames: 12)
        let events = stroke(driver, from: 0.35, step: 0.03)
        XCTAssertEqual(events.switches, [.right])
    }

    func testFastSwipeLeftSwitchesLeft() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.65), frames: 12)
        let events = stroke(driver, from: 0.65, step: -0.03)
        XCTAssertEqual(events.switches, [.left])
    }

    // Winding up the other way first only makes the desktop peek; where the hand ends decides.
    func testWindUpThenSwipeGoesTheIntendedWay() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.45), frames: 12)
        driver.feed(openHand(x: 0.45), frames: 4) { hand, i in hand.palm.x = 0.45 - Double(i + 1) * 0.01 }
        stroke(driver, from: 0.41, step: 0.03, frames: 8)
        XCTAssertEqual(driver.events.switches, [.right])
    }

    func testReturnStrokeDoesNotUndoTheSwitch() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.35), frames: 12)
        stroke(driver, from: 0.35, step: 0.03, settle: 0)
        // Bring the hand straight back, just as fast.
        stroke(driver, from: 0.56, step: -0.03)
        driver.feed(openHand(x: 0.35), frames: 10)
        XCTAssertEqual(driver.events.switches, [.right], "bringing the hand back must not switch back")
        XCTAssertEqual(driver.events.count(.desktopSwipeBegan), 1, "nor drag the desktop back")
    }

    func testRepeatedSwipesHopMultipleDesktops() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.35), frames: 12)
        stroke(driver, from: 0.35, step: 0.03, settle: 0)
        // Relaxed return, then swipe again — no pause needed.
        driver.feed(openHand(x: 0.56), frames: 16) { hand, i in hand.palm.x = 0.56 - Double(i) * 0.013 }
        stroke(driver, from: 0.35, step: 0.03)
        XCTAssertEqual(driver.events.switches, [.right, .right])
    }

    func testOppositeSwipeWorksAfterLockout() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.35), frames: 12)
        stroke(driver, from: 0.35, step: 0.03)
        driver.feed(openHand(x: 0.56), frames: 35) // ~1.2 s rest
        stroke(driver, from: 0.56, step: -0.03)
        XCTAssertEqual(driver.events.switches, [.right, .left])
    }

    func testRestingHandDriftDoesNotStartASwipe() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.30), frames: 12)
        driver.feed(openHand(x: 0.30), frames: 90) { hand, i in
            hand.palm.x = 0.30 + Double(i) * 0.0008 // ≈ 0.16 palm lengths per second
        }
        XCTAssertEqual(driver.events.count(.desktopSwipeBegan), 0)
    }

    func testVerticalMotionDoesNotSwipe() {
        let driver = FrameDriver()
        driver.feed(openHand(), frames: 12)
        driver.feed(openHand(), frames: 8) { hand, i in
            hand.palm.y = 0.3 + Double(i + 1) * 0.03
            hand.palm.x = 0.5 + Double(i + 1) * 0.008
        }
        XCTAssertEqual(driver.events.count(.desktopSwipeBegan), 0)
        XCTAssertTrue(driver.events.switches.isEmpty)
    }

    func testSwipeSurvivesMotionBlurMidStroke() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.35), frames: 12)
        driver.feed(openHand(x: 0.35), frames: 7) { hand, i in
            hand.palm.x = 0.35 + Double(i + 1) * 0.03
            if i == 2 || i == 3 { hand.fingers = [.index, .middle] } // fingers smeared
        }
        driver.feed(openHand(x: 0.56), frames: 6)
        XCTAssertEqual(driver.events.switches, [.right])
        XCTAssertEqual(driver.events.count(.desktopSwipeBegan), 1)
    }

    func testHandLostMidSwipeDecidesLikeLettingGo() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.30), frames: 12)
        drag(driver, from: 0.30, to: 0.45)
        driver.feedNoHand(frames: 12)
        XCTAssertEqual(driver.events.switches, [.right])
        XCTAssertEqual(driver.machine.currentState, .handLost)
    }

    func testOpenHandSweepingIntoViewDoesNotSwitch() {
        let driver = FrameDriver()
        // The hand appears already moving fast (entering from the side).
        let events = driver.feed(openHand(x: 0.10), frames: 9) { hand, i in
            hand.palm.x = 0.10 + Double(i) * 0.03
        }
        XCTAssertEqual(events.count(.desktopSwipeBegan), 0)
    }

    func testSwipeNeedsAnOpenHand() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 6)
        driver.feed(SyntheticHand(), frames: 7) { hand, i in
            hand.palm.x = 0.35 + Double(i + 1) * 0.03
        }
        XCTAssertTrue(driver.events.switches.isEmpty, "a fast pointing motion moves the pointer, it doesn't switch desktops")
        XCTAssertEqual(driver.events.count(.desktopSwipeBegan), 0)
    }

    func testNaturalSwipeDirectionInverts() {
        let machine = GestureStateMachine()
        var config = GestureConfig()
        config.naturalSwipeDirection = true
        machine.apply(config)
        let driver = FrameDriver(machine: machine)
        driver.feed(openHand(x: 0.35), frames: 12)
        let events = stroke(driver, from: 0.35, step: 0.03)
        XCTAssertEqual(events.switches, [.left])
        XCTAssertLessThan(events.swipeProgress.last ?? 0, 0, "the desktop follows the hand")
    }

    func testNoClickRightAfterSwipe() {
        let driver = FrameDriver()
        driver.feed(openHand(x: 0.35), frames: 12)
        stroke(driver, from: 0.35, step: 0.03, settle: 0)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 5)
        driver.feed(SyntheticHand(), frames: 3)
        XCTAssertTrue(driver.events.clicks.isEmpty)
    }

    // MARK: - Mission Control

    private func palm(spread: Double) -> SyntheticHand {
        var h = SyntheticHand()
        h.fingers = SyntheticHand.openPalm
        h.spread = spread
        return h
    }

    func testFiveFingerGatherAndOpenTriggersMissionControl() {
        let driver = FrameDriver()
        driver.feed(palm(spread: 0.55), frames: 6)
        driver.feed(palm(spread: 0.55), frames: 6) { hand, i in hand.spread = 0.55 - Double(i + 1) * 0.07 }
        driver.feed(palm(spread: 0.15), frames: 2)
        driver.feed(palm(spread: 0.15), frames: 6) { hand, i in hand.spread = 0.15 + Double(i + 1) * 0.07 }
        XCTAssertEqual(driver.events.count(.triggerMissionControl), 1)
        XCTAssertTrue(driver.events.clicks.isEmpty)
    }

    func testGatherAsFistWithThumbTouchingIndexDoesNotClick() {
        let driver = FrameDriver()
        driver.feed(palm(spread: 0.55), frames: 6)
        driver.feed(palm(spread: 0.55), frames: 6) { hand, i in
            hand.spread = 0.55 - Double(i + 1) * 0.07
            hand.pinch = max(0.06, 0.6 - Double(i + 1) * 0.1)
            if i >= 2 { hand.fingers = SyntheticHand.fist }
        }
        driver.feed(palm(spread: 0.15), frames: 6) { hand, i in
            hand.spread = 0.15 + Double(i + 1) * 0.07
        }
        XCTAssertEqual(driver.events.count(.triggerMissionControl), 1)
        XCTAssertTrue(driver.events.clicks.isEmpty)
        XCTAssertEqual(driver.events.count(.leftMouseDown), 0)
    }

    func testStaticOpenPalmDoesNothing() {
        let driver = FrameDriver()
        driver.feed(palm(spread: 0.55), frames: 60)
        XCTAssertTrue(driver.events.isEmpty)
    }

    func testOpenHandThenPointingMovesPointerPromptly() {
        let driver = FrameDriver()
        driver.feed(palm(spread: 0.55), frames: 8)
        driver.feed(SyntheticHand(), frames: 6)
        let events = driver.feed(SyntheticHand(), frames: 10) { hand, i in
            hand.palm.x = 0.5 + Double(i + 1) * 0.006
        }
        XCTAssertGreaterThan(events.pointerTotal.dx, 10, "leaving the open hand must not lock the pointer")
    }

    // MARK: - Lifecycle

    func testResetReturnsToIdle() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        _ = driver.machine.reset()
        XCTAssertEqual(driver.machine.currentState, .idle)
    }

    func testHandLossWithoutActivityEmitsNothing() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        let events = driver.feedNoHand(frames: 20)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(driver.machine.currentState, .handLost)
    }
}
