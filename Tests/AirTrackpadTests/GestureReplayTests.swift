import XCTest
@testable import AirTrackpadCore

final class GestureReplayTests: XCTestCase {

    /// `<repo>/recordings`, resolved from this file so it works from any working directory.
    static let recordingsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("recordings", isDirectory: true)

    // MARK: - Canonical recordings

    private struct Step {
        var hand: SyntheticHand
        var frames: Int
        var change: ((inout SyntheticHand, Int) -> Void)?
    }

    /// Builds a deterministic recording (fixed ids, timestamps and date) so the files in
    /// `recordings/` only change when the gesture definitions do.
    private static func makeRecording(_ name: String, _ steps: [Step]) -> GestureRecording {
        var frames: [RecordedFrame] = []
        var t = 1.0
        var index = 0
        for step in steps {
            var hand = step.hand
            for i in 0..<step.frames {
                step.change?(&hand, i)
                let (observation, metrics) = hand.frame(at: t)
                var fixed = observation
                fixed.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
                frames.append(RecordedFrame(timestamp: t, observation: fixed, metrics: metrics, gestureState: name))
                t += 1.0 / 30.0
                index += 1
            }
        }
        return GestureRecording(name: name, recordedAt: Date(timeIntervalSince1970: 1_790_000_000), targetFPS: 30, frames: frames)
    }

    private static var pointing: SyntheticHand { SyntheticHand() }
    private static var pinched: SyntheticHand { var h = SyntheticHand(); h.pinch = 0.08; return h }
    private static func open(_ x: Double) -> SyntheticHand {
        var h = SyntheticHand(); h.fingers = SyntheticHand.openHand; h.palm.x = x; return h
    }
    private static func palm(_ spread: Double) -> SyntheticHand {
        var h = SyntheticHand(); h.fingers = SyntheticHand.openPalm; h.spread = spread; return h
    }

    static let canonical: [(name: String, recording: GestureRecording)] = [
        ("two_finger_click_001", makeRecording("two_finger_click_001", [
            Step(hand: pointing, frames: 8),
            Step(hand: pinched, frames: 4),
            Step(hand: pointing, frames: 4)
        ])),
        ("two_finger_drag_001", makeRecording("two_finger_drag_001", [
            Step(hand: pointing, frames: 8),
            Step(hand: pinched, frames: 4),
            Step(hand: pinched, frames: 12) { h, i in h.palm.x = 0.5 + Double(i + 1) * 0.008 },
            Step(hand: { var h = pointing; h.palm.x = 0.596; return h }(), frames: 4)
        ])),
        ("four_finger_swipe_right_001", makeRecording("four_finger_swipe_right_001", [
            Step(hand: open(0.35), frames: 12),
            Step(hand: open(0.35), frames: 7) { h, i in h.palm.x = 0.35 + Double(i + 1) * 0.03 },
            Step(hand: open(0.56), frames: 6)
        ])),
        ("four_finger_swipe_left_001", makeRecording("four_finger_swipe_left_001", [
            Step(hand: open(0.65), frames: 12),
            Step(hand: open(0.65), frames: 7) { h, i in h.palm.x = 0.65 - Double(i + 1) * 0.03 },
            Step(hand: open(0.44), frames: 6)
        ])),
        ("five_finger_mission_control_001", makeRecording("five_finger_mission_control_001", [
            Step(hand: palm(0.55), frames: 6),
            Step(hand: palm(0.55), frames: 6) { h, i in h.spread = 0.55 - Double(i + 1) * 0.07 },
            Step(hand: palm(0.15), frames: 2),
            Step(hand: palm(0.15), frames: 6) { h, i in h.spread = 0.15 + Double(i + 1) * 0.07 }
        ]))
    ]

