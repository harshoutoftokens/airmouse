import Foundation

/// Central persistent user settings for AirTrackpad.
public struct AppSettings: Codable, Sendable, Equatable {
    /// Bump when tuning defaults change enough that stored values should be replaced.
    public static let currentVersion = 2
    public static let didChangeNotification = Notification.Name("com.airtrackpad.settingsDidChange")

    public var settingsVersion: Int = AppSettings.currentVersion

    // MARK: Cursor
    public var cursorMode: CursorMode = .relative
    /// Trackpad mode pointer speed multiplier.
    public var pointerSpeed: Double = 1.0
    /// 0 = linear, 1 = strong acceleration.
    public var pointerAcceleration: Double = 0.7
    /// 0 = most responsive, 1 = steadiest.
    public var cursorSmoothing: Double = 0.5
    /// Direct mode: zooms the calibration box (higher = less hand travel per screen).
    public var cursorSensitivity: Double = 1.0
    /// Direct mode calibration box for the knuckle anchor (normalized camera coordinates).
    public var calibMinX: Double = 0.25
    public var calibMaxX: Double = 0.75
    public var calibMinY: Double = 0.22
    public var calibMaxY: Double = 0.68

    // MARK: Click & drag
    public var pinchStartThreshold: Double = 0.22
    public var pinchReleaseThreshold: Double = 0.32
    public var dragHoldDelay: Double = 0.45
    public var rightClickEnabled: Bool = true

    // MARK: Scroll
    public var scrollEnabled: Bool = true
    public var scrollSensitivity: Double = 1.0
    public var naturalScrolling: Bool = true
    public var scrollMomentum: Bool = true

    // MARK: Desktop swipe
    public var swipeEnabled: Bool = true
    /// Higher = shorter / slower strokes still count.
    public var swipeSensitivity: Double = 1.0
    public var naturalSwipeDirection: Bool = false
    public var spaceSwitchStyle: SpaceSwitchStyle = .instant

    // MARK: Mission Control
    public var missionControlEnabled: Bool = true
    public var fiveFingerPinchThreshold: Double = 0.22
    public var fiveFingerOpenThreshold: Double = 0.40

    // MARK: App behaviour
    /// nil = automatic (prefers the built-in camera).
    public var cameraDeviceID: String? = nil
    public var mirrorsHorizontal: Bool = true
    public var pauseWhileTyping: Bool = true
    public var showCursorFeedback: Bool = true
    public var showHUDAtLaunch: Bool = true

    // MARK: Debug HUD
    public var showCameraFeed: Bool = false
    public var showPerformanceMetrics: Bool = true
    public var isAlwaysOnTop: Bool = false

    public init() {}

    // MARK: - Derived engine configuration

    public func gestureConfig(doubleClickInterval: TimeInterval = 0.5) -> GestureConfig {
        var c = GestureConfig()
        c.pinchPressThreshold = pinchStartThreshold
        c.pinchReleaseThreshold = max(pinchReleaseThreshold, pinchStartThreshold + 0.05)
        c.dragHoldDelay = dragHoldDelay
        c.doubleClickInterval = doubleClickInterval
        c.rightClickEnabled = rightClickEnabled
        c.scrollEnabled = scrollEnabled
        c.scrollSensitivity = scrollSensitivity
        c.naturalScrolling = naturalScrolling
        c.swipeEnabled = swipeEnabled
        let sensitivity = max(0.5, min(2.0, swipeSensitivity))
        c.swipeFullDistance = 1.5 / sensitivity
        c.naturalSwipeDirection = naturalSwipeDirection
        c.missionControlEnabled = missionControlEnabled
        c.fiveFingerPinchThreshold = fiveFingerPinchThreshold
        c.fiveFingerOpenThreshold = max(fiveFingerOpenThreshold, fiveFingerPinchThreshold + 0.1)
        return c
    }

