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
    
    public init() {}
}
