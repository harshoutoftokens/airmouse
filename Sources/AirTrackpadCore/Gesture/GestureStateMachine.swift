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
    
    // Screen configuration
    public var screenBounds: CGRect = CGRect(x: 0, y: 0, width: 1470, height: 956)
    
    // 2-Finger Pinch / Drag parameters
    public var pinchStartThreshold: Double = 0.22
    public var pinchReleaseThreshold: Double = 0.32
    public var clickMaxDuration: TimeInterval = 0.40
    public var dragHoldDelay: TimeInterval = 0.35
    public var clickCooldownDuration: TimeInterval = 0.20
    
    // 4-Finger Fast Swipe parameters
    public var swipeMinDisplacement: Double = 0.10
    public var swipeMinVelocity: Double = 0.30
    public var swipeMaxDuration: TimeInterval = 0.40
    public var swipeDirectionRatio: Double = 1.3
    public var swipeCooldownDuration: TimeInterval = 0.40
    
    // 5-Finger Mission Control parameters
    public var fiveFingerOpenThreshold: Double = 0.46
    public var fiveFingerPinchThreshold: Double = 0.25
    public var fiveFingerMaxSequenceDuration: TimeInterval = 1.40
    public var fiveFingerMinSequenceDuration: TimeInterval = 0.15
    public var missionControlCooldownDuration: TimeInterval = 0.50
    
    // Timers & internal tracking
    private var pinchStartTime: TimeInterval?
    private var cooldownUntil: TimeInterval = 0.0
    private var isDraggingActive: Bool = false
    public private(set) var currentCursorPosition: CGPoint = .zero
    private var dragAnchorPosition: CGPoint?
    
    // Stability debounce counters (prevent single-frame flicker)
    private var consecutiveTwoFingerFrames: Int = 0
    private var consecutiveOneFingerFrames: Int = 0
    
    // Swipe kinematic buffer
    private var centroidHistory: [CentroidSample] = []
    
    // 5-finger temporal state tracking
    private var fiveFingerSequenceStartTime: TimeInterval?
    private var previousSpread: Double = 0.0
    
    private let lock = NSLock()
    
    public init() {
        if let loc = CGEvent(source: nil)?.location {
            self.currentCursorPosition = loc
        }
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentState = .idle
        pinchStartTime = nil
        isDraggingActive = false
        dragAnchorPosition = nil
        consecutiveTwoFingerFrames = 0
        consecutiveOneFingerFrames = 0
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
            consecutiveOneFingerFrames = 0
            consecutiveTwoFingerFrames = 0
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
        
        // Update stability counters
        if extCount >= 2 {
            consecutiveTwoFingerFrames += 1
            consecutiveOneFingerFrames = 0
        } else if extCount == 1 {
            consecutiveOneFingerFrames += 1
            consecutiveTwoFingerFrames = 0
        } else {
            consecutiveOneFingerFrames = 0
            consecutiveTwoFingerFrames = 0
        }
        
        // Record centroid history for swipe detection
        centroidHistory.append(CentroidSample(point: metrics.centroid, timestamp: timestamp))
        centroidHistory.removeAll { timestamp - $0.timestamp > swipeMaxDuration }
        
        // 3. PRIORITY 1: FIVE-FINGER MISSION CONTROL SEQUENCE
        let isFiveFingerState = currentState.rawValue.contains("FIVE_FINGER")
        let isFiveFingerPose = (extCount >= 5 && spread >= fiveFingerOpenThreshold)
        
        if isFiveFingerState || isFiveFingerPose {
            let events = processFiveFingerSequence(metrics: metrics, timestamp: timestamp)
            if !events.isEmpty {
                return events
            }
            if currentState.rawValue.contains("FIVE_FINGER") {
                return []
            }
        }
        
        // 4. PRIORITY 2: FOUR-FINGER FAST SWIPE
        let isIndexExtended = (metrics.state(for: .index) == .extended)
        let isMiddleExtended = (metrics.state(for: .middle) == .extended)
        let isRingExtended = (metrics.state(for: .ring) == .extended)
        let isLittleExtended = (metrics.state(for: .little) == .extended)
        
        let isFourFingerPose = (extCount >= 3 && extCount <= 5 && isIndexExtended && isMiddleExtended && isRingExtended) || extCount == 4
        if isFourFingerPose {
            let events = processFourFingerSwipe(timestamp: timestamp)
            if !events.isEmpty {
                return events
            }
            currentState = .fourFingerCandidate
            return []
        }
        
        // 5. PRIORITY 3: TWO-FINGER PINCH / DRAG & ONE-FINGER CURSOR
        
        let isPinchTriggered = isIndexExtended && (pinchDist < pinchStartThreshold) && !isRingExtended && !isLittleExtended
        let isPointingWithOneFinger = isIndexExtended && !isMiddleExtended && !isRingExtended && !isLittleExtended && (pinchDist >= pinchStartThreshold)
        let isTwoFingersDetected = (isIndexExtended && isMiddleExtended && !isRingExtended && !isLittleExtended) || (extCount == 2 && pinchDist >= pinchStartThreshold)
        
        // Immediate pinch detection
        if isPinchTriggered && (currentState == .oneFingerCursor || currentState == .twoFingerDetected || currentState == .idle) {
            currentState = .pinchCandidate
            pinchStartTime = timestamp
        } else if isTwoFingersDetected && currentState == .oneFingerCursor {
            currentState = .twoFingerDetected
        }
        
        switch currentState {
        case .idle:
            if isPinchTriggered {
                currentState = .pinchCandidate
                pinchStartTime = timestamp
            } else if isPointingWithOneFinger {
                currentState = .oneFingerCursor
            } else if isTwoFingersDetected {
                currentState = .twoFingerDetected
            }
            
        case .oneFingerCursor:
            if isPinchTriggered {
                currentState = .pinchCandidate
                pinchStartTime = timestamp
            } else if isTwoFingersDetected {
                currentState = .twoFingerDetected
            } else if extCount == 0 && !isIndexExtended {
                currentState = .idle
            }
            
        case .twoFingerDetected:
            if isPinchTriggered {
                currentState = .pinchCandidate
                pinchStartTime = timestamp
            } else if isPointingWithOneFinger {
                currentState = .oneFingerCursor
            } else if extCount == 0 && !isIndexExtended {
                currentState = .idle
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
            // When user releases pinch -> Mouse Up!
            if pinchDist > pinchReleaseThreshold {
                isDraggingActive = false
                currentState = .cooldown
                cooldownUntil = timestamp + 0.15
                emittedEvents.append(.leftMouseUp(at: currentCursorPosition))
                dragAnchorPosition = nil
            } else {
                // Drag displacement: accumulate hand movement onto currentCursorPosition
                if let indexTip = hand.landmark(.indexTip) {
                    if let anchor = dragAnchorPosition {
                        // Delta in normalized space mapped to screen space
                        let dx = (indexTip.x - anchor.x) * screenBounds.width * 1.5
                        let dy = (anchor.y - indexTip.y) * screenBounds.height * 1.5 // inverted Y
                        
                        let newX = max(screenBounds.minX, min(screenBounds.maxX, currentCursorPosition.x + dx))
                        let newY = max(screenBounds.minY, min(screenBounds.maxY, currentCursorPosition.y + dy))
                        
                        currentCursorPosition = CGPoint(x: newX, y: newY)
                        emittedEvents.append(.leftMouseDragged(to: currentCursorPosition))
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
        guard centroidHistory.count >= 2 else { return [] }
        guard let first = centroidHistory.first, let last = centroidHistory.last else { return [] }
        
        let dt = last.timestamp - first.timestamp
        guard dt >= 0.04 && dt <= swipeMaxDuration else { return [] }
        
        let dx = last.point.x - first.point.x
        let dy = last.point.y - first.point.y
        let absDx = abs(dx)
        let absDy = abs(dy)
        let velocity = absDx / dt
        
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
            if extCount >= 4 && spread >= fiveFingerOpenThreshold {
                currentState = .fiveFingerOpen
                fiveFingerSequenceStartTime = timestamp
            } else if spread <= fiveFingerPinchThreshold {
                currentState = .fiveFingerPinchLocked
                fiveFingerSequenceStartTime = timestamp
            }
            
        case .fiveFingerOpen:
            if spread < fiveFingerOpenThreshold - 0.05 {
                currentState = .fiveFingerContracting
            } else if let start = fiveFingerSequenceStartTime, timestamp - start > fiveFingerMaxSequenceDuration {
                currentState = .idle
                fiveFingerSequenceStartTime = nil
            }
            
        case .fiveFingerContracting:
            if spread <= fiveFingerPinchThreshold {
                currentState = .fiveFingerPinchLocked
            } else if let start = fiveFingerSequenceStartTime, timestamp - start > fiveFingerMaxSequenceDuration {
                currentState = .idle
                fiveFingerSequenceStartTime = nil
            }
            
        case .fiveFingerPinchLocked:
            if spread > fiveFingerPinchThreshold + 0.06 {
                currentState = .fiveFingerExpanding
            } else if let start = fiveFingerSequenceStartTime, timestamp - start > fiveFingerMaxSequenceDuration {
                currentState = .idle
                fiveFingerSequenceStartTime = nil
            }
            
        case .fiveFingerExpanding:
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
            } else if let start = fiveFingerSequenceStartTime, timestamp - start > fiveFingerMaxSequenceDuration {
                currentState = .idle
                fiveFingerSequenceStartTime = nil
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
        consecutiveOneFingerFrames = 0
        consecutiveTwoFingerFrames = 0
        centroidHistory.removeAll()
        fiveFingerSequenceStartTime = nil
        return events
    }
}