    /// Applies cursor-related settings to an engine.
    public func configure(_ cursor: CursorEngine) {
        cursor.mode = cursorMode
        cursor.acceleration = PointerAcceleration(speed: pointerSpeed, acceleration: pointerAcceleration)
        let s = max(0.0, min(1.0, cursorSmoothing))
        cursor.filter.minCutoff = 2.4 + (0.7 - 2.4) * s
        cursor.filter.beta = 1.8 + (0.7 - 1.8) * s
        cursor.restSpeed = 0.05 + (0.12 - 0.05) * s
        cursor.mapper.minX = calibMinX
        cursor.mapper.maxX = calibMaxX
        cursor.mapper.minY = calibMinY
        cursor.mapper.maxY = calibMaxY
        cursor.mapper.sensitivity = max(0.5, min(3.0, cursorSensitivity))
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "com.airtrackpad.settings"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AppSettings.userDefaultsKey)
        NotificationCenter.default.post(name: AppSettings.didChangeNotification, object: nil)
    }

    // MARK: - Codable (tolerant of missing keys; migrates old tuning)

    private enum CodingKeys: String, CodingKey {
        case settingsVersion
        case cursorMode, pointerSpeed, pointerAcceleration, cursorSmoothing, cursorSensitivity
        case calibMinX, calibMaxX, calibMinY, calibMaxY
        case pinchStartThreshold, pinchReleaseThreshold, dragHoldDelay, rightClickEnabled
        case scrollEnabled, scrollSensitivity, naturalScrolling, scrollMomentum
        case swipeEnabled, swipeSensitivity, naturalSwipeDirection, spaceSwitchStyle
        case missionControlEnabled, fiveFingerPinchThreshold, fiveFingerOpenThreshold
        case cameraDeviceID, mirrorsHorizontal, pauseWhileTyping, showCursorFeedback, showHUDAtLaunch
        case showCameraFeed, showPerformanceMetrics, isAlwaysOnTop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        // One unreadable field (e.g. an enum value from a newer version) falls back to its
        // default instead of discarding every setting.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let version = value(.settingsVersion, 1)

        // Preferences that mean the same thing in every version are always kept.
        mirrorsHorizontal = value(.mirrorsHorizontal, d.mirrorsHorizontal)
        showCameraFeed = value(.showCameraFeed, d.showCameraFeed)
        showPerformanceMetrics = value(.showPerformanceMetrics, d.showPerformanceMetrics)
        isAlwaysOnTop = value(.isAlwaysOnTop, d.isAlwaysOnTop)

        guard version >= AppSettings.currentVersion else {
            // Version 1 tuning targeted the old fingertip / absolute pipeline; start from the
            // new defaults instead of carrying those numbers over.
            settingsVersion = AppSettings.currentVersion
            return
        }
        settingsVersion = version
        cursorMode = value(.cursorMode, d.cursorMode)
        pointerSpeed = value(.pointerSpeed, d.pointerSpeed)
        pointerAcceleration = value(.pointerAcceleration, d.pointerAcceleration)
        cursorSmoothing = value(.cursorSmoothing, d.cursorSmoothing)
        cursorSensitivity = value(.cursorSensitivity, d.cursorSensitivity)
        calibMinX = value(.calibMinX, d.calibMinX)
        calibMaxX = value(.calibMaxX, d.calibMaxX)
        calibMinY = value(.calibMinY, d.calibMinY)
        calibMaxY = value(.calibMaxY, d.calibMaxY)
        pinchStartThreshold = value(.pinchStartThreshold, d.pinchStartThreshold)
        pinchReleaseThreshold = value(.pinchReleaseThreshold, d.pinchReleaseThreshold)
        dragHoldDelay = value(.dragHoldDelay, d.dragHoldDelay)
        rightClickEnabled = value(.rightClickEnabled, d.rightClickEnabled)
        scrollEnabled = value(.scrollEnabled, d.scrollEnabled)
        scrollSensitivity = value(.scrollSensitivity, d.scrollSensitivity)
        naturalScrolling = value(.naturalScrolling, d.naturalScrolling)
        scrollMomentum = value(.scrollMomentum, d.scrollMomentum)
        swipeEnabled = value(.swipeEnabled, d.swipeEnabled)
        swipeSensitivity = value(.swipeSensitivity, d.swipeSensitivity)
        naturalSwipeDirection = value(.naturalSwipeDirection, d.naturalSwipeDirection)
        spaceSwitchStyle = value(.spaceSwitchStyle, d.spaceSwitchStyle)
        missionControlEnabled = value(.missionControlEnabled, d.missionControlEnabled)
        fiveFingerPinchThreshold = value(.fiveFingerPinchThreshold, d.fiveFingerPinchThreshold)
        fiveFingerOpenThreshold = value(.fiveFingerOpenThreshold, d.fiveFingerOpenThreshold)
        cameraDeviceID = (try? c.decodeIfPresent(String.self, forKey: .cameraDeviceID)) ?? nil
        pauseWhileTyping = value(.pauseWhileTyping, d.pauseWhileTyping)
        showCursorFeedback = value(.showCursorFeedback, d.showCursorFeedback)
        showHUDAtLaunch = value(.showHUDAtLaunch, d.showHUDAtLaunch)
    }
}
