import XCTest
@testable import AirTrackpadCore

final class PinchDetectorTests: XCTestCase {
    private func feed(_ detector: inout PinchDetector, _ values: [Double], reach: Double = 0.7, start: TimeInterval = 1.0) -> [PinchTransition] {
        values.enumerated().map { i, d in
            detector.update(distance: d, fingerReach: reach, timestamp: start + Double(i) / 30.0)
        }
    }

    func testPressAndReleaseWithHysteresis() {
        var p = PinchDetector(pressThreshold: 0.22, releaseThreshold: 0.32)
        let transitions = feed(&p, [0.6, 0.6, 0.1, 0.1, 0.1, 0.27, 0.27, 0.27, 0.6, 0.6])
        XCTAssertEqual(transitions.filter { $0 == .pressed }.count, 1)
        XCTAssertEqual(transitions.filter { $0 == .released }.count, 1)
        // 0.27 sits between the thresholds: still pinched
        XCTAssertLessThan(transitions.firstIndex(of: .pressed)!, 5)
        XCTAssertGreaterThan(transitions.firstIndex(of: .released)!, 7)
    }

    func testNoiseAroundThresholdDoesNotChatter() {
        var p = PinchDetector()
        _ = feed(&p, [0.6, 0.6])
        let noisy = (0..<60).map { 0.22 + 0.04 * sin(Double($0) * 2.9) } // ±0.04 around the press level
        let transitions = feed(&p, noisy, start: 2.0)
        XCTAssertLessThanOrEqual(transitions.filter { $0 == .pressed }.count, 1)
        XCTAssertEqual(transitions.filter { $0 == .released }.count, 0)
    }

    func testRequiresOpenBeforeFirstPress() {
        var p = PinchDetector()
        let transitions = feed(&p, Array(repeating: 0.08, count: 10))
        XCTAssertFalse(transitions.contains(.pressed))
    }

    func testCurledFingerCannotPress() {
        var p = PinchDetector()
        let transitions = feed(&p, [0.6, 0.6, 0.1, 0.1, 0.1, 0.1], reach: 0.25)
        XCTAssertFalse(transitions.contains(.pressed))
    }

    func testProgressRisesAsFingersClose() {
        var p = PinchDetector()
        _ = feed(&p, [0.6, 0.6, 0.6])
        let open = p.progress
        _ = feed(&p, [0.3, 0.3, 0.3], start: 2.0)
        XCTAssertGreaterThan(p.progress, open)
        XCTAssertGreaterThan(p.closingSpeed, -0.01)
    }
}

final class PoseClassifierTests: XCTestCase {
    private func metrics(_ states: [Finger: FingerState], reach: [Finger: Double]? = nil) -> HandMetrics {
        HandMetrics(timestamp: 0, extendedFingerCount: states.values.filter { $0 == .extended }.count,
                    fingerStates: states, centroid: Landmark(x: 0.5, y: 0.5), spread: 0.3,
                    pinchDistance: 0.6, handScale: 0.15, fingerReach: reach)
    }

    func testPointing() {
        let m = metrics([.thumb: .folded, .index: .extended, .middle: .folded, .ring: .folded, .little: .folded])
        XCTAssertEqual(PoseClassifier.classify(m), .pointing)
    }

    func testRelaxedHalfCurledMiddleIsStillPointing() {
        let m = metrics(
            [.thumb: .folded, .index: .extended, .middle: .partiallyExtended, .ring: .folded, .little: .folded],
            reach: [.thumb: 0.4, .index: 0.8, .middle: 0.55, .ring: 0.3, .little: 0.3]
        )
        XCTAssertEqual(PoseClassifier.classify(m), .pointing, "a loosely curled middle finger must not flip pointing into scrolling")
    }

    func testScroll() {
        let m = metrics([.thumb: .folded, .index: .extended, .middle: .extended, .ring: .folded, .little: .folded])
        XCTAssertEqual(PoseClassifier.classify(m), .scroll)
    }

    func testOpenHand() {
        let m = metrics([.thumb: .extended, .index: .extended, .middle: .extended, .ring: .extended, .little: .partiallyExtended])
        XCTAssertEqual(PoseClassifier.classify(m), .openHand)
    }

