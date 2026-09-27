import XCTest
@testable import AirTrackpadCore

final class GestureReplayTests: XCTestCase {
    
    private func createSyntheticHand(
        timestamp: TimeInterval,
        extendedFingers: Int,
        pinchDist: Double,
        spread: Double = 0.5,
        centroidX: Double = 0.5
    ) -> (HandObservation, HandMetrics) {
        let wrist = Landmark(x: centroidX, y: 0.1)
        let middleMCP = Landmark(x: centroidX, y: 0.3)
        let indexTip = Landmark(x: centroidX, y: 0.5)
        let thumbTip = Landmark(x: centroidX - pinchDist * 0.2, y: 0.5)
        
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
        
        var states: [Finger: FingerState] = [:]
        states[.index] = extendedFingers >= 1 ? .extended : .folded
        states[.middle] = extendedFingers >= 2 ? .extended : .folded
        states[.ring] = extendedFingers >= 3 ? .extended : .folded
        states[.little] = extendedFingers >= 4 ? .extended : .folded
        states[.thumb] = extendedFingers >= 5 ? .extended : .folded
        
        let metrics = HandMetrics(
            timestamp: timestamp,
            extendedFingerCount: extendedFingers,
            fingerStates: states,
            centroid: indexTip,
            spread: spread,
            pinchDistance: pinchDist,
            handScale: 0.2
        )
        
        return (hand, metrics)
    }
    
    func testReplayTwoFingerClick() throws {
        var frames: [RecordedFrame] = []
        
        // Frame 1: 2 fingers open
        let (h1, m1) = createSyntheticHand(timestamp: 1.0, extendedFingers: 2, pinchDist: 0.4)
        frames.append(RecordedFrame(timestamp: 1.0, observation: h1, metrics: m1, gestureState: "TWO_FINGER"))
        
        // Frame 2: Pinched
        let (h2, m2) = createSyntheticHand(timestamp: 1.05, extendedFingers: 2, pinchDist: 0.15)
        frames.append(RecordedFrame(timestamp: 1.05, observation: h2, metrics: m2, gestureState: "PINCH"))
        
        // Frame 3: Released
        let (h3, m3) = createSyntheticHand(timestamp: 1.15, extendedFingers: 2, pinchDist: 0.35)
        frames.append(RecordedFrame(timestamp: 1.15, observation: h3, metrics: m3, gestureState: "RELEASE"))
        
        let recording = GestureRecording(name: "two_finger_click_001", frames: frames)
        
        // Save and reload from disk
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("two_finger_click_001.json")
        try GestureRecorder.save(recording: recording, to: tempURL)
        let loaded = try GestureRecorder.load(from: tempURL)
        
        let sm = GestureStateMachine()
        let replayEngine = GestureReplayEngine()
        let events = replayEngine.replayInstantaneous(recording: loaded, stateMachine: sm)
        
        XCTAssertEqual(events.count, 1)
        if case .leftClick = events.first {
            // Success
        } else {
            XCTFail("Expected leftClick during replay")
        }
    }
    
    func testReplayFourFingerSwipe() throws {
        var frames: [RecordedFrame] = []
        
        for i in 0..<5 {
            let t = 1.0 + Double(i) * 0.03
            let x = 0.30 + Double(i) * 0.04 // Moving right from 0.30 to 0.46
            let (h, m) = createSyntheticHand(timestamp: t, extendedFingers: 4, pinchDist: 0.5, centroidX: x)
            frames.append(RecordedFrame(timestamp: t, observation: h, metrics: m, gestureState: "4F_SWIPE"))
        }
        
        let recording = GestureRecording(name: "four_finger_swipe_right_001", frames: frames)
        let sm = GestureStateMachine()
        let replayEngine = GestureReplayEngine()
        let events = replayEngine.replayInstantaneous(recording: recording, stateMachine: sm)
        
        XCTAssertEqual(events.count, 1)
        if case .switchSpace(let dir) = events.first {
            XCTAssertEqual(dir, .right)
        } else {
            XCTFail("Expected switchSpace(.right)")
        }
    }
    