    private func expectations(for name: String, _ events: [AbstractGestureEvent], file: StaticString = #filePath, line: UInt = #line) {
        switch name {
        case "two_finger_click_001":
            XCTAssertEqual(events.clicks, [1], file: file, line: line)
        case "two_finger_drag_001":
            XCTAssertEqual(events.count(.leftMouseDown), 1, file: file, line: line)
            XCTAssertEqual(events.count(.leftMouseUp), 1, file: file, line: line)
            XCTAssertGreaterThan(events.pointerTotal.dx, 0, file: file, line: line)
        case "four_finger_swipe_right_001":
            XCTAssertEqual(events.switches, [.right], file: file, line: line)
        case "four_finger_swipe_left_001":
            XCTAssertEqual(events.switches, [.left], file: file, line: line)
        case "five_finger_mission_control_001":
            XCTAssertEqual(events.count(.triggerMissionControl), 1, file: file, line: line)
        default:
            XCTFail("no expectations for \(name)", file: file, line: line)
        }
    }

    // MARK: - Tests

    func testCanonicalRecordingsReplay() {
        for (name, recording) in Self.canonical {
            let events = GestureReplayEngine().replayInstantaneous(recording: recording, stateMachine: GestureStateMachine())
            expectations(for: name, events)
        }
    }

    func testRecordingsSurviveJSONRoundTrip() throws {
        let (name, recording) = Self.canonical[0]
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name)-roundtrip.json")
        try GestureRecorder.save(recording: recording, to: url)
        let loaded = try GestureRecorder.load(from: url)
        let events = GestureReplayEngine().replayInstantaneous(recording: loaded, stateMachine: GestureStateMachine())
        expectations(for: name, events)
    }

    func testRecordingsOnDiskReplay() throws {
        for (name, _) in Self.canonical {
            let url = Self.recordingsDirectory.appendingPathComponent("\(name).json")
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("missing \(url.lastPathComponent); regenerate with AIRTRACKPAD_EXPORT_RECORDINGS=1 swift test")
                continue
            }
            let recording = try GestureRecorder.load(from: url)
            let events = GestureReplayEngine().replayInstantaneous(recording: recording, stateMachine: GestureStateMachine())
            expectations(for: name, events)
        }
    }

    func testReplayThroughRouterDrivesBackend() {
        let backend = MockInputBackend()
        let router = ActionRouter(backend: backend)
        let recording = Self.canonical.first { $0.name == "two_finger_drag_001" }!.recording
        GestureReplayEngine().replayInstantaneous(recording: recording, stateMachine: GestureStateMachine(), actionRouter: router)
        XCTAssertEqual(backend.mouseEvents.filter { $0 == "down" }.count, 1)
        XCTAssertEqual(backend.mouseEvents.filter { $0 == "up" }.count, 1)
        XCTAssertTrue(backend.mouseEvents.contains("drag"))
        XCTAssertFalse(backend.isMouseDown)
    }

    func testLegacyMetricsFormatStillDecodes() throws {
        let json = """
        {"timestamp":1,"extendedFingerCount":1,"fingerStates":{"index":"extended","middle":"folded"},
         "centroid":{"x":0.5,"y":0.5,"z":0,"confidence":1},"spread":0.3,"pinchDistance":0.4,"handScale":0.2}
        """
        let metrics = try JSONDecoder().decode(HandMetrics.self, from: Data(json.utf8))
        XCTAssertEqual(metrics.middlePinchDistance, 1.0)
        XCTAssertEqual(metrics.cursorAnchor, metrics.centroid)
        XCTAssertGreaterThan(metrics.reach(for: .index), metrics.reach(for: .middle))
    }

    /// Regenerates `recordings/*.json`. Opt-in so routine test runs never modify the repo:
    ///     AIRTRACKPAD_EXPORT_RECORDINGS=1 swift test --filter testExportCanonicalRecordings
    func testExportCanonicalRecordings() throws {
        guard ProcessInfo.processInfo.environment["AIRTRACKPAD_EXPORT_RECORDINGS"] == "1" else {
            throw XCTSkip("set AIRTRACKPAD_EXPORT_RECORDINGS=1 to regenerate recordings/")
        }
        try FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
        for (name, recording) in Self.canonical {
            try GestureRecorder.save(recording: recording, to: Self.recordingsDirectory.appendingPathComponent("\(name).json"))
        }
    }
}
