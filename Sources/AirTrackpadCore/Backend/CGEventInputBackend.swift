import Foundation
import CoreGraphics
import AppKit

public final class CGEventInputBackend: InputBackendProtocol, @unchecked Sendable {
    private let eventSource: CGEventSource? = CGEventSource(stateID: .combinedSessionState)
    private let lock = NSLock()
    private var isButtonDown: Bool = false
    
    public init() {}
    
    public func moveCursor(to screenPoint: CGPoint) {
        CGWarpMouseCursorPosition(screenPoint)
        if let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    public func mouseClick(at screenPoint: CGPoint) {
        CGWarpMouseCursorPosition(screenPoint)
        guard let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ) else { return }
        
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        
        down.post(tap: .cghidEventTap)
        usleep(30_000) // 30ms click duration
        up.post(tap: .cghidEventTap)
    }
    
    public func mouseDown(at screenPoint: CGPoint) {
        lock.lock()
        isButtonDown = true
        lock.unlock()
        
        CGWarpMouseCursorPosition(screenPoint)
        if let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    public func mouseDragged(to screenPoint: CGPoint) {
        CGWarpMouseCursorPosition(screenPoint)
        if let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    public func mouseUp(at screenPoint: CGPoint) {
        lock.lock()
        isButtonDown = false
        lock.unlock()
        
        CGWarpMouseCursorPosition(screenPoint)
        if let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: screenPoint,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
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
                mouseEventSource: eventSource,
                mouseType: .leftMouseUp,
                mouseCursorPosition: currentPos,
                mouseButton: .left
            ) {
                up.post(tap: .cghidEventTap)
            }
        }
    }
    
    private func postKeyCombination(keyCode: UInt16, modifiers: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) else { return }
        
        down.flags = modifiers
        up.flags = []
        
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
    }
}