    func testReplayFiveFingerMissionControl() throws {
        var frames: [RecordedFrame] = []
        
        // 1. Open
        let (h1, m1) = createSyntheticHand(timestamp: 1.0, extendedFingers: 5, pinchDist: 0.5, spread: 0.55)
        frames.append(RecordedFrame(timestamp: 1.0, observation: h1, metrics: m1, gestureState: "OPEN"))
        
        // 2. Contracting
        let (h2, m2) = createSyntheticHand(timestamp: 1.15, extendedFingers: 5, pinchDist: 0.3, spread: 0.35)
        frames.append(RecordedFrame(timestamp: 1.15, observation: h2, metrics: m2, gestureState: "CONTRACT"))
        
        // 3. Pinch lock
        let (h3, m3) = createSyntheticHand(timestamp: 1.25, extendedFingers: 5, pinchDist: 0.15, spread: 0.18)
        frames.append(RecordedFrame(timestamp: 1.25, observation: h3, metrics: m3, gestureState: "LOCKED"))
        
        // 4. Expanding
        let (h4, m4) = createSyntheticHand(timestamp: 1.40, extendedFingers: 5, pinchDist: 0.35, spread: 0.35)
        frames.append(RecordedFrame(timestamp: 1.40, observation: h4, metrics: m4, gestureState: "EXPAND"))
        
        // 5. Open Palm -> Mission Control Trigger
        let (h5, m5) = createSyntheticHand(timestamp: 1.55, extendedFingers: 5, pinchDist: 0.5, spread: 0.52)
        frames.append(RecordedFrame(timestamp: 1.55, observation: h5, metrics: m5, gestureState: "TRIGGER"))
        
        let recording = GestureRecording(name: "five_finger_mission_control_001", frames: frames)
        let sm = GestureStateMachine()
        let replayEngine = GestureReplayEngine()
        let events = replayEngine.replayInstantaneous(recording: recording, stateMachine: sm)
        
        XCTAssertEqual(events.count, 1)
        if case .triggerMissionControl = events.first {
            // Success
        } else {
            XCTFail("Expected triggerMissionControl")
        }
    }
    
