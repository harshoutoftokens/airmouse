import XCTest
@testable import AirTrackpadCore

final class FingerClassifierTests: XCTestCase {

    /// A right hand seen by the (mirrored) camera, palm facing it, fingers pointing up.
    private func hand(
        indexTip: Landmark = Landmark(x: 0.45, y: 0.80),
        middleTip: Landmark = Landmark(x: 0.50, y: 0.32),
        middlePIP: Landmark = Landmark(x: 0.50, y: 0.42),
        middleDIP: Landmark = Landmark(x: 0.50, y: 0.38),
        thumbTip: Landmark = Landmark(x: 0.44, y: 0.33)
    ) -> HandObservation {
        HandObservation(timestamp: 1.0, chirality: .right, confidence: 0.95, joints: [
            .wrist: Landmark(x: 0.5, y: 0.1),
            .middleMCP: Landmark(x: 0.5, y: 0.35),
            .indexMCP: Landmark(x: 0.45, y: 0.35),
            .indexPIP: Landmark(x: 0.45, y: 0.50),
            .indexDIP: Landmark(x: 0.45, y: 0.65),
            .indexTip: indexTip,
            .middlePIP: middlePIP,
            .middleDIP: middleDIP,
            .middleTip: middleTip,
            .ringMCP: Landmark(x: 0.55, y: 0.35),
            .ringPIP: Landmark(x: 0.55, y: 0.42),
            .ringDIP: Landmark(x: 0.55, y: 0.38),
            .ringTip: Landmark(x: 0.55, y: 0.32),
            .littleMCP: Landmark(x: 0.60, y: 0.33),
            .littlePIP: Landmark(x: 0.60, y: 0.40),
            .littleDIP: Landmark(x: 0.60, y: 0.36),
            .littleTip: Landmark(x: 0.60, y: 0.30),
            .thumbCMC: Landmark(x: 0.42, y: 0.18),
            .thumbMP: Landmark(x: 0.40, y: 0.25),
            .thumbIP: Landmark(x: 0.42, y: 0.30),
            .thumbTip: thumbTip
        ])
    }

    func testOneFingerExtended() {
        let h = hand()
        let states = FingerClassifier.classifyFingers(in: h)
        XCTAssertEqual(states[.index], .extended)
        XCTAssertEqual(states[.middle], .folded)
        XCTAssertEqual(states[.ring], .folded)
        XCTAssertEqual(states[.little], .folded)

        let metrics = FingerClassifier.extractMetrics(from: h)
        XCTAssertEqual(metrics.extendedFingerCount, 1)
        XCTAssertEqual(PoseClassifier.classify(metrics), .pointing)
    }

    func testTwoFingersSideBySideAreNotAPinch() {
        // ✌ with index and middle held together; thumb tucked low.
        let h = hand(
            indexTip: Landmark(x: 0.47, y: 0.80),
            middleTip: Landmark(x: 0.50, y: 0.82),
            middlePIP: Landmark(x: 0.50, y: 0.52),
            middleDIP: Landmark(x: 0.50, y: 0.67),
            thumbTip: Landmark(x: 0.46, y: 0.30)
        )
        let metrics = FingerClassifier.extractMetrics(from: h)
        XCTAssertEqual(PoseClassifier.classify(metrics), .scroll)
        XCTAssertGreaterThan(metrics.pinchDistance, 0.6, "index↔middle proximity must not count as a pinch")
    }

    func testThumbTouchingIndexIsAPinch() {
        let h = hand(indexTip: Landmark(x: 0.44, y: 0.60), thumbTip: Landmark(x: 0.445, y: 0.59))
        let metrics = FingerClassifier.extractMetrics(from: h)
        XCTAssertLessThan(metrics.pinchDistance, 0.1)
    }

    func testCursorAnchorBarelyMovesWhenFingertipCurls() {
        let pointing = FingerClassifier.extractMetrics(from: hand())
        let pinching = FingerClassifier.extractMetrics(from: hand(indexTip: Landmark(x: 0.44, y: 0.60), thumbTip: Landmark(x: 0.445, y: 0.59)))
        let anchorShift = Geometry.distance(pointing.cursorAnchor, pinching.cursorAnchor)
        let tipShift = 0.2
        XCTAssertLessThan(anchorShift, tipShift * 0.05, "pinching must not drag the pointer")
    }

    func testRobustScaleSurvivesPalmTilt() {
        // Palm tilted back: projected wrist→knuckle length shrinks, knuckle width doesn't.
        var joints: [JointName: Landmark] = [
            .wrist: Landmark(x: 0.5, y: 0.25),
            .middleMCP: Landmark(x: 0.5, y: 0.35),
            .indexMCP: Landmark(x: 0.43, y: 0.35),
            .littleMCP: Landmark(x: 0.58, y: 0.34)
        ]
        let tilted = HandObservation(timestamp: 0, chirality: .right, confidence: 1, joints: joints)
        joints[.wrist] = Landmark(x: 0.5, y: 0.13)
        let upright = HandObservation(timestamp: 0, chirality: .right, confidence: 1, joints: joints)
        XCTAssertLessThan(tilted.palmScale, upright.palmScale * 0.6)
        XCTAssertEqual(tilted.robustScale, upright.robustScale, accuracy: upright.robustScale * 0.25)
    }
}
