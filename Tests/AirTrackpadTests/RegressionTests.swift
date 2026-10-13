import XCTest
@testable import AirTrackpadCore

/// Regression tests for issues found in code review of the 1.1 rewrite.
final class RegressionTests: XCTestCase {

    private func palm(spread: Double) -> SyntheticHand {
        var h = SyntheticHand()
        h.fingers = SyntheticHand.openPalm
        h.spread = spread
        return h
    }

    private func startDrag(_ driver: FrameDriver) {
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 20)
        XCTAssertEqual(driver.machine.currentState, .dragging)
    }

    // Abandoned Mission Control gather (held past the time limit) must not become a click/drag.
    func testAbandonedMissionControlGatherDoesNotClickOrDrag() {
        let driver = FrameDriver()
        driver.feed(palm(spread: 0.55), frames: 8)
        driver.feed(palm(spread: 0.55), frames: 6) { hand, i in
            hand.spread = 0.55 - Double(i + 1) * 0.07
            hand.pinch = max(0.06, 0.6 - Double(i + 1) * 0.1)
        }
        // Keep the fingertips gathered for 2 s, then settle into a point while still pinched.
        var gathered = SyntheticHand()
        gathered.fingers = SyntheticHand.fist
        gathered.spread = 0.12
        gathered.pinch = 0.06
        driver.feed(gathered, frames: 60)
        var stillPinched = SyntheticHand()
        stillPinched.pinch = 0.06
        driver.feed(stillPinched, frames: 30)
        XCTAssertEqual(driver.events.count(.leftMouseDown), 0)
        XCTAssertTrue(driver.events.clicks.isEmpty)
        XCTAssertEqual(driver.events.count(.triggerMissionControl), 0)
    }

    // A frame where the fingertips weren't observed must not end a drag.
    func testUntrackedFingertipFrameHoldsDrag() {
        let driver = FrameDriver()
        startDrag(driver)
        var lost = SyntheticHand()
        lost.pinch = 1.0 // what an unobserved tip used to read as
        lost.pinchTracked = false
        let glitch = driver.feed(lost, frames: 3)
        XCTAssertEqual(glitch.count(.leftMouseUp), 0)
        XCTAssertEqual(driver.machine.currentState, .dragging)
    }

    // A single glitched (but "tracked") landmark frame must not end a drag either.
    func testSingleGlitchFrameDoesNotDropDrag() {
        let driver = FrameDriver()
        startDrag(driver)
        var glitch = SyntheticHand()
        glitch.pinch = 1.0
        driver.feed(glitch, frames: 1)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 4)
        XCTAssertEqual(driver.events.count(.leftMouseUp), 0)
        XCTAssertEqual(driver.events.count(.leftMouseDown), 1, "no drop-and-regrab")
    }

    // Direct mode: the pointer must follow the hand closely during a drag.
    func testAbsoluteDragFollowsHandWithoutPinchDeadZone() {
        let mapper = ScreenMapper(minX: 0.2, maxX: 0.8, minY: 0.2, maxY: 0.8, screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let cursor = CursorEngine(mapper: mapper)
        cursor.mode = .absolute
        let driver = FrameDriver(machine: GestureStateMachine(cursor: cursor))
        startDrag(driver)
        let moves = driver.feed({ var h = SyntheticHand(); h.pinch = 0.08; return h }(), frames: 20) { hand, i in
            hand.palm.x = 0.5 + Double(i + 1) * 0.004
        }
        let targets = moves.compactMap { e -> CGPoint? in
            if case .pointerWarp(let p) = e { return p } else { return nil }
        }
        let expected = mapper.mapToScreen(normalizedX: 0.58, normalizedY: 0.475).x
        XCTAssertLessThan(abs(Double((targets.last?.x ?? 0) - expected)), 22, "filter lag only — no extra ~20 pt pinch leash while dragging")
    }

    // Click rollback must not break double clicks: knuckle drift while the second pinch closes
    // is undone, so the second click lands where the first did and counts as a double click.
    func testDoubleClickSurvivesRollback() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        driver.feed(pinched, frames: 4)
        driver.feed(SyntheticHand(), frames: 6) // released; past the post-click settle
        let closing = driver.feed(SyntheticHand(), frames: 4) { hand, i in
            hand.pinch = [0.40, 0.33, 0.27, 0.23][i]
            hand.palm.x = 0.5 + 0.007 * Double(i + 1)
        }
        var second = SyntheticHand()
        second.palm.x = 0.528
        second.pinch = 0.06
        let press = driver.feed(second, frames: 3)
        var open = SyntheticHand()
        open.palm.x = 0.528
        driver.feed(open, frames: 3)
        let drift = closing.pointerTotal.dx
        XCTAssertGreaterThan(drift, 8, "scenario must drift more than the double-click tolerance")
        XCTAssertLessThan(abs(drift + press.pointerTotal.dx), 1.0, "drift was rolled back")
        XCTAssertEqual(driver.events.clicks, [1, 2])
    }
    
    // Grazing the index while holding a right-click pinch must not add a left click.
    func testRightPinchBlocksLeftClick() {
        let driver = FrameDriver()
        var hand = SyntheticHand()
        hand.partial = [.middle]
        driver.feed(hand, frames: 8)
        hand.middlePinch = 0.08
        driver.feed(hand, frames: 5)
        hand.pinch = 0.08 // thumb brushes the index tip too
        driver.feed(hand, frames: 4)
        hand.pinch = 0.6
        hand.middlePinch = 0.8
        driver.feed(hand, frames: 4)
        XCTAssertEqual(driver.events.count(.rightClick), 1)
        XCTAssertTrue(driver.events.clicks.isEmpty)
    }

    // Live logs: quick clicks became two-frame drags because opening the fingers moves the
    // knuckles past the drag threshold before the release is confirmed.
    func testOpeningFingersDoNotTurnAClickIntoADrag() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.06
        // A ~0.3 s click with the slight drift of a hand held in the air…
        driver.feed(pinched, frames: 9) { hand, i in hand.palm.x = 0.5 + 0.0015 * Double(i + 1) }
        // …then the knuckles swing as the index extends.
        driver.feed(pinched, frames: 5) { hand, i in
            hand.pinch = [0.14, 0.27, 0.40, 0.50, 0.55][i]
            hand.palm.x = 0.5135 + 0.012 * Double(i + 1)
        }
        XCTAssertEqual(driver.events.count(.leftMouseDown), 0)
        XCTAssertEqual(driver.events.clicks, [1])
    }

    // …while a deliberate move with the pinch held still starts a drag.
    func testMovingWhilePinchedStillDrags() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.06
        driver.feed(pinched, frames: 9)
        driver.feed(pinched, frames: 6) { hand, i in hand.palm.x = 0.5 + 0.012 * Double(i + 1) }
        XCTAssertEqual(driver.events.count(.leftMouseDown), 1)
    }

    // A pinch landing stops scroll momentum, like touching a trackpad.
    func testPinchPressCancelsMomentum() {
        let driver = FrameDriver()
        driver.feed(SyntheticHand(), frames: 8)
        var pinched = SyntheticHand()
        pinched.pinch = 0.08
        let press = driver.feed(pinched, frames: 4)
        XCTAssertEqual(press.count(.cancelMomentum), 1)
    }

    func testRouterStopsMomentumOnCancel() {
        let backend = MockInputBackend()
        let router = ActionRouter(backend: backend, smoothing: true)
        router.layout = DisplayLayout(displays: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        router.handle(event: .scroll(deltaX: 0, deltaY: -40, phase: .began))
        router.handle(event: .scroll(deltaX: 0, deltaY: -40, phase: .changed))
        pause(0.05)
        router.handle(event: .scroll(deltaX: 0, deltaY: 0, phase: .ended))
        pause(0.08)
        router.handle(event: .cancelMomentum)
        router.waitUntilIdle()
        let countAtCancel = backend.scrollEvents.count
        pause(0.2)
        router.waitUntilIdle()
        XCTAssertTrue(backend.scrollEvents.contains { $0.momentumPhase == .begin }, "momentum started")
        XCTAssertEqual(backend.scrollEvents.last?.momentumPhase, .end)
        XCTAssertEqual(backend.scrollEvents.count, countAtCancel, "no momentum after cancel")
    }

    // Nothing may be posted after the router is disabled (app quitting).
    func testDisabledRouterReleasesAndDropsQueuedEvents() {
        let backend = MockInputBackend()
        let router = ActionRouter(backend: backend, smoothing: true)
        router.handle(event: .leftMouseDown)
        router.waitUntilIdle()
        XCTAssertTrue(backend.isMouseDown)
        router.setEnabled(false)
        XCTAssertFalse(backend.isMouseDown)
        router.handle(event: .leftMouseDown)
        router.waitUntilIdle()
        XCTAssertFalse(backend.isMouseDown)
    }

    // An unreadable value must not wipe the other settings.
    func testUnknownEnumValueKeepsOtherSettings() throws {
        let json = #"{"settingsVersion":2,"spaceSwitchStyle":"teleport","pointerSpeed":2.0,"isAlwaysOnTop":true}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.pointerSpeed, 2.0)
        XCTAssertTrue(decoded.isAlwaysOnTop)
        XCTAssertEqual(decoded.spaceSwitchStyle, AppSettings().spaceSwitchStyle)
    }

    // A synthesized (extrapolated) fingertip must not be used for pinch distance.
    func testSynthesizedTipIsNotTrackedForPinch() {
        let joints: [JointName: Landmark] = [
            .wrist: Landmark(x: 0.5, y: 0.1), .middleMCP: Landmark(x: 0.5, y: 0.35),
            .indexMCP: Landmark(x: 0.45, y: 0.35), .littleMCP: Landmark(x: 0.6, y: 0.33),
            .indexTip: Landmark(x: 0.45, y: 0.8, confidence: 0.5), .thumbTip: Landmark(x: 0.44, y: 0.33)
        ]
        let hand = HandObservation(timestamp: 0, chirality: .right, confidence: 1, joints: joints, synthesizedJoints: [.indexTip])
        let metrics = FingerClassifier.extractMetrics(from: hand)
        XCTAssertFalse(metrics.pinchTracked)
        let observed = HandObservation(timestamp: 0, chirality: .right, confidence: 1, joints: joints)
        XCTAssertTrue(FingerClassifier.extractMetrics(from: observed).pinchTracked)
    }

    private func pause(_ seconds: TimeInterval) {
        let done = expectation(description: "pause")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 1)
    }
}