    func testExportCanonicalRecordings() throws {
        let recordingsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        
        // 1. Two Finger Click
        var clickFrames: [RecordedFrame] = []
        let (c1, m1) = createSyntheticHand(timestamp: 1.0, extendedFingers: 2, pinchDist: 0.4)
        clickFrames.append(RecordedFrame(timestamp: 1.0, observation: c1, metrics: m1, gestureState: "TWO_FINGER"))
        let (c2, m2) = createSyntheticHand(timestamp: 1.05, extendedFingers: 2, pinchDist: 0.15)
        clickFrames.append(RecordedFrame(timestamp: 1.05, observation: c2, metrics: m2, gestureState: "PINCH"))
        let (c3, m3) = createSyntheticHand(timestamp: 1.15, extendedFingers: 2, pinchDist: 0.35)
        clickFrames.append(RecordedFrame(timestamp: 1.15, observation: c3, metrics: m3, gestureState: "RELEASE"))
        try GestureRecorder.save(recording: GestureRecording(name: "two_finger_click_001", frames: clickFrames), to: recordingsDir.appendingPathComponent("two_finger_click_001.json"))
        
        // 2. Two Finger Drag
        var dragFrames: [RecordedFrame] = []
        let (d1, dm1) = createSyntheticHand(timestamp: 1.0, extendedFingers: 2, pinchDist: 0.4)
        dragFrames.append(RecordedFrame(timestamp: 1.0, observation: d1, metrics: dm1, gestureState: "TWO_FINGER"))
        let (d2, dm2) = createSyntheticHand(timestamp: 1.05, extendedFingers: 2, pinchDist: 0.15)
        dragFrames.append(RecordedFrame(timestamp: 1.05, observation: d2, metrics: dm2, gestureState: "PINCH"))
        let (d3, dm3) = createSyntheticHand(timestamp: 1.45, extendedFingers: 2, pinchDist: 0.15)
        dragFrames.append(RecordedFrame(timestamp: 1.45, observation: d3, metrics: dm3, gestureState: "DRAGGING"))
        let (d4, dm4) = createSyntheticHand(timestamp: 1.80, extendedFingers: 2, pinchDist: 0.38)
        dragFrames.append(RecordedFrame(timestamp: 1.80, observation: d4, metrics: dm4, gestureState: "RELEASE"))
        try GestureRecorder.save(recording: GestureRecording(name: "two_finger_drag_001", frames: dragFrames), to: recordingsDir.appendingPathComponent("two_finger_drag_001.json"))
        
        // 3. Four Finger Swipe Right
        var swipeRightFrames: [RecordedFrame] = []
        for i in 0..<5 {
            let t = 1.0 + Double(i) * 0.03
            let x = 0.30 + Double(i) * 0.04
            let (h, m) = createSyntheticHand(timestamp: t, extendedFingers: 4, pinchDist: 0.5, centroidX: x)
            swipeRightFrames.append(RecordedFrame(timestamp: t, observation: h, metrics: m, gestureState: "4F_SWIPE_RIGHT"))
        }
        try GestureRecorder.save(recording: GestureRecording(name: "four_finger_swipe_right_001", frames: swipeRightFrames), to: recordingsDir.appendingPathComponent("four_finger_swipe_right_001.json"))
        
        // 4. Four Finger Swipe Left
        var swipeLeftFrames: [RecordedFrame] = []
        for i in 0..<5 {
            let t = 1.0 + Double(i) * 0.03
            let x = 0.60 - Double(i) * 0.04
            let (h, m) = createSyntheticHand(timestamp: t, extendedFingers: 4, pinchDist: 0.5, centroidX: x)
            swipeLeftFrames.append(RecordedFrame(timestamp: t, observation: h, metrics: m, gestureState: "4F_SWIPE_LEFT"))
        }
        try GestureRecorder.save(recording: GestureRecording(name: "four_finger_swipe_left_001", frames: swipeLeftFrames), to: recordingsDir.appendingPathComponent("four_finger_swipe_left_001.json"))
        
        // 5. Five Finger Mission Control
        var mcFrames: [RecordedFrame] = []
        let (mcf1, mcm1) = createSyntheticHand(timestamp: 1.0, extendedFingers: 5, pinchDist: 0.5, spread: 0.55)
        mcFrames.append(RecordedFrame(timestamp: 1.0, observation: mcf1, metrics: mcm1, gestureState: "OPEN"))
        let (mcf2, mcm2) = createSyntheticHand(timestamp: 1.15, extendedFingers: 5, pinchDist: 0.3, spread: 0.35)
        mcFrames.append(RecordedFrame(timestamp: 1.15, observation: mcf2, metrics: mcm2, gestureState: "CONTRACT"))
        let (mcf3, mcm3) = createSyntheticHand(timestamp: 1.25, extendedFingers: 5, pinchDist: 0.15, spread: 0.18)
        mcFrames.append(RecordedFrame(timestamp: 1.25, observation: mcf3, metrics: mcm3, gestureState: "LOCKED"))
        let (mcf4, mcm4) = createSyntheticHand(timestamp: 1.40, extendedFingers: 5, pinchDist: 0.35, spread: 0.35)
        mcFrames.append(RecordedFrame(timestamp: 1.40, observation: mcf4, metrics: mcm4, gestureState: "EXPAND"))
        let (mcf5, mcm5) = createSyntheticHand(timestamp: 1.55, extendedFingers: 5, pinchDist: 0.5, spread: 0.52)
        mcFrames.append(RecordedFrame(timestamp: 1.55, observation: mcf5, metrics: mcm5, gestureState: "TRIGGER"))
        try GestureRecorder.save(recording: GestureRecording(name: "five_finger_mission_control_001", frames: mcFrames), to: recordingsDir.appendingPathComponent("five_finger_mission_control_001.json"))
    }
}
