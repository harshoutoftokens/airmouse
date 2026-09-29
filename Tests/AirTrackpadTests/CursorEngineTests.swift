import XCTest
@testable import AirTrackpadCore

final class CursorEngineTests: XCTestCase {
    
    func testDeadzoneSuppressesMicroTremors() {
        let mapper = ScreenMapper(screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let engine = CursorEngine(mapper: mapper, deadZonePixels: 2.0)
        
        // Initial point
        let p0 = Landmark(x: 0.5, y: 0.5)
        let event0 = engine.process(indexTip: p0, timestamp: 1.0)
        XCTAssertNotNil(event0)
        
        // Sub-pixel tremor: negligible movement
        let p1 = Landmark(x: 0.5001, y: 0.5001)
        let event1 = engine.process(indexTip: p1, timestamp: 1.016)
        // Movement is below 2.0 pixel deadzone threshold, so nil is returned (suppressed)
        XCTAssertNil(event1)
    }
    
    func testMovementBeyondDeadzoneDispatchesCursorEvent() {
        let mapper = ScreenMapper(screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let engine = CursorEngine(mapper: mapper, deadZonePixels: 2.0)
        
        _ = engine.process(indexTip: Landmark(x: 0.5, y: 0.5), timestamp: 1.0)
        
        // Significant movement: 0.5 -> 0.55 in camera space is ~70px on screen
        let p2 = Landmark(x: 0.55, y: 0.5)
        let event2 = engine.process(indexTip: p2, timestamp: 1.033)
        XCTAssertNotNil(event2)
        
        if case .cursorMoved(let pt) = event2 {
            XCTAssertGreaterThan(pt.x, 500.0)
        } else {
            XCTFail("Expected cursorMoved event")
        }
    }
    
    func testSpeedMultiplierScalesDisplacement() {
        let mapper = ScreenMapper(screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let engineNormal = CursorEngine(mapper: mapper, deadZonePixels: 0.0)
        let engineSlow = CursorEngine(mapper: mapper, deadZonePixels: 0.0)
        
        let p0 = Landmark(x: 0.5, y: 0.5)
        let p1 = Landmark(x: 0.55, y: 0.5)
        
        guard case .cursorMoved(let normal0) = engineNormal.process(trackingPoint: p0, timestamp: 1.0, speedMultiplier: 1.0),
              case .cursorMoved(let normal1) = engineNormal.process(trackingPoint: p1, timestamp: 1.016, speedMultiplier: 1.0),
              case .cursorMoved(let slow0) = engineSlow.process(trackingPoint: p0, timestamp: 1.0, speedMultiplier: 0.5),
              case .cursorMoved(let slow1) = engineSlow.process(trackingPoint: p1, timestamp: 1.016, speedMultiplier: 0.5) else {
            XCTFail("Expected cursor move events")
            return
        }
        
        let normalDx = normal1.x - normal0.x
        let slowDx = slow1.x - slow0.x
        
        XCTAssertEqual(slowDx, normalDx * 0.5, accuracy: 0.1)
    }
}
