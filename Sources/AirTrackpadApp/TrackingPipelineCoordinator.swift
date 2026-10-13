import Foundation
import AppKit
import CoreVideo
import CoreGraphics
import CoreImage
import os
import AirTrackpadCore

public final class TrackingPipelineCoordinator: @unchecked Sendable {
    private let cameraManager = CameraManager()
    private let handTracker = VisionHandTracker(maximumHandCount: 2, mirrorsHorizontal: true)
    private let stateMachine = GestureStateMachine()
    private let backend: CGEventInputBackend
    private let actionRouter: ActionRouter
    private let appState: AppState
    private let recorder = GestureRecorder()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let log = Logger(subsystem: "com.airtrackpad.app", category: "gestures")

    // Camera-queue state
    private var lastFPSTime: TimeInterval = 0.0
    private var framesSinceFPS: Int = 0
    private var frameCounter: Int = 0
    private var lastTrackedWrist: Landmark?
    private var isCameraFeedEnabled: Bool = false
    private var pauseWhileTyping: Bool = true
    private var isPaused: Bool = false
    private var lastGestureState: GestureState = .idle
    /// Uptime of the last delivered camera frame, and whether the watchdog already fired.
    private var lastFrameUptime: TimeInterval = 0
    private var watchdogTripped = false
    private var watchdog: DispatchSourceTimer?

    private let keyLock = NSLock()
    private var lastKeyboardActivity: TimeInterval = 0

    public init(appState: AppState) {
        self.appState = appState
        self.backend = CGEventInputBackend()
        self.actionRouter = ActionRouter(backend: backend, smoothing: true)

        cameraManager.onFrame = { [weak self] pixelBuffer, timestamp in
            self?.processFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
        cameraManager.onCameraChanged = { [weak self] description in
            Task { @MainActor in self?.appState.cameraDescription = description }
        }
        backend.spaceSwitcher.onResult = { [weak self] result in
            self?.report(result)
        }
    }

    // MARK: - Settings

    public func applySettings(_ settings: AppSettings) {
        let config = settings.gestureConfig(doubleClickInterval: NSEvent.doubleClickInterval)
        let cameraID = settings.cameraDeviceID
        cameraManager.perform { [weak self] in
            guard let self else { return }
            self.stateMachine.apply(config)
            settings.configure(self.stateMachine.cursor)
            self.handTracker.mirrorsHorizontal = settings.mirrorsHorizontal
            self.backend.spaceSwitcher.style = settings.spaceSwitchStyle
            self.actionRouter.momentumEnabled = settings.scrollMomentum
            self.pauseWhileTyping = settings.pauseWhileTyping
            self.isCameraFeedEnabled = settings.showCameraFeed
        }
        cameraManager.selectDevice(cameraID)
        Task { @MainActor in self.appState.cursorMode = settings.cursorMode }
    }

    public func refreshDisplayLayout() {
        let layout = DisplayLayout.current()
        actionRouter.layout = layout
        let pointer = backend.currentPointerLocation()
        cameraManager.perform { [weak self] in
            self?.stateMachine.cursor.mapper.screenBounds = layout.display(containing: pointer)
        }
    }

    // MARK: - Lifecycle

    @MainActor
    public func start() {
        applySettings(AppSettings.load())
        refreshDisplayLayout()
        actionRouter.setEnabled(true)
        startWatchdog()
        cameraManager.perform { [weak self] in self?.isPaused = false }
        appState.isRunning = true
        appState.isPaused = false
        appState.isAccessibilityGranted = PermissionsHelper.isAccessibilityAuthorized
        cameraManager.start()
    }

    public func stop() {
        // Disable output first: releases any held button now, and frames still in flight can't
        // press it again afterwards.
        actionRouter.setEnabled(false)
        cameraManager.stop()
        cameraManager.perform { [weak self] in
            guard let self else { return }
            _ = self.stateMachine.reset()
            self.lastTrackedWrist = nil
            self.lastFrameUptime = 0
        }
        Task { @MainActor in
            appState.isRunning = false
            appState.observations = []
            appState.metrics = nil
            appState.fps = 0.0
            appState.activeGestureName = "STOPPED"
            appState.feedback = .hidden
        }
    }

    /// Keeps the camera running (HUD stays live) but stops sending input.
    public func setPaused(_ paused: Bool) {
        if paused {
            // Release immediately, without waiting behind frame work on the camera queue.
            actionRouter.emergencyStop()
        }
        cameraManager.perform { [weak self] in
            guard let self else { return }
            self.isPaused = paused
            if paused {
                for event in self.stateMachine.reset() { self.actionRouter.handle(event: event) }
                self.actionRouter.emergencyStop()
            }
        }
        Task { @MainActor in
            appState.isPaused = paused
            if paused { appState.feedback = .hidden }
        }
    }

    /// Called for every key press anywhere: gestures pause briefly while you type.
    public func noteKeyboardActivity() {
        keyLock.lock()
        lastKeyboardActivity = ProcessInfo.processInfo.systemUptime
        keyLock.unlock()
    }

    private var isTyping: Bool {
        keyLock.lock()
        defer { keyLock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastKeyboardActivity < 0.6
    }

    // MARK: - Diagnostics

    public func testSpaceSwitch(_ direction: SwipeDirection) {
        backend.spaceSwitcher.switchSpace(direction)
    }

    public func resetSpaceSwitchCalibration() {
        backend.spaceSwitcher.resetCalibration()
    }

    public func setRecording(_ recording: Bool) {
        cameraManager.perform { [weak self] in
            guard let self else { return }
            if recording {
                self.recorder.startRecording(name: "session-\(Int(Date().timeIntervalSince1970))")
            } else if self.recorder.isRecording {
                let recording = self.recorder.stopRecording()
                let url = TrackingPipelineCoordinator.recordingsDirectory()
                    .appendingPathComponent("\(recording.name).json")
                try? GestureRecorder.save(recording: recording, to: url)
                Task { @MainActor in self.appState.lastRecordingURL = url }
            }
        }
        Task { @MainActor in appState.isRecording = recording }
    }

    public static func recordingsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AirTrackpad/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Frame pipeline (camera queue)

    // MARK: - Frame watchdog
    
    /// Hand-loss handling runs per frame, so if frames stop arriving (camera unplugged,
    /// Continuity Camera gone, capture error) nothing would ever release a held button. The
    /// watchdog does: no frame for 0.35 s → reset recognition and release everything.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 0.15, leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let coordinator = self else { return }
            coordinator.cameraManager.perform { [weak coordinator] in coordinator?.checkFrameWatchdog() }
        }
        timer.resume()
        watchdog = timer
    }
    
