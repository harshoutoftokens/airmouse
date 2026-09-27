import Foundation
import CoreGraphics

/// Dispatches abstract gesture events to the configured input backend while enforcing safety invariants.
public final class ActionRouter: @unchecked Sendable {
    public let backend: InputBackendProtocol
    private let lock = NSLock()
    private var isDragging: Bool = false
    private var isEnabled: Bool = true
    
    public init(backend: InputBackendProtocol) {
        self.backend = backend
    }
    
    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        if !enabled && isDragging {
            isDragging = false
            backend.emergencyRelease()
        }
        lock.unlock()
    }
    
    public func handle(event: AbstractGestureEvent) {
        lock.lock()
        guard isEnabled else {
            lock.unlock()
            return
        }
        lock.unlock()
        
        switch event {
        case .cursorMoved(let point):
            backend.moveCursor(to: point)
            
        case .leftClick(let point):
            backend.mouseClick(at: point)
            
        case .leftMouseDown(let point):
            lock.lock()
            isDragging = true
            lock.unlock()
            backend.mouseDown(at: point)
            
        case .leftMouseDragged(let point):
            backend.mouseDragged(to: point)
            
        case .leftMouseUp(let point):
            lock.lock()
            isDragging = false
            lock.unlock()
            backend.mouseUp(at: point)
            
        case .switchSpace(let direction):
            backend.switchSpace(direction: direction)
            
        case .triggerMissionControl:
            backend.triggerMissionControl()
            
        case .emergencyStop, .trackingPaused:
            emergencyStop()
            
        case .trackingResumed:
            break
        }
    }
    
    public func emergencyStop() {
        lock.lock()
        let wasDragging = isDragging
        isDragging = false
        lock.unlock()
        
        if wasDragging {
            backend.emergencyRelease()
        }
    }
}
