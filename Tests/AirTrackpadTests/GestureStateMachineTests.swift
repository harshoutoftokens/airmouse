import XCTest
@testable import AirTrackpadCore

final class GestureStateMachineTests: XCTestCase {
    
    private func makeHand(
        timestamp: TimeInterval,
        extendedFingers: Int,
        pinchDistance: Double,
        spread: Double = 0.5,
        centroid: Landmark = Landmark(x: 0.5, y: 0.5)
    ) -> (HandObservation, HandMetrics) {
        let wrist = Landmark(x: centroid.x, y: 0.1)
        let middleMCP = Landmark(x: centroid.x, y: 0.3)
        let thumbTip = Landmark(x: centroid.x - pinchDistance * 0.2, y: centroid.y)
        let indexTip = centroid
        
        let joints: [JointName: Landmark] = [
            .wrist: wrist,
            .middleMCP: middleMCP,
            .indexTip: indexTip,
            .thumbTip: thumbTip
        ]
        
        let hand = HandObservation(
            timestamp: timestamp,
            chirality: .right,
            confidence: 0.95,
            joints: joints
        )
        
        var fingerStates: [Finger: FingerState] = [:]
        fingerStates[.index] = extendedFingers >= 1 ? .extended : .folded
        fingerStates[.middle] = extendedFingers >= 2 ? .extended : .folded
        fingerStates[.ring] = extendedFingers >= 3 ? .extended : .folded
        fingerStates[.little] = extendedFingers >= 4 ? .extended : .folded
        fingerStates[.thumb] = extendedFingers >= 5 ? .extended : .folded
        
        let metrics = HandMetrics(
            timestamp: timestamp,
            extendedFingerCount: extendedFingers,
            fingerStates: fingerStates,
            centroid: centroid,
            spread: spread,
            pinchDistance: pinchDistance,
            handScale: 0.2
        )
        
        return (hand, metrics)
    }
    
    func testCursorFreezeOnTwoFingers() {
        let sm = GestureStateMachine()
        
        let (h1, m1) = makeHand(timestamp: 1.0, extendedFingers: 1, pinchDistance: 0.5)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.0)
        XCTAssertEqual(sm.currentState, .oneFingerCursor)
        
