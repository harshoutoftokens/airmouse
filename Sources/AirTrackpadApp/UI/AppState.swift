import Foundation
import SwiftUI
import CoreVideo
import AirTrackpadCore

@MainActor
public final class AppState: ObservableObject {
    @Published public var fps: Double = 0.0
    @Published public var latencyMs: Double = 0.0
    @Published public var observations: [HandObservation] = []
    @Published public var metrics: HandMetrics?
    @Published public var activeGestureName: String = "IDLE"
    @Published public var gestureState: AirTrackpadCore.GestureState = .idle
    @Published public var pose: HandPose = .none
    @Published public var pinchProgress: Double = 0.0
    @Published public var handSpeed: Double = 0.0
    @Published public var isRunning: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var isAccessibilityGranted: Bool = false
    @Published public var currentFrameImage: CGImage?
    /// Last recognized action ("Click", "Desktop →", …) for the HUD.
    @Published public var lastAction: String = ""
    @Published public var lastActionDate: Date?
    @Published public var cameraDescription: String = ""
    @Published public var cursorMode: CursorMode = .relative
    @Published public var isRecording: Bool = false
    @Published public var lastRecordingURL: URL?

    @Published public var showCameraFeed: Bool = AppSettings.load().showCameraFeed {
        didSet { persist { $0.showCameraFeed = showCameraFeed } }
    }
    @Published public var showPerformanceMetrics: Bool = AppSettings.load().showPerformanceMetrics {
        didSet { persist { $0.showPerformanceMetrics = showPerformanceMetrics } }
    }
    @Published public var isAlwaysOnTop: Bool = AppSettings.load().isAlwaysOnTop {
        didSet {
            persist { $0.isAlwaysOnTop = isAlwaysOnTop }
            onWindowLevelChange?(isAlwaysOnTop)
        }
    }

    /// Pointer feedback ring state (read by the overlay at display rate, not published).
    public var feedback: CursorFeedback = .hidden
    public var feedbackFlash: CursorFlash?

    public var onWindowLevelChange: ((Bool) -> Void)?

    public init() {}

    public func noteAction(_ text: String, flash: CursorFlash.Kind? = nil) {
        lastAction = text
        lastActionDate = Date()
        if let flash {
            feedbackFlash = CursorFlash(kind: flash, date: Date())
        }
    }

    private func persist(_ change: (inout AppSettings) -> Void) {
        var settings = AppSettings.load()
        let before = settings
        change(&settings)
        if settings != before {
            settings.save()
        }
    }
}