    private func checkFrameWatchdog() {
        guard !watchdogTripped, lastFrameUptime > 0,
              ProcessInfo.processInfo.systemUptime - lastFrameUptime > 0.35 else { return }
        watchdogTripped = true
        for event in stateMachine.reset() { actionRouter.handle(event: event) }
        actionRouter.emergencyStop()
        log.error("no camera frames for 0.35 s — released input")
        Task { @MainActor in
            self.appState.feedback = .hidden
            self.appState.observations = []
            self.appState.activeGestureName = "NO CAMERA FRAMES"
        }
    }
    
    private func processFrame(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        let startTime = DispatchTime.now()
        frameCounter += 1
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        watchdogTripped = false

        let observations = (try? handTracker.process(pixelBuffer: pixelBuffer, timestamp: timestamp)) ?? []
        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0

        let hand = selectHand(from: observations)
        let metrics = hand.map { FingerClassifier.extractMetrics(from: $0) }

        let suppress = isPaused || (pauseWhileTyping && isTyping)
        let events = stateMachine.process(
            hand: suppress ? nil : hand,
            metrics: suppress ? nil : metrics,
            timestamp: timestamp
        )
        let telemetry = stateMachine.telemetry
        let state = stateMachine.currentState

        var actionText: String?
        var flash: CursorFlash.Kind?
        for event in events {
            actionRouter.handle(event: event)
            switch event {
            case .leftClick(let count):
                actionText = count == 1 ? "Click" : (count == 2 ? "Double-click" : "Triple-click")
                log.info("click count=\(count) pinch=\(telemetry.pinchDistance, format: .fixed(precision: 2))")
            case .rightClick:
                actionText = "Right-click"
                log.info("right-click")
            case .leftMouseDown:
                actionText = "Drag"
                log.info("drag begin")
            case .leftMouseUp:
                actionText = "Drop"
                log.info("drag end")
            case .switchSpace(let direction):
                actionText = direction == .right ? "Desktop →" : "Desktop ←"
                flash = direction == .right ? .swipeRight : .swipeLeft
                if let s = telemetry.lastSwipe {
                    log.info("swipe \(direction.rawValue, privacy: .public) dist=\(s.distance, format: .fixed(precision: 2)) peak=\(s.peakSpeed, format: .fixed(precision: 2)) dur=\(s.duration, format: .fixed(precision: 3))")
                }
            case .triggerMissionControl:
                actionText = "Mission Control"
                flash = .missionControl
                log.info("mission control")
            default:
                break
            }
        }
        if state != lastGestureState {
            log.debug("state \(self.lastGestureState.rawValue, privacy: .public) → \(state.rawValue, privacy: .public) pose=\(telemetry.pose.rawValue, privacy: .public)")
            lastGestureState = state
        }

        if recorder.isRecording {
            recorder.recordFrame(observation: hand, metrics: metrics, gestureState: state.rawValue, timestamp: timestamp)
        }

        let feedback: CursorFeedback
        if suppress || hand == nil {
            feedback = state == .dragging ? .dragging : .hidden
        } else {
            switch state {
            case .pointing: feedback = .tracking(progress: telemetry.pinchProgress)
            case .pressed: feedback = .pressed
            case .dragging: feedback = .dragging
            case .scrolling: feedback = .scrolling
            case .openHand, .missionControlGesture: feedback = .openHand
            default: feedback = .hidden
            }
        }

        var previewImage: CGImage?
        if isCameraFeedEnabled && frameCounter % 2 == 0 {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            previewImage = ciContext.createCGImage(image, from: image.extent)
        }

        let gestureName = suppress && !isPaused ? "⌨︎ TYPING" : (isPaused ? "⏸ PAUSED" : state.rawValue)
        Task { @MainActor in
            self.updateFPS(timestamp: timestamp)
            self.appState.latencyMs = latencyMs
            self.appState.observations = observations
            self.appState.metrics = metrics
            self.appState.gestureState = state
            self.appState.activeGestureName = gestureName
            self.appState.pose = telemetry.pose
            self.appState.pinchProgress = telemetry.pinchProgress
            self.appState.handSpeed = telemetry.handSpeed
            self.appState.feedback = feedback
            if let actionText {
                self.appState.noteAction(actionText, flash: flash)
            }
            if self.appState.showCameraFeed {
                if let previewImage {
                    self.appState.currentFrameImage = previewImage
                }
            } else if self.appState.currentFrameImage != nil {
                self.appState.currentFrameImage = nil
            }
        }
    }

