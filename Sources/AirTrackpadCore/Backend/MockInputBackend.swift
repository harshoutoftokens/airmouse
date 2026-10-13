import Foundation
import CoreGraphics

public final class MockInputBackend: InputBackendProtocol, @unchecked Sendable {
    public struct ScrollRecord: Sendable, Equatable {
        public var deltaX: Double
        public var deltaY: Double
        public var phase: ScrollEventPhase
        public var momentumPhase: ScrollMomentumPhase
    }

    private let lock = NSLock()

    public private(set) var pointer: CGPoint
    public private(set) var cursorPositions: [CGPoint] = []
    public private(set) var clicks: [(point: CGPoint, count: Int)] = []
    public private(set) var mouseEvents: [String] = []
    public private(set) var scrollEvents: [ScrollRecord] = []
    public private(set) var spaceSwitches: [SwipeDirection] = []
    public private(set) var missionControlCount: Int = 0
    public private(set) var isMouseDown: Bool = false

    public init(pointer: CGPoint = CGPoint(x: 500, y: 400)) {
        self.pointer = pointer
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        cursorPositions.removeAll()
        clicks.removeAll()
        mouseEvents.removeAll()
        scrollEvents.removeAll()
        spaceSwitches.removeAll()
        missionControlCount = 0
        isMouseDown = false
    }

    public func currentPointerLocation() -> CGPoint {
        lock.lock()
        defer { lock.unlock() }
        return pointer
    }

    public func moveCursor(to point: CGPoint, delta: CGVector, buttonDown: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pointer = point
        cursorPositions.append(point)
        mouseEvents.append(buttonDown ? "drag" : "move")
    }

    public func mouseDown(at point: CGPoint, clickCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        pointer = point
        isMouseDown = true
        mouseEvents.append("down")
    }

    public func mouseUp(at point: CGPoint, clickCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        pointer = point
        if isMouseDown && mouseEvents.last == "down" {
            clicks.append((point, clickCount))
        }
        isMouseDown = false
        mouseEvents.append("up")
    }

    public func rightClick(at point: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        mouseEvents.append("rightClick")
    }

    public func scroll(deltaX: Double, deltaY: Double, phase: ScrollEventPhase, momentumPhase: ScrollMomentumPhase) {
        lock.lock()
        defer { lock.unlock() }
        scrollEvents.append(ScrollRecord(deltaX: deltaX, deltaY: deltaY, phase: phase, momentumPhase: momentumPhase))
        mouseEvents.append("scroll")
    }

    public func switchSpace(direction: SwipeDirection) {
        lock.lock()
        defer { lock.unlock() }
        spaceSwitches.append(direction)
    }

    public func triggerMissionControl() {
        lock.lock()
        defer { lock.unlock() }
        missionControlCount += 1
    }

    public func emergencyRelease() {
        lock.lock()
        defer { lock.unlock() }
        isMouseDown = false
        mouseEvents.append("emergencyRelease")
    }
}