        let (h2, m2) = makeHand(timestamp: 1.016, extendedFingers: 2, pinchDistance: 0.5)
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.016)
        XCTAssertEqual(sm.currentState, .twoFingerDetected)
    }
    
    func testQuickPinchProducesLeftClick() {
        let sm = GestureStateMachine()
        sm.updateCursorPosition(CGPoint(x: 500, y: 400))
        
        let (h1, m1) = makeHand(timestamp: 1.0, extendedFingers: 2, pinchDistance: 0.4)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.0)
        
        let (h2, m2) = makeHand(timestamp: 1.05, extendedFingers: 2, pinchDistance: 0.15)
        let events2 = sm.process(hand: h2, metrics: m2, timestamp: 1.05)
        XCTAssertEqual(sm.currentState, .pinchCandidate)
        XCTAssertTrue(events2.isEmpty)
        
        let (h3, m3) = makeHand(timestamp: 1.15, extendedFingers: 2, pinchDistance: 0.35)
        let events3 = sm.process(hand: h3, metrics: m3, timestamp: 1.15)
        
        XCTAssertEqual(events3.count, 1)
        if case .leftClick(let pos) = events3.first {
            XCTAssertEqual(pos.x, 500)
            XCTAssertEqual(pos.y, 400)
        } else {
            XCTFail("Expected leftClick event")
        }
    }
    
    func testSustainedPinchEntersDragAndReleasesMouseUp() {
        let sm = GestureStateMachine()
        sm.updateCursorPosition(CGPoint(x: 300, y: 300))
        
        let (h1, m1) = makeHand(timestamp: 1.0, extendedFingers: 2, pinchDistance: 0.4)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.0)
        
        let (h2, m2) = makeHand(timestamp: 1.05, extendedFingers: 2, pinchDistance: 0.15)
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.05)
        
        let (h3, m3) = makeHand(timestamp: 2.00, extendedFingers: 2, pinchDistance: 0.15)
        let events3 = sm.process(hand: h3, metrics: m3, timestamp: 2.00)
        
        XCTAssertEqual(sm.currentState, .dragging)
        XCTAssertEqual(events3.count, 1)
        if case .leftMouseDown = events3.first {
            // Success
        } else {
            XCTFail("Expected leftMouseDown event")
        }
        
        let (h4, m4) = makeHand(timestamp: 2.30, extendedFingers: 2, pinchDistance: 0.40)
        let events4 = sm.process(hand: h4, metrics: m4, timestamp: 2.30)
        
        XCTAssertEqual(events4.count, 1)
        if case .leftMouseUp = events4.first {
            // Success
        } else {
            XCTFail("Expected leftMouseUp event")
        }
    }
    
    func testSafetyInvariantMouseUpOnHandLoss() {
        let sm = GestureStateMachine()
        
        let (h1, m1) = makeHand(timestamp: 1.0, extendedFingers: 2, pinchDistance: 0.4)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.0)
        let (h2, m2) = makeHand(timestamp: 1.05, extendedFingers: 2, pinchDistance: 0.15)
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.05)
        let (h3, m3) = makeHand(timestamp: 2.00, extendedFingers: 2, pinchDistance: 0.15)
        _ = sm.process(hand: h3, metrics: m3, timestamp: 2.00)
        XCTAssertEqual(sm.currentState, .dragging)
        
        let eventsLoss = sm.process(hand: nil, metrics: nil, timestamp: 2.05)
        XCTAssertEqual(eventsLoss.count, 1)
        if case .leftMouseUp = eventsLoss.first {
            // Success
        } else {
            XCTFail("Critical safety failure: Mouse button stuck down on hand loss!")
        }
    }
    
    // MARK: - Phase 6 Tests: 4-Finger Fast Swipe
    func testFourFingerFastSwipeRight() {
        let sm = GestureStateMachine()
        
        // 4 fingers moving from x=0.30 to x=0.45 in 0.15s (dx = +0.15, velocity = 1.0 norm/s)
        let (h1, m1) = makeHand(timestamp: 1.00, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.30, y: 0.50))
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.00)
        
        let (h2, m2) = makeHand(timestamp: 1.08, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.38, y: 0.50))
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.08)
        
        let (h3, m3) = makeHand(timestamp: 1.15, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.45, y: 0.50))
        let events = sm.process(hand: h3, metrics: m3, timestamp: 1.15)
        
        XCTAssertEqual(events.count, 1)
        if case .switchSpace(let dir) = events.first {
            XCTAssertEqual(dir, .right)
        } else {
            XCTFail("Expected switchSpace(.right)")
        }
    }
    
    func testFourFingerFastSwipeLeft() {
        let sm = GestureStateMachine()
        
        // 4 fingers moving from x=0.60 to x=0.45 in 0.15s (dx = -0.15, velocity = 1.0 norm/s)
        let (h1, m1) = makeHand(timestamp: 1.00, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.60, y: 0.50))
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.00)
        
        let (h2, m2) = makeHand(timestamp: 1.08, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.52, y: 0.50))
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.08)
        
        let (h3, m3) = makeHand(timestamp: 1.15, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.45, y: 0.50))
        let events = sm.process(hand: h3, metrics: m3, timestamp: 1.15)
        
        XCTAssertEqual(events.count, 1)
        if case .switchSpace(let dir) = events.first {
            XCTAssertEqual(dir, .left)
        } else {
            XCTFail("Expected switchSpace(.left)")
        }
    }
    
    func testFourFingerVerticalMovementRejected() {
        let sm = GestureStateMachine()
        
        // 4 fingers moving predominantly vertically (dx = 0.05, dy = 0.20)
        let (h1, m1) = makeHand(timestamp: 1.00, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.50, y: 0.30))
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.00)
        
        let (h2, m2) = makeHand(timestamp: 1.10, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.52, y: 0.40))
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.10)
        
        let (h3, m3) = makeHand(timestamp: 1.15, extendedFingers: 4, pinchDistance: 0.5, centroid: Landmark(x: 0.55, y: 0.50))
        let events = sm.process(hand: h3, metrics: m3, timestamp: 1.15)
        
        // Should be rejected because movement is vertical, not horizontal
        XCTAssertTrue(events.isEmpty)
    }
    
    // MARK: - Phase 7 Tests: 5-Finger Mission Control Sequence
    func testFiveFingerMissionControlSequence() {
        let sm = GestureStateMachine()
        
        // 1. Five extended fingers (open palm, spread = 0.55)
        let (h1, m1) = makeHand(timestamp: 1.00, extendedFingers: 5, pinchDistance: 0.5, spread: 0.55)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.00)
        XCTAssertEqual(sm.currentState, .fiveFingerOpen)
        
        // 2. Converge / Contracting (spread drops to 0.35)
        let (h2, m2) = makeHand(timestamp: 1.15, extendedFingers: 5, pinchDistance: 0.3, spread: 0.35)
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.15)
        XCTAssertEqual(sm.currentState, .fiveFingerContracting)
        
        // 3. Pinch Lock (spread <= 0.22) -> ARMED
        let (h3, m3) = makeHand(timestamp: 1.25, extendedFingers: 5, pinchDistance: 0.15, spread: 0.18)
        let events3 = sm.process(hand: h3, metrics: m3, timestamp: 1.25)
        XCTAssertEqual(sm.currentState, .fiveFingerPinchLocked)
        // CRITICAL: Mission control is NOT triggered on pinch!
        XCTAssertTrue(events3.isEmpty)
        
        // 4. Expanding (spread increases to 0.35)
        let (h4, m4) = makeHand(timestamp: 1.40, extendedFingers: 5, pinchDistance: 0.35, spread: 0.35)
        _ = sm.process(hand: h4, metrics: m4, timestamp: 1.40)
        XCTAssertEqual(sm.currentState, .fiveFingerExpanding)
        
        // 5. Open Palm Reached (spread >= 0.48) -> TRIGGER MISSION CONTROL!
        let (h5, m5) = makeHand(timestamp: 1.55, extendedFingers: 5, pinchDistance: 0.5, spread: 0.52)
        let events5 = sm.process(hand: h5, metrics: m5, timestamp: 1.55)
        
        XCTAssertEqual(events5.count, 1)
        if case .triggerMissionControl = events5.first {
            // Success
        } else {
            XCTFail("Expected triggerMissionControl event")
        }
        XCTAssertEqual(sm.currentState, .cooldown)
    }
    
    func testFiveFingerStaticOpenPalmDoesNotTriggerMissionControl() {
        let sm = GestureStateMachine()
        
        // User merely shows an open palm without the pinch->open sequence
        for i in 0..<10 {
            let t = 1.0 + Double(i) * 0.05
            let (h, m) = makeHand(timestamp: t, extendedFingers: 5, pinchDistance: 0.5, spread: 0.55)
            let events = sm.process(hand: h, metrics: m, timestamp: t)
            XCTAssertTrue(events.isEmpty, "Static open palm should never trigger Mission Control")
        }
    }
    
    func testSwipeWorksFromFiveFingerOpenPose() {
        let sm = GestureStateMachine()
        
        // Hand starts in 5-finger open pose at x=0.30
        let (h1, m1) = makeHand(timestamp: 1.00, extendedFingers: 5, pinchDistance: 0.5, spread: 0.52, centroid: Landmark(x: 0.30, y: 0.50))
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.00)
        
        // Hand moves horizontally to x=0.45 across 0.15s (10cm displacement)
        let (h2, m2) = makeHand(timestamp: 1.15, extendedFingers: 5, pinchDistance: 0.5, spread: 0.50, centroid: Landmark(x: 0.45, y: 0.50))
        let events = sm.process(hand: h2, metrics: m2, timestamp: 1.15)
        
        XCTAssertEqual(events.count, 1)
        if case .switchSpace(let dir) = events.first {
            XCTAssertEqual(dir, .right)
        } else {
            XCTFail("Expected switchSpace event when swiping with open hand")
        }
    }
}