    /// Keeps following the same hand when two are visible.
    private func selectHand(from observations: [HandObservation]) -> HandObservation? {
        let hand: HandObservation?
        if observations.count <= 1 {
            hand = observations.first
        } else if let previous = lastTrackedWrist {
            hand = observations.min { a, b in
                let da = a.landmark(.wrist).map { Geometry.distance($0, previous) } ?? .infinity
                let db = b.landmark(.wrist).map { Geometry.distance($0, previous) } ?? .infinity
                return da < db
            }
        } else {
            hand = observations.max { $0.confidence < $1.confidence }
        }
        lastTrackedWrist = hand?.landmark(.wrist)
        return hand
    }

    private func report(_ result: SpaceSwitchResult) {
        let text: String
        var flash: CursorFlash.Kind?
        switch result {
        case .switched(let direction):
            // The slide itself is the feedback; only log it.
            log.info("space switch: moved \(direction.rawValue, privacy: .public)")
            return
        case .blockedAtEdge(let direction):
            text = direction == .right ? "No desktop to the right" : "No desktop to the left"
            flash = .blocked
        case .correctedDirection:
            text = "Desktop direction calibrated"
        case .noEffect:
            text = "Desktop switch had no effect"
        case .fellBackToKeyboard:
            text = "Using ⌃← / ⌃→ for desktops"
        case .unexpectedDirection:
            text = "Desktop moved the other way — will correct if it repeats"
        }
        log.info("space switch: \(text, privacy: .public)")
        Task { @MainActor in self.appState.noteAction(text, flash: flash) }
    }

    @MainActor
    private func updateFPS(timestamp: TimeInterval) {
        if lastFPSTime == 0.0 {
            lastFPSTime = timestamp
            return
        }
        framesSinceFPS += 1
        let dt = timestamp - lastFPSTime
        if dt >= 1.0 {
            appState.fps = Double(framesSinceFPS) / dt
            appState.isAccessibilityGranted = PermissionsHelper.isAccessibilityAuthorized
            framesSinceFPS = 0
            lastFPSTime = timestamp
        }
    }
}
