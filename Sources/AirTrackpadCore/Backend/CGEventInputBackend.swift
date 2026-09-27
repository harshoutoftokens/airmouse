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
    
    public func switchSpace(direction: SwipeDirection) {
        // Virtual key codes: Left Arrow = 0x7B, Right Arrow = 0x7C
        let keyCode: UInt16 = (direction == .right) ? 0x7C : 0x7B
        postKeyCombination(keyCode: keyCode, modifiers: .maskControl)
    }
    
    public func triggerMissionControl() {
        // Virtual key code: Up Arrow = 0x7E with Control modifier
        postKeyCombination(keyCode: 0x7E, modifiers: .maskControl)
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
    
    private func postKeyCombination(keyCode: UInt16, modifiers: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        
        down.flags = modifiers
        up.flags = []
        
        down.post(tap: .cghidEventTap)
        down.post(tap: .cgSessionEventTap)
        usleep(35_000)
        up.post(tap: .cghidEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
