import Foundation
import CoreGraphics

public final class MockInputBackend: InputBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    
    public private(set) var cursorPositions: [CGPoint] = []
    public private(set) var clicks: [CGPoint] = []
    public private(set) var mouseEvents: [String] = []
    public private(set) var spaceSwitches: [SwipeDirection] = []
    public private(set) var missionControlCount: Int = 0
    public private(set) var isMouseDown: Bool = false
    
    public init() {}
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        cursorPositions.removeAll()
        clicks.removeAll()
        mouseEvents.removeAll()
        spaceSwitches.removeAll()
        missionControlCount = 0
        isMouseDown = false
    }
    
    public func moveCursor(to screenPoint: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        cursorPositions.append(screenPoint)
    }
    
    public func mouseClick(at screenPoint: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        clicks.append(screenPoint)
        mouseEvents.append("click")
    }
    
    public func mouseDown(at screenPoint: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        isMouseDown = true
        mouseEvents.append("down")
    }
    
    public func mouseDragged(to screenPoint: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        cursorPositions.append(screenPoint)
        mouseEvents.append("drag")
    }
    
    public func mouseUp(at screenPoint: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        isMouseDown = false
        mouseEvents.append("up")
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
