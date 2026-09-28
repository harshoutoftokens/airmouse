import Foundation

/// Central persistent user settings for AirTrackpad.
public struct AppSettings: Codable, Sendable {
    // Cursor settings
    public var cursorSensitivity: Double = 1.0
    public var cursorAcceleration: Double = 1.15
    public var cursorDeadzonePixels: Double = 1.2
    public var filterMinCutoff: Double = 1.0
    public var filterBeta: Double = 0.007
    
    // Pinch / Click / Drag settings
    public var pinchStartThreshold: Double = 0.22
    public var pinchReleaseThreshold: Double = 0.30
    public var clickMaxDuration: Double = 0.35
    public var dragHoldDelay: Double = 0.35
    public var clickCooldown: Double = 0.25
    
    // 4-Finger Swipe settings
    public var swipeMinDisplacement: Double = 0.09
    public var swipeMinVelocity: Double = 0.15
    public var swipeMaxDuration: Double = 0.85
    public var swipeCooldown: Double = 0.40
    
    // 5-Finger Mission Control settings
    public var fiveFingerPinchThreshold: Double = 0.22
    public var fiveFingerOpenThreshold: Double = 0.48
    public var fiveFingerMaxSequenceDuration: Double = 1.20
    public var missionControlCooldown: Double = 0.60
    
    // Camera settings
    public var targetFPS: Int32 = 60
    public var mirrorsHorizontal: Bool = true
    
    // Calibration bounds
    public var calibMinX: Double = 0.15
    public var calibMaxX: Double = 0.85
    public var calibMinY: Double = 0.15
    public var calibMaxY: Double = 0.85
    
    public init() {}
    
    private static let userDefaultsKey = "com.airtrackpad.settings"
    
    public static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        if settings.swipeMaxDuration < 0.60 {
            settings.swipeMaxDuration = 0.85
        }
        if settings.swipeMinVelocity > 0.30 {
            settings.swipeMinVelocity = 0.15
        }
        if settings.swipeMinDisplacement > 0.12 {
            settings.swipeMinDisplacement = 0.09
        }
        return settings
    }
    
    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.userDefaultsKey)
        }
    }
}
