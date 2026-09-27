import Foundation
import CoreVideo
import CoreGraphics
import AirTrackpadCore

public final class TrackingPipelineCoordinator: @unchecked Sendable {
    private let cameraManager = CameraManager()
    private let handTracker = VisionHandTracker(maximumHandCount: 1, mirrorsHorizontal: true)
    private let cursorEngine = CursorEngine()
    private let actionRouter: ActionRouter
    private let appState: AppState
    
    // FPS calculation
    private var lastFrameTime: TimeInterval = 0.0
    private var frameCount: Int = 0
    
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
    
    public func start() {
        Task { @MainActor in
            appState.isRunning = true
        }
        cameraManager.start()
    }
    
    public func stop() {
        cameraManager.stop()
        Task { @MainActor in
            appState.isRunning = false
            appState.observations = []
            appState.metrics = nil
            appState.fps = 0.0
        }
    }
    
    private func processFrame(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        let startTime = DispatchTime.now()
        
        do {
            let observations = try handTracker.process(pixelBuffer: pixelBuffer, timestamp: timestamp)
            
            let endTime = DispatchTime.now()
            let latencyNanos = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
            let latencyMs = Double(latencyNanos) / 1_000_000.0
            
            var gestureName = "IDLE"
            
            if let hand = observations.first {
                let metrics = FingerClassifier.extractMetrics(from: hand)
                
                // GESTURE 1: One-Finger Cursor Mode
                if metrics.extendedFingerCount == 1,
                   metrics.state(for: .index) == .extended,
                   let indexTip = hand.landmark(.indexTip),
                   indexTip.confidence > 0.4 {
                    
                    gestureName = "☝ ONE_FINGER_CURSOR"
                    if let cursorEvent = cursorEngine.process(indexTip: indexTip, timestamp: timestamp) {
                        actionRouter.handle(event: cursorEvent)
                    }
                } else {
                    cursorEngine.reset()
                }
                
                Task { @MainActor in
                    self.updateFPS(timestamp: timestamp)
                    self.appState.latencyMs = latencyMs
                    self.appState.observations = observations
                    self.appState.metrics = metrics
                    self.appState.activeGestureName = gestureName
                }
            } else {
                cursorEngine.reset()
                Task { @MainActor in
                    self.updateFPS(timestamp: timestamp)
                    self.appState.latencyMs = latencyMs
                    self.appState.observations = []
                    self.appState.metrics = nil
                    self.appState.activeGestureName = "NO_HAND"
                }
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
            frameCount = 0
            lastFrameTime = timestamp
        }
    }
}
