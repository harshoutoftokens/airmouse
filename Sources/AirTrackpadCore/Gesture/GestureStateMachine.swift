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
    public var pinchStartThreshold: Double = 0.24
    public var pinchReleaseThreshold: Double = 0.32
    public var clickMaxDuration: TimeInterval = 0.40
    public var dragHoldDelay: TimeInterval = 0.85 // ~1.0 second hold to activate drag
    public var clickCooldownDuration: TimeInterval = 0.20
    
    // 4-Finger Fast Swipe parameters
    public var swipeMinDisplacement: Double = 0.09
    public var swipeMinVelocity: Double = 0.15
    public var swipeMaxDuration: TimeInterval = 0.85
    public var swipeDirectionRatio: Double = 1.05
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
    
    // Swipe kinematic buffer & Point A -> Point B tracking
    private var swipeAnchorPoint: Landmark?
    private var swipeAnchorTime: TimeInterval?
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
        swipeAnchorPoint = nil
        swipeAnchorTime = nil
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
            swipeAnchorPoint = nil
            swipeAnchorTime = nil
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
        
        // 3. PRIORITY 1: MULTI-FINGER HORIZONTAL SWIPE (Point A -> Point B)
        // Whenever a multi-finger or open-palm pose is detected, evaluate horizontal displacement.
        // A distinct horizontal stroke (Point A -> Point B) ALWAYS triggers desktop switching,
        // even if Mission Control is open or the hand has 5 open fingers.
        let isMultiFinger = isMultiFingerSwipePose(metrics: metrics)
        let isFiveFingerState = currentState.rawValue.contains("FIVE_FINGER")
        let isFiveFingerPose = (extCount >= 5 && spread >= fiveFingerOpenThreshold)
        
        if isMultiFinger || isFiveFingerState || isFiveFingerPose {
            let events = processFourFingerSwipe(metrics: metrics, timestamp: timestamp)
            if !events.isEmpty {
                fiveFingerSequenceStartTime = nil
                return events
            }
        } else {
            swipeAnchorPoint = nil
            swipeAnchorTime = nil
        }
        
        // 4. PRIORITY 2: FIVE-FINGER MISSION CONTROL SEQUENCE (Open palm -> Pinch in -> Expand out)
        if isFiveFingerState || isFiveFingerPose {
            let events = processFiveFingerSequence(metrics: metrics, timestamp: timestamp)
            if !events.isEmpty {
                return events
            }
            if currentState.rawValue.contains("FIVE_FINGER") {
                return []
            }
        }
        
        if isMultiFinger && currentState != .cooldown && !currentState.rawValue.contains("FIVE_FINGER") {
            currentState = .fourFingerCandidate
            return []
        }
        
        // 5. PRIORITY 3: TWO-FINGER PINCH / DRAG & ONE-FINGER CURSOR
        let isIndexExtended = (metrics.state(for: .index) == .extended)
        let isMiddleExtended = (metrics.state(for: .middle) == .extended)
        let isRingExtended = (metrics.state(for: .ring) == .extended)
        let isLittleExtended = (metrics.state(for: .little) == .extended)
        
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
    
    // MARK: - Four-Finger / Multi-Finger Swipe Kinematics (Point A -> Point B)
    private func isMultiFingerSwipePose(metrics: HandMetrics) -> Bool {
        let extCount = metrics.extendedFingerCount
        let pinchDist = metrics.pinchDistance
        
        let indexState = metrics.state(for: .index)
        let middleState = metrics.state(for: .middle)
        let ringState = metrics.state(for: .ring)
        let littleState = metrics.state(for: .little)
        let thumbState = metrics.state(for: .thumb)
        
        let isIndexUp = (indexState == .extended || indexState == .partiallyExtended)
        let isMiddleUp = (middleState == .extended || middleState == .partiallyExtended)
        let isRingUp = (ringState == .extended || ringState == .partiallyExtended)
        let isLittleUp = (littleState == .extended || littleState == .partiallyExtended)
        let isThumbUp = (thumbState == .extended || thumbState == .partiallyExtended)
        
        let uprightCount = [isIndexUp, isMiddleUp, isRingUp, isLittleUp, isThumbUp].filter { $0 }.count
        
        // Exclude single finger pointing
        if isIndexUp && !isMiddleUp && !isRingUp && !isLittleUp {
            return false
        }
        
        // Exclude two-finger pause
        if isIndexUp && isMiddleUp && !isRingUp && !isLittleUp && uprightCount == 2 {
            return false
        }
        
        // Exclude pinch
        if isIndexUp && (pinchDist < pinchStartThreshold) && !isRingUp && !isLittleUp {
            return false
        }
        
        // Classic 4 extended fingers (or 5 open fingers)
        if extCount >= 4 {
            return true
        }
        
        // 3 extended with at least 4 upright fingers (handles partially extended little/ring/thumb)
        if extCount >= 3 && uprightCount >= 4 && isIndexUp && isMiddleUp {
            return true
        }
        
        // At least 4 upright fingers with index and middle up
        if uprightCount >= 4 && isIndexUp && isMiddleUp && (isRingUp || isLittleUp) {
            return true
        }
        
        // Extended index, middle, ring (classical 3+ fingers)
        if indexState == .extended && middleState == .extended && ringState == .extended {
            return true
        }
        
        return false
    }
    
    private func processFourFingerSwipe(metrics: HandMetrics, timestamp: TimeInterval) -> [AbstractGestureEvent] {
        let currentCentroid = metrics.centroid
        
        centroidHistory.append(CentroidSample(point: currentCentroid, timestamp: timestamp))
        centroidHistory.removeAll { timestamp - $0.timestamp > swipeMaxDuration }
        
        guard let anchor = swipeAnchorPoint, let startTime = swipeAnchorTime else {
            swipeAnchorPoint = currentCentroid
            swipeAnchorTime = timestamp
            return []
        }
        
        let dx = currentCentroid.x - anchor.x
        let dy = currentCentroid.y - anchor.y
        let absDx = abs(dx)
        let absDy = abs(dy)
        let dt = timestamp - startTime
        
        // If hand is resting / hovering near Point A, keep refreshing Point A to current position
        // so that the swipe displacement is measured from where the stroke actually starts!
        if absDx < 0.035 && absDy < 0.035 {
            swipeAnchorPoint = currentCentroid
            swipeAnchorTime = timestamp
            return []
        }
        
        // User has moved from Point A towards Point B!
        // Check if displacement (~10 cm in camera coordinates) is reached with horizontal dominance:
        let isHorizontal = absDx >= (absDy * swipeDirectionRatio)
        let isFarEnough = absDx >= swipeMinDisplacement
        let isTimely = dt >= 0.04 && dt <= swipeMaxDuration
        
        if isFarEnough && isHorizontal && isTimely {
            // dx > 0: Hand moved to the right -> Trigger swipe to desktop on the right!
            // dx < 0: Hand moved to the left -> Trigger swipe to desktop on the left!
            let direction: SwipeDirection = (dx > 0) ? .right : .left
            print("🚀 AirTrackpad: 4-Finger Desktop Switch Triggered: \(direction) (dx: \(String(format: "%.3f", dx)), dt: \(String(format: "%.3f", dt))s)")
            
            swipeAnchorPoint = nil
            swipeAnchorTime = nil
            centroidHistory.removeAll()
            fiveFingerSequenceStartTime = nil
            
            currentState = .cooldown
            cooldownUntil = timestamp + swipeCooldownDuration
            
            return [.switchSpace(direction: direction)]
        }
        
        // If stroke took too long (> swipeMaxDuration) without reaching displacement, reset anchor to current point
        if dt > swipeMaxDuration {
            swipeAnchorPoint = currentCentroid
            swipeAnchorTime = timestamp
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
            } else if extCount >= 5 && spread <= fiveFingerPinchThreshold {
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