    func testFist() {
        let m = metrics([.thumb: .folded, .index: .folded, .middle: .folded, .ring: .folded, .little: .folded])
        XCTAssertEqual(PoseClassifier.classify(m), .fist)
    }

    func testStabilizerNeedsConsecutiveFrames() {
        var s = PoseStabilizer()
        s.update(.pointing)
        s.update(.pointing)
        XCTAssertEqual(s.stable, .pointing)
        s.update(.scroll)
        s.update(.scroll)
        XCTAssertEqual(s.stable, .pointing, "pointing → scroll needs three frames")
        s.update(.scroll)
        XCTAssertEqual(s.stable, .scroll)
        s.update(.pointing)
        s.update(.scroll)
        XCTAssertEqual(s.stable, .scroll, "a single odd frame is ignored")
    }
}

final class DesktopSwipeTrackerTests: XCTestCase {
    private func run(_ d: inout DesktopSwipeTracker, xs: [Double], start: Double = 0) -> [DesktopSwipeUpdate] {
        var out: [DesktopSwipeUpdate] = []
        for (i, x) in xs.enumerated() {
            out += d.update(pose: .openHand, point: Landmark(x: x, y: 0.4), scale: 0.15, timestamp: start + Double(i) / 30.0)
        }
        return out
    }

    func testProgressIsPalmTravelOverFullDistance() {
        var d = DesktopSwipeTracker()
        let xs = Array(repeating: 0.4, count: 4) + (1...10).map { 0.4 + Double($0) * 0.006 }
        let updates = run(&d, xs: xs)
        XCTAssertEqual(updates.first, .began)
        guard case .changed(let p) = updates.last else { return XCTFail("no progress") }
        XCTAssertEqual(p, 0.06 / 0.15 / 1.5, accuracy: 0.01)
    }

    func testReleaseDecision() {
        var d = DesktopSwipeTracker()
        _ = run(&d, xs: Array(repeating: 0.4, count: 4) + (1...30).map { 0.4 + Double($0) * 0.006 })
        XCTAssertEqual(d.finish(at: 2, reason: "test"), .ended(progress: d.lastSummary?.progress ?? 0, commit: true))
        XCTAssertGreaterThan(d.lastSummary?.progress ?? 0, 0.5)
    }

    func testNeverReleasesAtZeroProgressAsACommit() {
        var d = DesktopSwipeTracker()
        _ = run(&d, xs: Array(repeating: 0.4, count: 4) + (1...6).map { 0.4 + Double($0) * 0.006 })
        guard case .ended(_, let commit) = d.finish(at: 1, reason: "test") else { return XCTFail() }
        XCTAssertFalse(commit)
    }
}

final class FiveFingerDetectorTests: XCTestCase {
    func testPointingAbandonsSequence() {
        var d = FiveFingerDetector()
        _ = d.update(pose: .openHand, thumbUp: true, spread: 0.55, timestamp: 0.0)
        _ = d.update(pose: .openHand, thumbUp: true, spread: 0.55, timestamp: 0.03)
        XCTAssertEqual(d.phase, .open)
        _ = d.update(pose: .pointing, thumbUp: false, spread: 0.30, timestamp: 0.06)
        XCTAssertEqual(d.phase, .idle)
        XCTAssertFalse(d.isGathering)
    }

    func testSlowSequenceTimesOut() {
        var d = FiveFingerDetector()
        var t = 0.0
        func step(_ pose: HandPose, _ spread: Double) -> Bool {
            defer { t += 1.0 / 30.0 }
            return d.update(pose: pose, thumbUp: true, spread: spread, timestamp: t)
        }
        for _ in 0..<4 { _ = step(.openHand, 0.55) }
        XCTAssertEqual(d.phase, .open)
        for _ in 0..<8 { _ = step(.other, 0.12) }
        XCTAssertEqual(d.phase, .armed)
        t += 2.0 // fingers held together for two seconds
        XCTAssertFalse(step(.other, 0.55), "a sequence that took seconds is not a gesture")
        XCTAssertEqual(d.phase, .idle)
    }
}
