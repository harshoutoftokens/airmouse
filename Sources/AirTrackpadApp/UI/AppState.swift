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
    @Published public var isRunning: Bool = false
    @Published public var isAccessibilityGranted: Bool = false
    @Published public var currentFrameImage: CGImage?
    @Published public var cursorSpeedMultiplier: Double = 1.0
    @Published public var showCameraFeed: Bool = AppSettings.load().showCameraFeed {
        didSet {
            var settings = AppSettings.load()
            if settings.showCameraFeed != showCameraFeed {
                settings.showCameraFeed = showCameraFeed
                settings.save()
            }
        }
    }
    @Published public var showPerformanceMetrics: Bool = AppSettings.load().showPerformanceMetrics {
        didSet {
            var settings = AppSettings.load()
            if settings.showPerformanceMetrics != showPerformanceMetrics {
                settings.showPerformanceMetrics = showPerformanceMetrics
                settings.save()
            }
        }
    }
    @Published public var isAlwaysOnTop: Bool = AppSettings.load().isAlwaysOnTop {
        didSet {
            var settings = AppSettings.load()
            if settings.isAlwaysOnTop != isAlwaysOnTop {
                settings.isAlwaysOnTop = isAlwaysOnTop
                settings.save()
            }
            onWindowLevelChange?(isAlwaysOnTop)
        }
    }
    
    public var onWindowLevelChange: ((Bool) -> Void)?
    
    public init() {}
}
