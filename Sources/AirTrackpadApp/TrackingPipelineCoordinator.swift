import Foundation
import CoreVideo
import CoreGraphics
import AirTrackpadCore

public final class TrackingPipelineCoordinator: @unchecked Sendable {
    private let cameraManager = CameraManager()
    private let handTracker = VisionHandTracker(maximumHandCount: 2, mirrorsHorizontal: true)
    private let cursorEngine = CursorEngine()
    private let stateMachine = GestureStateMachine()
    private let actionRouter: ActionRouter
    private let appState: AppState
    
    // FPS calculation
    private var lastFrameTime: TimeInterval = 0.0
    private var frameCount: Int = 0
    private var lastTrackedWrist: Landmark?
    
    public init(appState: AppState, backend: InputBackendProtocol = CGEventInputBackend()) {
        self.appState = appState
        self.actionRouter = ActionRouter(backend: backend)
        setupPipeline()
    }
    
    private func setupPipeline() {
        cameraManager.onFrame = { [weak self] pixelBuffer, timestamp in
            self?.processFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
    }
    
    public func applySettings(_ settings: AppSettings) {
        stateMachine.swipeMinDisplacement = settings.swipeMinDisplacement
        stateMachine.swipeMinVelocity = settings.swipeMinVelocity
        stateMachine.swipeMaxDuration = settings.swipeMaxDuration
        stateMachine.swipeCooldownDuration = settings.swipeCooldown
        stateMachine.fiveFingerPinchThreshold = settings.fiveFingerPinchThreshold
        stateMachine.fiveFingerOpenThreshold = settings.fiveFingerOpenThreshold
        stateMachine.fiveFingerMaxSequenceDuration = settings.fiveFingerMaxSequenceDuration
        stateMachine.missionControlCooldownDuration = settings.missionControlCooldown
        stateMachine.pinchStartThreshold = settings.pinchStartThreshold
        stateMachine.pinchReleaseThreshold = settings.pinchReleaseThreshold
        stateMachine.clickMaxDuration = settings.clickMaxDuration
        stateMachine.dragHoldDelay = settings.dragHoldDelay
        stateMachine.clickCooldownDuration = settings.clickCooldown
        
        cursorEngine.deadZonePixels = settings.cursorDeadzonePixels
        cursorEngine.filter.updateCoefficients(minCutoff: settings.filterMinCutoff, beta: settings.filterBeta)
    }
    
    @MainActor
    public func start() {
        applySettings(AppSettings.load())
        cursorEngine.mapper.updateScreenBounds()
        stateMachine.screenBounds = cursorEngine.mapper.screenBounds
        let isTrusted = PermissionsHelper.isAccessibilityAuthorized
        Task { @MainActor in
            appState.isRunning = true
            appState.isAccessibilityGranted = isTrusted
        }
        cameraManager.start()
    }
    
    public func stop() {
        cameraManager.stop()
        actionRouter.emergencyStop()
        stateMachine.reset()
        cursorEngine.reset()
        lastTrackedWrist = nil
        Task { @MainActor in
            appState.isRunning = false
            appState.observations = []
            appState.metrics = nil
            appState.fps = 0.0
            appState.activeGestureName = "STOPPED"
        }
    }
    
    private func processFrame(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        let startTime = DispatchTime.now()
        
        do {
            let observations = try handTracker.process(pixelBuffer: pixelBuffer, timestamp: timestamp)
            
            let endTime = DispatchTime.now()
            let latencyNanos = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
            let latencyMs = Double(latencyNanos) / 1_000_000.0
            
            // Select continuous primary hand if multiple detected
            let hand: HandObservation?
            if observations.isEmpty {
                hand = nil
                lastTrackedWrist = nil
            } else if observations.count == 1 {
                hand = observations.first
                lastTrackedWrist = hand?.landmark(.wrist)
            } else {
                // Find hand closest to previous wrist position
                if let prevWrist = lastTrackedWrist {
                    let sorted = observations.sorted { obs1, obs2 in
                        let d1 = obs1.landmark(.wrist).map { Geometry.distance($0, prevWrist) } ?? 999.0
                        let d2 = obs2.landmark(.wrist).map { Geometry.distance($0, prevWrist) } ?? 999.0
                        return d1 < d2
                    }
                    hand = sorted.first
                } else {
                    hand = observations.max(by: { $0.confidence < $1.confidence })
                }
                lastTrackedWrist = hand?.landmark(.wrist)
            }
            
            let metrics = hand.map { FingerClassifier.extractMetrics(from: $0) }
            
            // 1. Process Temporal State Machine
            let smEvents = stateMachine.process(hand: hand, metrics: metrics, timestamp: timestamp)
            var swipeTriggeredName: String?
            for event in smEvents {
                actionRouter.handle(event: event)
                if case .switchSpace(let dir) = event {
                    swipeTriggeredName = "🚀 SWIPE \(dir.rawValue.uppercased())"
                }
            }
            
            // 2. Cursor Navigation: ONLY active in oneFingerCursor mode
            if stateMachine.currentState == .oneFingerCursor,
               let h = hand,
               let indexTip = h.landmark(.indexTip),
               indexTip.confidence > 0.4 {
                
                if let cursorEvent = cursorEngine.process(indexTip: indexTip, timestamp: timestamp) {
                    actionRouter.handle(event: cursorEvent)
                    if case .cursorMoved(let pt) = cursorEvent {
                        stateMachine.updateCursorPosition(pt)
                    }
                }
            } else if hand == nil {
                // Only reset the OneEuroFilter when hand is completely lost from the camera
                cursorEngine.reset()
            }
            
            let currentGestureName = swipeTriggeredName ?? stateMachine.currentState.rawValue
            
            Task { @MainActor in
                self.updateFPS(timestamp: timestamp)
                self.appState.latencyMs = latencyMs
                self.appState.observations = observations
                self.appState.metrics = metrics
                self.appState.activeGestureName = currentGestureName
            }
        } catch {
            // Silently continue to next frame on transient Vision error
        }
    }
    
    @MainActor
    private func updateFPS(timestamp: TimeInterval) {
        if lastFrameTime == 0.0 {
            lastFrameTime = timestamp
            return
        }
        frameCount += 1
        let dt = timestamp - lastFrameTime
        if dt >= 0.5 {
            let currentFPS = Double(frameCount) / dt
            appState.fps = currentFPS
            appState.isAccessibilityGranted = PermissionsHelper.isAccessibilityAuthorized
            frameCount = 0
            lastFrameTime = timestamp
        }
    }
}
