import XCTest
@testable import AirTrackpadCore

final class CursorEngineTests: XCTestCase {

    private func run(_ engine: CursorEngine, xs: [Double], y: Double = 0.4, scale: Double = 0.15, start: TimeInterval = 1.0) -> [CursorEngine.Sample] {
        xs.enumerated().map { i, x in
            engine.update(anchor: Landmark(x: x, y: y), scale: scale, timestamp: start + Double(i) / 30.0)
        }
    }

    func testRelativeMotionFollowsHandDirection() {
        let engine = CursorEngine()
        let samples = run(engine, xs: (0..<20).map { 0.4 + Double($0) * 0.006 })
        let total = samples.reduce(0.0) { $0 + Double($1.delta.dx) }
        XCTAssertGreaterThan(total, 30)
    }

    func testRelativeMotionIsDistanceInvariant() {
        // The same physical motion seen from twice as far: half the image displacement and
        // half the hand size. Pointer travel should match.
        let near = CursorEngine()
        let far = CursorEngine()
        let nearTotal = run(near, xs: (0..<20).map { 0.4 + Double($0) * 0.008 }, scale: 0.20)
            .reduce(0.0) { $0 + Double($1.delta.dx) }
        let farTotal = run(far, xs: (0..<20).map { 0.4 + Double($0) * 0.004 }, scale: 0.10)
            .reduce(0.0) { $0 + Double($1.delta.dx) }
        XCTAssertEqual(nearTotal, farTotal, accuracy: nearTotal * 0.08)
    }

    func testRestingHandProducesNoMotion() {
        let engine = CursorEngine()
        let samples = run(engine, xs: (0..<60).map { 0.5 + 0.001 * sin(Double($0) * 2.3) })
        let total = samples.reduce(0.0) { $0 + hypot(Double($1.delta.dx), Double($1.delta.dy)) }
        XCTAssertLessThan(total, 3)
    }

    func testGainMultiplierScalesMotion() {
        let a = CursorEngine()
        let b = CursorEngine()
        var totalA = 0.0, totalB = 0.0
        for i in 0..<20 {
            let t = 1.0 + Double(i) / 30.0
            let anchor = Landmark(x: 0.4 + Double(i) * 0.006, y: 0.4)
            totalA += Double(a.update(anchor: anchor, scale: 0.15, timestamp: t).delta.dx)
            totalB += Double(b.update(anchor: anchor, scale: 0.15, timestamp: t, gainMultiplier: 0.5).delta.dx)
        }
        XCTAssertEqual(totalB, totalA * 0.5, accuracy: totalA * 0.02)
    }

    func testAccelerationCurve() {
        let accel = PointerAcceleration(speed: 1.0, acceleration: 0.7)
        XCTAssertLessThan(accel.gain(forSpeed: 0.2), accel.gain(forSpeed: 2.0))
        XCTAssertLessThan(accel.gain(forSpeed: 2.0), accel.gain(forSpeed: 6.0))
        XCTAssertEqual(accel.gain(forSpeed: 6.0), accel.gain(forSpeed: 20.0), accuracy: 1e-9, "saturates")
        let linear = PointerAcceleration(speed: 1.0, acceleration: 0.0)
        XCTAssertEqual(linear.gain(forSpeed: 0.2), linear.gain(forSpeed: 6.0), accuracy: 1e-9)
    }

    func testAbsoluteModeMapsCalibrationBoxToDisplay() {
        let mapper = ScreenMapper(minX: 0.2, maxX: 0.8, minY: 0.2, maxY: 0.8, screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let engine = CursorEngine(mapper: mapper)
        engine.mode = .absolute
        var last: CGPoint?
        for i in 0..<30 {
            last = engine.update(anchor: Landmark(x: 0.5, y: 0.5), scale: 0.15, timestamp: 1.0 + Double(i) / 30.0).target
        }
        XCTAssertEqual(Double(last?.x ?? 0), 500, accuracy: 3)
        XCTAssertEqual(Double(last?.y ?? 0), 500, accuracy: 3)
    }

    func testAbsoluteModeLeashHoldsStillThroughJitter() {
        let mapper = ScreenMapper(minX: 0.2, maxX: 0.8, minY: 0.2, maxY: 0.8, screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let engine = CursorEngine(mapper: mapper)
        engine.mode = .absolute
        var targets: [CGPoint] = []
        for i in 0..<60 {
            let jitter = 0.0006 * sin(Double(i) * 2.7)
            if let p = engine.update(anchor: Landmark(x: 0.5 + jitter, y: 0.5), scale: 0.15, timestamp: 1.0 + Double(i) / 30.0, leashBoost: 6).target {
                targets.append(p)
            }
        }
        let settled = targets.suffix(30)
        let xs = settled.map { Double($0.x) }
        XCTAssertLessThan((xs.max() ?? 0) - (xs.min() ?? 0), 1.0)
    }

    func testEmittedMotionHistory() {
        let engine = CursorEngine()
        engine.recordEmitted(CGVector(dx: 5, dy: 1), at: 1.0)
        engine.recordEmitted(CGVector(dx: 3, dy: 0), at: 1.1)
        engine.recordEmitted(CGVector(dx: 2, dy: -1), at: 1.2)
        let since = engine.emittedMotion(since: 1.05)
        XCTAssertEqual(Double(since.dx), 5, accuracy: 1e-9)
        XCTAssertEqual(Double(since.dy), -1, accuracy: 1e-9)
    }
}
