import XCTest
@testable import AirTrackpadCore

final class ScreenMapperTests: XCTestCase {
    
    func testCenterMapping() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let mapper = ScreenMapper(minX: 0.1, maxX: 0.9, minY: 0.1, maxY: 0.9, screenBounds: bounds)
        
        // Exact center in camera space (0.5, 0.5) should map to center of screen (500, 500)
        let mapped = mapper.mapToScreen(normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertEqual(mapped.x, 500.0, accuracy: 1e-4)
        XCTAssertEqual(mapped.y, 500.0, accuracy: 1e-4)
    }
    
    func testBoundaryClamping() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let mapper = ScreenMapper(minX: 0.2, maxX: 0.8, minY: 0.2, maxY: 0.8, screenBounds: bounds)
        
        // Landmark at left margin (0.2) should map to 0.0 (left edge)
        let leftEdge = mapper.mapToScreen(normalizedX: 0.2, normalizedY: 0.5)
        XCTAssertEqual(leftEdge.x, 0.0, accuracy: 1e-4)
        
        // Landmark beyond right margin (0.95) should clamp to 1000.0 (right edge)
        let rightEdge = mapper.mapToScreen(normalizedX: 0.95, normalizedY: 0.5)
        XCTAssertEqual(rightEdge.x, 1000.0, accuracy: 1e-4)
    }
}
