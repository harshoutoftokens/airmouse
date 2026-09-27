import XCTest
@testable import AirTrackpadCore

final class GeometryTests: XCTestCase {
    
    func testDistance() {
        let p1 = Landmark(x: 0.0, y: 0.0)
        let p2 = Landmark(x: 3.0, y: 4.0)
        let d = Geometry.distance(p1, p2)
        XCTAssertEqual(d, 5.0, accuracy: 1e-6)
    }
    
    func testCentroid() {
        let points = [
            Landmark(x: 0.0, y: 0.0),
            Landmark(x: 2.0, y: 0.0),
            Landmark(x: 1.0, y: 3.0)
        ]
        let c = Geometry.centroid(of: points)
        XCTAssertEqual(c.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(c.y, 1.0, accuracy: 1e-6)
    }
    
    func testSpread() {
        let palmScale = 0.2
        let points = [
            Landmark(x: 0.4, y: 0.5),
            Landmark(x: 0.6, y: 0.5)
        ]
        let s = Geometry.spread(of: points, palmScale: palmScale)
        XCTAssertEqual(s, 0.5, accuracy: 1e-6)
    }
    
    func testVectorCalculations() {
        let v1 = Vector2D(dx: 1.0, dy: 0.0)
        let v2 = Vector2D(dx: 0.0, dy: 2.0)
        XCTAssertEqual(v1.dot(v2), 0.0, accuracy: 1e-6)
        XCTAssertEqual(v1.cosine(with: v2), 0.0, accuracy: 1e-6)
        
        let v3 = Vector2D(dx: 2.0, dy: 0.0)
        XCTAssertEqual(v1.cosine(with: v3), 1.0, accuracy: 1e-6)
    }
}
