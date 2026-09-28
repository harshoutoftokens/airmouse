import Foundation
import CoreGraphics
import AppKit

public final class CGEventInputBackend: InputBackendProtocol, @unchecked Sendable {
    private let eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private var isButtonDown: Bool = false
    private var lastDragPoint: CGPoint = .zero
    
    public init() {}
    
    public func moveCursor(to screenPoint: CGPoint) {
        CGWarpMouseCursorPosition(screenPoint)
        if let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
            event.post(tap: .cgSessionEventTap)
        }
    }
    
    public func mouseClick(at screenPoint: CGPoint) {
        let targetPoint: CGPoint
        if (screenPoint.x <= 1.0 && screenPoint.y <= 1.0), let loc = CGEvent(source: nil)?.location {
            targetPoint = loc
        } else {
            targetPoint = screenPoint
        }
        
        CGWarpMouseCursorPosition(targetPoint)
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: targetPoint,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: targetPoint,
            mouseButton: .left
        ) else { return }
        
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        
        down.post(tap: .cghidEventTap)
        down.post(tap: .cgSessionEventTap)
        usleep(45_000) // 45ms realistic click hold
        up.post(tap: .cghidEventTap)
        up.post(tap: .cgSessionEventTap)
    }
    
    public func mouseDown(at screenPoint: CGPoint) {
        lock.lock()
        isButtonDown = true
        lock.unlock()
        
        let targetPoint: CGPoint
        if (screenPoint.x <= 1.0 && screenPoint.y <= 1.0), let loc = CGEvent(source: nil)?.location {
            targetPoint = loc
        } else {
            targetPoint = screenPoint
        }
        lastDragPoint = targetPoint
        
        CGWarpMouseCursorPosition(targetPoint)
        if let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: targetPoint,
            mouseButton: .left
        ) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
            down.post(tap: .cgSessionEventTap)
        }
    }
    
    public func mouseDragged(to screenPoint: CGPoint) {
        let dx = screenPoint.x - lastDragPoint.x
        let dy = screenPoint.y - lastDragPoint.y
        lastDragPoint = screenPoint
        
        if let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ) {
            event.setDoubleValueField(.mouseEventDeltaX, value: Double(dx))
            event.setDoubleValueField(.mouseEventDeltaY, value: Double(dy))
            event.post(tap: .cghidEventTap)
            event.post(tap: .cgSessionEventTap)
        }
        CGWarpMouseCursorPosition(screenPoint)
    }
    
    public func mouseUp(at screenPoint: CGPoint) {
        lock.lock()
        isButtonDown = false
        lock.unlock()
        
        let targetPoint: CGPoint
        if (screenPoint.x <= 1.0 && screenPoint.y <= 1.0), let loc = CGEvent(source: nil)?.location {
            targetPoint = loc
        } else {
            targetPoint = screenPoint
        }
        
        if let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: targetPoint,
            mouseButton: .left
        ) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
            up.post(tap: .cgSessionEventTap)
        }
        CGWarpMouseCursorPosition(targetPoint)
    }
    
    // MARK: - Native Space Switching (Dock Swipe Gestures)
    
    private static func cgField(_ n: UInt32) -> CGEventField {
        unsafeBitCast(n, to: CGEventField.self)
    }
    
    private static let fieldCGSEventType = cgField(55)
    private static let fieldGestureHIDType = cgField(110)
    private static let fieldSwipeMotion = cgField(123)
    private static let fieldSwipeProgress = cgField(124)
    private static let fieldSwipeVelocityX = cgField(129)
    private static let fieldSwipeVelocityY = cgField(130)
    private static let fieldGesturePhase = cgField(132)
    
    private static let kCGSEventDockControl: Int64 = 30
    private static let kIOHIDEventTypeDockSwipe: Int64 = 23
    private static let kCGGestureMotionHorizontal: Int64 = 1
    
    private enum DockGesturePhase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }
    
    public func switchSpace(direction: SwipeDirection) {
        DispatchQueue.global(qos: .userInteractive).async {
            // macOS Dock swipe sign: -1.0 moves to space on the right, +1.0 moves to space on the left
            let sign: Double = (direction == .right) ? -1.0 : 1.0
            let steps = 8
            let rampMs: Double = 60.0
            let peakProgress: Double = 0.35
            let endVelocity: Double = 130.0
            let perStepUs = UInt32((rampMs / Double(steps)) * 1000.0)
            
            Self.postDockPhase(.began, progress: sign * 1e-4, velocity: sign * 10.0)
            for step in 1...steps {
                let frac = Double(step) / Double(steps)
                Self.postDockPhase(.changed,
                                   progress: sign * peakProgress * frac,
                                   velocity: sign * endVelocity * frac)
                usleep(perStepUs)
            }
            Self.postDockPhase(.ended,
                               progress: sign * peakProgress,
                               velocity: sign * endVelocity)
        }
    }
    
    private static func postDockPhase(_ phase: DockGesturePhase, progress: Double, velocity: Double) {
        guard let ev = CGEvent(source: nil) else { return }
        ev.setIntegerValueField(fieldCGSEventType, value: kCGSEventDockControl)
        ev.setIntegerValueField(fieldGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        ev.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
        ev.setDoubleValueField(fieldSwipeProgress, value: progress)
        ev.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
        ev.setDoubleValueField(fieldSwipeVelocityX, value: velocity)
        ev.setDoubleValueField(fieldSwipeVelocityY, value: velocity)
        ev.post(tap: .cgSessionEventTap)
    }
    
    public func triggerMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    
    public func emergencyRelease() {
        lock.lock()
        let wasDown = isButtonDown
        isButtonDown = false
        lock.unlock()
        
        if wasDown {
            let currentPos = CGEvent(source: nil)?.location ?? .zero
            if let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: currentPos,
                mouseButton: .left
            ) {
                up.post(tap: .cghidEventTap)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }
}
