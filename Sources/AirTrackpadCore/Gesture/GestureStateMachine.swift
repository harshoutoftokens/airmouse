import Foundation
import CoreGraphics

public enum GestureState: String, Sendable, Codable {
    case idle = "IDLE"
    case oneFingerCursor = "☝ ONE_FINGER_CURSOR"
    case twoFingerDetected = "☝☝ TWO_FINGER_PAUSED"
    case pinchCandidate = "🤏 PINCH_CANDIDATE"
    case dragging = "✊ DRAGGING"
    case fourFingerCandidate = "🖐 FOUR_FINGER_CANDIDATE"
    case fiveFingerOpen = "🖐 FIVE_FINGER_OPEN"
    case fiveFingerContracting = "🤏 FIVE_FINGER_CONTRACTING"
    case fiveFingerPinchLocked = "🔒 FIVE_FINGER_ARMED"
    case fiveFingerExpanding = "🖐 FIVE_FINGER_EXPANDING"
    case cooldown = "⏱ COOLDOWN"
}

/// Formal temporal gesture state machine coordinating gestures, priorities, and hysteresis.
public final class GestureStateMachine: @unchecked Sendable {
    public private(set) var currentState: GestureState = .idle
    
    // Configuration parameters
    public var pinchStartThreshold: Double = 0.22
    public var pinchReleaseThreshold: Double = 0.30
    public var clickMaxDuration: TimeInterval = 0.35
    public var dragHoldDelay: TimeInterval = 0.35
    public var clickCooldownDuration: TimeInterval = 0.25
    
    // Timers & internal tracking
    private var pinchStartTime: TimeInterval?
    private var cooldownUntil: TimeInterval = 0.0
    private var isDraggingActive: Bool = false
    private var currentCursorPosition: CGPoint = .zero
    private var dragAnchorPosition: CGPoint?
    
    private let lock = NSLock()
    
    public init() {}
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentState = .idle
        pinchStartTime = nil
        isDraggingActive = false
        dragAnchorPosition = nil
    }
    
    public func updateCursorPosition(_ point: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        self.currentCursorPosition = point
    }
    
    /// Processes a single frame of hand observation and metrics, returning any emitted abstract events.
    public func process(
        hand: HandObservation?,
        metrics: HandMetrics?,
        timestamp: TimeInterval
    ) -> [AbstractGestureEvent] {
        lock.lock()
        defer { lock.unlock() }
        
        var emittedEvents: [AbstractGestureEvent] = []
        
        // 1. Hand Lost Watchdog: If hand disappeared, immediately release mouse if held
        guard let hand = hand, let metrics = metrics else {
            if isDraggingActive {
                isDraggingActive = false
                emittedEvents.append(.leftMouseUp(at: currentCursorPosition))
            }
            currentState = .idle
            pinchStartTime = nil
            return emittedEvents
        }
        
        // 2. Global Cooldown Check
        if timestamp < cooldownUntil {
            return emittedEvents
        }
        
        let extCount = metrics.extendedFingerCount
        let pinchDist = metrics.pinchDistance
        
        // 3. Priority Evaluation: Multi-touch preempts 1-finger cursor immediately
        if extCount >= 2 && currentState == .oneFingerCursor {
            currentState = .twoFingerDetected
        }
        
        switch currentState {
        case .idle:
            if extCount == 1 && metrics.state(for: .index) == .extended {
                currentState = .oneFingerCursor
            } else if extCount == 2 {
                currentState = .twoFingerDetected
            }
            
        case .oneFingerCursor:
            if extCount != 1 || metrics.state(for: .index) != .extended {
                if extCount == 2 {
                    currentState = .twoFingerDetected
                } else {
                    currentState = .idle
                }
            }
            // Cursor movement is handled by CursorEngine in 1-finger mode
            
        case .twoFingerDetected:
            if extCount < 2 {
                currentState = .idle
            } else if pinchDist < pinchStartThreshold {
                currentState = .pinchCandidate
                pinchStartTime = timestamp
            }
            
        case .pinchCandidate:
            guard let startTime = pinchStartTime else {
                currentState = .twoFingerDetected
                break
            }
            let duration = timestamp - startTime
            
            // Check if released quickly -> Click!
            if pinchDist > pinchReleaseThreshold {
                if duration <= clickMaxDuration {
                    emittedEvents.append(.leftClick(at: currentCursorPosition))
                    cooldownUntil = timestamp + clickCooldownDuration
                    currentState = .cooldown
                } else {
                    currentState = .twoFingerDetected
                }
                pinchStartTime = nil
            } else if duration >= dragHoldDelay && !isDraggingActive {
                // Sustained pinch -> Dragging Mode!
                isDraggingActive = true
                currentState = .dragging
                emittedEvents.append(.leftMouseDown(at: currentCursorPosition))
                if let indexTip = hand.landmark(.indexTip) {
                    dragAnchorPosition = indexTip.point
                }
            }
            
        case .dragging:
            // Release pinch or hand opened -> Mouse Up!
            if pinchDist > pinchReleaseThreshold || extCount < 1 {
                isDraggingActive = false
                currentState = .cooldown
                cooldownUntil = timestamp + 0.15
                emittedEvents.append(.leftMouseUp(at: currentCursorPosition))
                dragAnchorPosition = nil
            } else {
                // Drag displacement: while pinched, hand motion moves dragged cursor
                if let indexTip = hand.landmark(.indexTip) {
                    if let anchor = dragAnchorPosition {
                        let dx = (indexTip.x - anchor.x) * 1500.0 // screen scale factor
                        let dy = (anchor.y - indexTip.y) * 1000.0
                        let newPos = CGPoint(
                            x: currentCursorPosition.x + dx,
                            y: currentCursorPosition.y + dy
                        )
                        emittedEvents.append(.leftMouseDragged(to: newPos))
                    }
                    dragAnchorPosition = indexTip.point
                }
            }
            
        case .cooldown:
            if timestamp >= cooldownUntil {
                currentState = .idle
            }
            
        default:
            currentState = .idle
        }
        
        return emittedEvents
    }
    
    /// Emergency fail-safe release
    public func emergencyRelease() -> [AbstractGestureEvent] {
        lock.lock()
        defer { lock.unlock() }
        var events: [AbstractGestureEvent] = []
        if isDraggingActive {
            isDraggingActive = false
            events.append(.leftMouseUp(at: currentCursorPosition))
        }
        currentState = .idle
        pinchStartTime = nil
        return events
    }
}
