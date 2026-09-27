import Foundation
import CoreGraphics

public enum GestureState: String, Sendable, Codable {
    case idle = "IDLE"
    case oneFingerCursor = "☝ ONE_FINGER_CURSOR"
    case twoFingerDetected = "☝☝ TWO_FINGER_PAUSED"
    case pinchCandidate = "🤏 PINCH_CANDIDATE"
    case dragging = "✊ DRAGGING"
    case fourFingerCandidate = "🖐 FOUR_FINGER_SWIPE_CANDIDATE"
    case fiveFingerOpen = "🖐 FIVE_FINGER_OPEN"
    case fiveFingerContracting = "🤏 FIVE_FINGER_CONTRACTING"
    case fiveFingerPinchLocked = "🔒 FIVE_FINGER_ARMED"
    case fiveFingerExpanding = "🖐 FIVE_FINGER_EXPANDING"
    case cooldown = "⏱ COOLDOWN"
}

private struct CentroidSample {
    let point: Landmark
    let timestamp: TimeInterval
}

/// Formal temporal gesture state machine coordinating all 5 core gestures, priorities, and kinematics.
public final class GestureStateMachine: @unchecked Sendable {
    public private(set) var currentState: GestureState = .idle
    
    // 2-Finger Pinch / Drag parameters
    public var pinchStartThreshold: Double = 0.22
    public var pinchReleaseThreshold: Double = 0.30
    public var clickMaxDuration: TimeInterval = 0.35
    public var dragHoldDelay: TimeInterval = 0.35
    public var clickCooldownDuration: TimeInterval = 0.25
    
    // 4-Finger Fast Swipe parameters
    public var swipeMinDisplacement: Double = 0.10
    public var swipeMinVelocity: Double = 0.45
    public var swipeMaxDuration: TimeInterval = 0.35
    public var swipeDirectionRatio: Double = 2.0
    public var swipeCooldownDuration: TimeInterval = 0.50
    
    // 5-Finger Mission Control parameters
    public var fiveFingerOpenThreshold: Double = 0.48
    public var fiveFingerPinchThreshold: Double = 0.22
    public var fiveFingerMaxSequenceDuration: TimeInterval = 1.20
    public var fiveFingerMinSequenceDuration: TimeInterval = 0.25
    public var missionControlCooldownDuration: TimeInterval = 0.60
    
    // Timers & internal tracking
    private var pinchStartTime: TimeInterval?
    private var cooldownUntil: TimeInterval = 0.0
    private var isDraggingActive: Bool = false
    private var currentCursorPosition: CGPoint = .zero
    private var dragAnchorPosition: CGPoint?
    
    // Swipe kinematic buffer
    private var centroidHistory: [CentroidSample] = []
    
    // 5-finger temporal state tracking
    private var fiveFingerSequenceStartTime: TimeInterval?
    private var previousSpread: Double = 0.0
    
    private let lock = NSLock()
    
