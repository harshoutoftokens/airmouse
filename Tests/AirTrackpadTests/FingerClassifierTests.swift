import XCTest
@testable import AirTrackpadCore

final class FingerClassifierTests: XCTestCase {
    
    func testOneFingerExtended() {
        let wrist = Landmark(x: 0.5, y: 0.1)
        let middleMCP = Landmark(x: 0.5, y: 0.35)
        
        let joints: [JointName: Landmark] = [
            .wrist: wrist,
            .middleMCP: middleMCP,
            
            // Index finger: fully extended pointing up
            .indexMCP: Landmark(x: 0.45, y: 0.35),
            .indexPIP: Landmark(x: 0.45, y: 0.50),
            .indexDIP: Landmark(x: 0.45, y: 0.65),
            .indexTip: Landmark(x: 0.45, y: 0.80),
            
            // Middle finger: folded into palm
            .middlePIP: Landmark(x: 0.50, y: 0.42),
            .middleDIP: Landmark(x: 0.50, y: 0.38),
            .middleTip: Landmark(x: 0.50, y: 0.32),
            
            // Ring finger: folded
            .ringMCP: Landmark(x: 0.55, y: 0.35),
            .ringPIP: Landmark(x: 0.55, y: 0.42),
            .ringDIP: Landmark(x: 0.55, y: 0.38),
            .ringTip: Landmark(x: 0.55, y: 0.32),
            
            // Little finger: folded
            .littleMCP: Landmark(x: 0.60, y: 0.33),
            .littlePIP: Landmark(x: 0.60, y: 0.40),
            .littleDIP: Landmark(x: 0.60, y: 0.36),
            .littleTip: Landmark(x: 0.60, y: 0.30),
            
            // Thumb: folded against palm
            .thumbCMC: Landmark(x: 0.42, y: 0.18),
            .thumbMP: Landmark(x: 0.40, y: 0.25),
            .thumbIP: Landmark(x: 0.42, y: 0.30),
            .thumbTip: Landmark(x: 0.44, y: 0.33)
        ]
        
        let hand = HandObservation(
            timestamp: 1.0,
            chirality: .right,
            confidence: 0.95,
            joints: joints
        )
        
        let states = FingerClassifier.classifyFingers(in: hand)
        XCTAssertEqual(states[.index], .extended)
        XCTAssertEqual(states[.middle], .folded)
        XCTAssertEqual(states[.ring], .folded)
        XCTAssertEqual(states[.little], .folded)
        
        let metrics = FingerClassifier.extractMetrics(from: hand)
        XCTAssertEqual(metrics.extendedFingerCount, 1)
    }
}
