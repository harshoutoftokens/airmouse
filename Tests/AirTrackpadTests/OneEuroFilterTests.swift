import XCTest
@testable import AirTrackpadCore

final class OneEuroFilterTests: XCTestCase {
    
    func testJitterReduction() {
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.007)
        let truePoint = CGPoint(x: 100.0, y: 100.0)
        
        var filteredPoints: [CGPoint] = []
        var t = 0.0
        for i in 0..<30 {
            t += 0.0166
            let noiseX = (Double(i % 3) - 1.0) * 1.5
            let noiseY = (Double((i + 1) % 3) - 1.0) * 1.5
            let noisy = CGPoint(x: truePoint.x + noiseX, y: truePoint.y + noiseY)
            let out = filter.filter(point: noisy, timestamp: t)
            filteredPoints.append(out)
        }
        
        let last = filteredPoints.last!
        let dist = hypot(last.x - truePoint.x, last.y - truePoint.y)
        XCTAssertLessThan(dist, 1.0)
    }
    
    func testStepResponse() {
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.02)
        var t = 0.0
        
        for _ in 0..<10 {
            t += 0.0166
            _ = filter.filter(point: .zero, timestamp: t)
        }
        
        t += 0.0166
        let step = filter.filter(point: CGPoint(x: 500, y: 500), timestamp: t)
        
        XCTAssertGreaterThan(step.x, 150.0)
        XCTAssertGreaterThan(step.y, 150.0)
    }
}
