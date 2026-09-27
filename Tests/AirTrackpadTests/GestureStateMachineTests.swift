import XCTest
@testable import AirTrackpadCore

final class GestureStateMachineTests: XCTestCase {
    
    private func makeHand(
        timestamp: TimeInterval,
        extendedFingers: Int,
        pinchDistance: Double,
        indexTip: Landmark = Landmark(x: 0.5, y: 0.5)
    ) -> (HandObservation, HandMetrics) {
        let wrist = Landmark(x: 0.5, y: 0.1)
        let middleMCP = Landmark(x: 0.5, y: 0.3)
        let thumbTip = Landmark(x: indexTip.x - pinchDistance * 0.2, y: indexTip.y)
        
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
            centroid: indexTip,
            spread: 0.5,
            pinchDistance: pinchDistance,
            handScale: 0.2
        )
        
        return (hand, metrics)
    }
    
    func testCursorFreezeOnTwoFingers() {
        let sm = GestureStateMachine()
        
        // 1 finger extended -> ONE_FINGER_CURSOR
        let (h1, m1) = makeHand(timestamp: 1.0, extendedFingers: 1, pinchDistance: 0.5)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.0)
        XCTAssertEqual(sm.currentState, .oneFingerCursor)
        
        // 2 fingers appear -> TWO_FINGER_PAUSED (cursor frozen)
        let (h2, m2) = makeHand(timestamp: 1.016, extendedFingers: 2, pinchDistance: 0.5)
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.016)
        XCTAssertEqual(sm.currentState, .twoFingerDetected)
    }
    
    func testQuickPinchProducesLeftClick() {
        let sm = GestureStateMachine()
        sm.updateCursorPosition(CGPoint(x: 500, y: 400))
        
        // 1. Two fingers detected (open)
        let (h1, m1) = makeHand(timestamp: 1.0, extendedFingers: 2, pinchDistance: 0.4)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.0)
        
        // 2. Pinch starts (D < 0.22)
        let (h2, m2) = makeHand(timestamp: 1.05, extendedFingers: 2, pinchDistance: 0.15)
        let events2 = sm.process(hand: h2, metrics: m2, timestamp: 1.05)
        XCTAssertEqual(sm.currentState, .pinchCandidate)
        XCTAssertTrue(events2.isEmpty)
        
        // 3. Pinch releases quickly at 1.15s (100ms later, D > 0.30)
        let (h3, m3) = makeHand(timestamp: 1.15, extendedFingers: 2, pinchDistance: 0.35)
        let events3 = sm.process(hand: h3, metrics: m3, timestamp: 1.15)
        
        // Should produce exactly one leftClick event!
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
        
        // 1. Two fingers detected
        let (h1, m1) = makeHand(timestamp: 1.0, extendedFingers: 2, pinchDistance: 0.4)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.0)
        
        // 2. Pinch starts at t = 1.05
        let (h2, m2) = makeHand(timestamp: 1.05, extendedFingers: 2, pinchDistance: 0.15)
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.05)
        
        // 3. Pinch sustained beyond dragHoldDelay (0.35s) -> t = 1.45s
        let (h3, m3) = makeHand(timestamp: 1.45, extendedFingers: 2, pinchDistance: 0.15)
        let events3 = sm.process(hand: h3, metrics: m3, timestamp: 1.45)
        
        XCTAssertEqual(sm.currentState, .dragging)
        XCTAssertEqual(events3.count, 1)
        if case .leftMouseDown = events3.first {
            // Success
        } else {
            XCTFail("Expected leftMouseDown event")
        }
        
        // 4. Release pinch -> mouseUp
        let (h4, m4) = makeHand(timestamp: 1.80, extendedFingers: 2, pinchDistance: 0.40)
        let events4 = sm.process(hand: h4, metrics: m4, timestamp: 1.80)
        
        XCTAssertEqual(events4.count, 1)
        if case .leftMouseUp = events4.first {
            // Success
        } else {
            XCTFail("Expected leftMouseUp event")
        }
    }
    
    func testSafetyInvariantMouseUpOnHandLoss() {
        let sm = GestureStateMachine()
        
        // 1. Enter dragging
        let (h1, m1) = makeHand(timestamp: 1.0, extendedFingers: 2, pinchDistance: 0.4)
        _ = sm.process(hand: h1, metrics: m1, timestamp: 1.0)
        let (h2, m2) = makeHand(timestamp: 1.05, extendedFingers: 2, pinchDistance: 0.15)
        _ = sm.process(hand: h2, metrics: m2, timestamp: 1.05)
        let (h3, m3) = makeHand(timestamp: 1.45, extendedFingers: 2, pinchDistance: 0.15)
        _ = sm.process(hand: h3, metrics: m3, timestamp: 1.45)
        XCTAssertEqual(sm.currentState, .dragging)
        
        // 2. Hand disappears completely!
        let eventsLoss = sm.process(hand: nil, metrics: nil, timestamp: 1.50)
        
        // SAFETY: leftMouseUp MUST be dispatched!
        XCTAssertEqual(eventsLoss.count, 1)
        if case .leftMouseUp = eventsLoss.first {
            // Safety invariant verified
        } else {
            XCTFail("Critical safety failure: Mouse button stuck down on hand loss!")
        }
    }
}