    public init() {}
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentState = .idle
        pinchStartTime = nil
        isDraggingActive = false
        dragAnchorPosition = nil
        centroidHistory.removeAll()
        fiveFingerSequenceStartTime = nil
        previousSpread = 0.0
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
            centroidHistory.removeAll()
            fiveFingerSequenceStartTime = nil
            return emittedEvents
        }
        
        // 2. Global Cooldown Check
        if timestamp < cooldownUntil {
            return emittedEvents
        }
        
        let extCount = metrics.extendedFingerCount
        let pinchDist = metrics.pinchDistance
        let spread = metrics.spread
        
        // Record centroid history for swipe detection (window = 350ms)
        centroidHistory.append(CentroidSample(point: metrics.centroid, timestamp: timestamp))
        centroidHistory.removeAll { timestamp - $0.timestamp > swipeMaxDuration }
        
        // 3. PRIORITY 1: FIVE-FINGER MISSION CONTROL SEQUENCE
        if extCount >= 5 || currentState == .fiveFingerPinchLocked || currentState == .fiveFingerExpanding || currentState == .fiveFingerContracting {
            let events = processFiveFingerSequence(metrics: metrics, timestamp: timestamp)
            if !events.isEmpty {
                return events
            }
            if currentState.rawValue.contains("FIVE_FINGER") {
                return []
            }
        }
        
        // 4. PRIORITY 2: FOUR-FINGER FAST SWIPE
        if extCount == 4 {
            let events = processFourFingerSwipe(timestamp: timestamp)
            if !events.isEmpty {
                return events
            }
            currentState = .fourFingerCandidate
            return []
        }
        
        // 5. PRIORITY 3: TWO-FINGER PINCH / DRAG
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
                isDraggingActive = true
                currentState = .dragging
                emittedEvents.append(.leftMouseDown(at: currentCursorPosition))
                if let indexTip = hand.landmark(.indexTip) {
                    dragAnchorPosition = indexTip.point
                }
            }
            
        case .dragging:
            if pinchDist > pinchReleaseThreshold || extCount < 1 {
                isDraggingActive = false
                currentState = .cooldown
                cooldownUntil = timestamp + 0.15
                emittedEvents.append(.leftMouseUp(at: currentCursorPosition))
                dragAnchorPosition = nil
            } else {
                if let indexTip = hand.landmark(.indexTip) {
                    if let anchor = dragAnchorPosition {
                        let dx = (indexTip.x - anchor.x) * 1500.0
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
        
        previousSpread = spread
        return emittedEvents
    }
    
    // MARK: - Four-Finger Fast Swipe Kinematics
    private func processFourFingerSwipe(timestamp: TimeInterval) -> [AbstractGestureEvent] {
        guard centroidHistory.count >= 3 else { return [] }
        guard let first = centroidHistory.first, let last = centroidHistory.last else { return [] }
        
        let dt = last.timestamp - first.timestamp
        guard dt >= 0.05 && dt <= swipeMaxDuration else { return [] }
        
        let dx = last.point.x - first.point.x
        let dy = last.point.y - first.point.y
        let absDx = abs(dx)
        let absDy = abs(dy)
        let velocity = absDx / dt
        
        // 1. Horizontal displacement floor
        // 2. Velocity floor
        // 3. Horizontal dominance: absDx >= 2.0 * absDy
        if absDx >= swipeMinDisplacement && velocity >= swipeMinVelocity && absDx >= (absDy * swipeDirectionRatio) {
            let direction: SwipeDirection = (dx > 0) ? .right : .left
            centroidHistory.removeAll()
            currentState = .cooldown
            cooldownUntil = timestamp + swipeCooldownDuration
            return [.switchSpace(direction: direction)]
        }
        
        return []
    }
    
    // MARK: - Five-Finger Mission Control Sequence
    private func processFiveFingerSequence(metrics: HandMetrics, timestamp: TimeInterval) -> [AbstractGestureEvent] {
        let spread = metrics.spread
        let extCount = metrics.extendedFingerCount
        
        switch currentState {
        case .idle, .oneFingerCursor, .twoFingerDetected, .fourFingerCandidate:
            if extCount >= 5 && spread >= fiveFingerOpenThreshold {
                currentState = .fiveFingerOpen
                fiveFingerSequenceStartTime = timestamp
            }
            
        case .fiveFingerOpen:
            if spread < fiveFingerOpenThreshold - 0.05 {
                currentState = .fiveFingerContracting
            }
            
        case .fiveFingerContracting:
            // Fingertips converge to pinch lock
            if spread <= fiveFingerPinchThreshold {
                currentState = .fiveFingerPinchLocked
                // NOTE: Mission Control is NOT triggered here! It merely arms the sequence.
            } else if let start = fiveFingerSequenceStartTime, timestamp - start > fiveFingerMaxSequenceDuration {
                currentState = .idle
                fiveFingerSequenceStartTime = nil
            }
            
        case .fiveFingerPinchLocked:
            // Expanding outward
            if spread > fiveFingerPinchThreshold + 0.08 {
                currentState = .fiveFingerExpanding
            } else if let start = fiveFingerSequenceStartTime, timestamp - start > fiveFingerMaxSequenceDuration {
                currentState = .idle
                fiveFingerSequenceStartTime = nil
            }
            
        case .fiveFingerExpanding:
            // Open palm reaches trigger threshold
            if spread >= fiveFingerOpenThreshold {
                guard let start = fiveFingerSequenceStartTime else {
                    currentState = .idle
                    return []
                }
                let totalDuration = timestamp - start
                
                if totalDuration >= fiveFingerMinSequenceDuration && totalDuration <= fiveFingerMaxSequenceDuration {
                    currentState = .cooldown
                    cooldownUntil = timestamp + missionControlCooldownDuration
                    fiveFingerSequenceStartTime = nil
                    return [.triggerMissionControl]
                } else {
                    currentState = .idle
                    fiveFingerSequenceStartTime = nil
                }
            }
            
        default:
            break
        }
        
        return []
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
        centroidHistory.removeAll()
        fiveFingerSequenceStartTime = nil
        return events
    }
}
