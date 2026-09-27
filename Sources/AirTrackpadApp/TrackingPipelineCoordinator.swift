import Foundation
import CoreVideo
import CoreGraphics
import AirTrackpadCore

public final class TrackingPipelineCoordinator: @unchecked Sendable {
    private let cameraManager = CameraManager()
    private let handTracker = VisionHandTracker(maximumHandCount: 1, mirrorsHorizontal: true)
    private let appState: AppState
    
    // FPS calculation
    private var lastFrameTime: TimeInterval = 0.0
    private var frameCount: Int = 0
    
    public init(appState: AppState) {
        self.appState = appState
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
            
            let primaryMetrics = observations.first.map { FingerClassifier.extractMetrics(from: $0) }
            
            Task { @MainActor in
                self.updateFPS(timestamp: timestamp)
                self.appState.latencyMs = latencyMs
                self.appState.observations = observations
                self.appState.metrics = primaryMetrics
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
