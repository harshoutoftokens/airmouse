import Foundation
import CoreGraphics
import QuartzCore

/// How a desktop switch is performed.
public enum SpaceSwitchStyle: String, Codable, Sendable, CaseIterable {
    /// Native trackpad slide at normal speed.
    case animated
    /// Native slide, quicker.
    case fast
    /// Lands on the next desktop immediately (InstantSpaceSwitcher technique).
    case instant
    /// Sends the system "Move left/right a space" shortcut (⌃← / ⌃→).
    case keyboard

    var dockSwipeVelocity: Double? {
        switch self {
        case .animated: return 40
        case .fast: return 80
        case .instant: return 2000
        case .keyboard: return nil
        }
    }

    /// How long to wait before checking where we landed.
    var settleTime: TimeInterval {
        switch self {
        case .animated, .keyboard: return 0.9
        case .fast: return 0.6
        case .instant: return 0.35
        }
    }
}

public enum SpaceSwitchResult: Sendable, Equatable {
    case switched(SwipeDirection)
    case blockedAtEdge(SwipeDirection)
    /// The dock-swipe sign convention was inverted on this system; it has been corrected.
    case correctedDirection(SwipeDirection)
    /// The dock swipe did not move the desktop.
    case noEffect(SwipeDirection)
    /// The desktop moved the other way once; corrected after a second consistent observation.
    case unexpectedDirection(SwipeDirection)
    /// Dock swipes stopped working; switched to the keyboard shortcut.
    case fellBackToKeyboard(SwipeDirection)
}

/// Switches desktops by synthesizing the trackpad dock-swipe gesture.
///
/// Encoding notes (from InstantSpaceSwitcher, MIT, which is measured against macOS 26.6.2, and
/// Mac Mouse Fix's notes on Dock behaviour):
/// - Post began → changed → ended back to back on the session tap. Fewer phases breaks
///   switching while Mission Control is open.
/// - Commit comes from *velocity*, not progress. Near-zero progress with velocity 40 gives the
///   normal slide; ~2000 lands instantly. (The previous encoding ended at progress 0.35 with
///   the sign inverted — a partial slide toward the wrong side that then snapped back.)
/// - macOS ≤ 26: positive values move to the desktop on the right.
/// - macOS 27+: the CGEvent gesture fields are ignored; the Dock reads an IOHID payload
///   appended to the serialized event, needs a companion gesture event, and reads the sign
///   through the natural-scrolling preference.
///
/// After an isolated switch the switcher checks which desktop it actually landed on. If it
/// went the wrong way, the sign convention is flipped (persisted per macOS version) and the
/// move is corrected; if dock swipes stop having any effect, it falls back to ⌃←/⌃→.
public final class SpaceSwitcher: @unchecked Sendable {
    public var style: SpaceSwitchStyle {
        get { lock.lock(); defer { lock.unlock() }; return _style }
        set { lock.lock(); _style = newValue; lock.unlock() }
    }
    /// Called on the switcher's queue after every attempt.
    public var onResult: (@Sendable (SpaceSwitchResult) -> Void)?

    private var _style: SpaceSwitchStyle = .animated
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.airtrackpad.spaces", qos: .userInteractive)
    private let defaults: UserDefaults
    private let osMajor: Int

    private var lastSwitchTime: CFTimeInterval = -.infinity
    private var predictedIndex: Int?
    private var predictedDisplay: String?
    private var verifyGeneration = 0
    private var consecutiveNoEffect = 0
    private var inversionEvidence = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    // MARK: - Persistence

    private var signKey: String { "AirTrackpad.dockSwipeSignCorrection.\(osMajor)" }
    private var brokenKey: String { "AirTrackpad.dockSwipeUnavailable.\(osMajor)" }

    /// +1 unless verification found the platform convention inverted on this machine.
    var signCorrection: Double {
        get { defaults.object(forKey: signKey) == nil ? 1.0 : (defaults.double(forKey: signKey) < 0 ? -1.0 : 1.0) }
        set { defaults.set(newValue < 0 ? -1.0 : 1.0, forKey: signKey) }
    }

    /// True once dock swipes were observed to have no effect on this macOS version.
    public var dockSwipeUnavailable: Bool {
        get { defaults.bool(forKey: brokenKey) }
        set { defaults.set(newValue, forKey: brokenKey) }
    }

    /// Forget learned corrections (e.g. from Settings → "Reset").
    public func resetCalibration() {
        defaults.removeObject(forKey: signKey)
        defaults.removeObject(forKey: brokenKey)
    }

    // MARK: - Switching

    public func switchSpace(_ direction: SwipeDirection) {
        guard direction == .left || direction == .right else { return }
        queue.async { [weak self] in self?.performSwitch(direction) }
    }

    private func performSwitch(_ direction: SwipeDirection) {
        let requested = style
        let effectiveStyle: SpaceSwitchStyle = (requested != .keyboard && dockSwipeUnavailable) ? .keyboard : requested
        let now = CACurrentMediaTime()
        let inBurst = now - lastSwitchTime < effectiveStyle.settleTime
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let info = SkyLightSpaces.spaceInfo(at: pointer)

        var current = info?.currentIndex
        if inBurst, let predicted = predictedIndex, predictedDisplay == info?.displayIdentifier {
            // Mid-animation the window server can still report the previous desktop.
            current = predicted
        }
        if let info, let current {
            let blocked = direction == .left ? current <= 0 : current + 1 >= info.count
            if blocked {
                onResult?(.blockedAtEdge(direction))
                return
            }
        }

        post(direction, style: effectiveStyle)
        lastSwitchTime = now
        let step = direction == .right ? 1 : -1
        predictedIndex = current.map { $0 + step }
        predictedDisplay = info?.displayIdentifier
        verifyGeneration += 1

        guard !inBurst, let before = info else {
            onResult?(.switched(direction))
            return
        }
        let generation = verifyGeneration
        queue.asyncAfter(deadline: .now() + effectiveStyle.settleTime) { [weak self] in
            self?.verify(generation: generation, before: before, direction: direction, style: effectiveStyle, pointer: pointer)
        }
    }

    private func verify(generation: Int, before: SpaceInfo, direction: SwipeDirection, style: SpaceSwitchStyle, pointer: CGPoint) {
        guard generation == verifyGeneration,
              let after = SkyLightSpaces.spaceInfo(at: pointer),
              after.displayIdentifier == before.displayIdentifier else {
            onResult?(.switched(direction))
            return
        }
        let expected = direction == .right ? 1 : -1
        let moved = after.currentIndex - before.currentIndex

        if moved == expected {
            consecutiveNoEffect = 0
            inversionEvidence = 0
            onResult?(.switched(direction))
            return
        }
        guard style != .keyboard else {
            onResult?(.noEffect(direction))
            return
        }
        if moved == -expected {
            // Went the opposite way. Persist a sign flip only after two consistent observations,
            // so a manual desktop change inside the settle window can't flip it.
            consecutiveNoEffect = 0
            inversionEvidence += 1
            guard inversionEvidence >= 2 else {
                onResult?(.unexpectedDirection(direction))
                return
            }
            inversionEvidence = 0
            signCorrection = -signCorrection
            post(direction, style: .instant)
            usleep(120_000)
            post(direction, style: style)
            predictedIndex = before.currentIndex + expected
            lastSwitchTime = CACurrentMediaTime()
            onResult?(.correctedDirection(direction))
            return
        }
        if moved == 0 {
            // At the first/last desktop an inverted swipe bounces off the edge and also reads as
            // "no movement" — that's inconclusive, not evidence that dock swipes are broken.
            let invertedWouldHitEdge = direction == .right ? before.currentIndex == 0 : before.currentIndex == before.count - 1
            if invertedWouldHitEdge {
                onResult?(.noEffect(direction))
                return
            }
            consecutiveNoEffect += 1
            if consecutiveNoEffect >= 2 {
                dockSwipeUnavailable = true
                consecutiveNoEffect = 0
                postKeyboard(direction)
                lastSwitchTime = CACurrentMediaTime()
                onResult?(.fellBackToKeyboard(direction))
            } else {
                onResult?(.noEffect(direction))
            }
        }
    }

    // MARK: - Diagnostics

    /// Runs a raw (uncorrected, unverified) switch and reports the Space index before and after.
    /// For the `--diagnose-spaces` launch mode; blocks the calling thread for `wait` seconds.
    public func diagnose(_ direction: SwipeDirection, style: SpaceSwitchStyle, wait: TimeInterval = 1.4) -> String {
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let before = SkyLightSpaces.spaceInfo(at: pointer)
        if let velocity = style.dockSwipeVelocity {
            // Platform convention only (no learned correction): ≤26 positive = right.
            if osMajor >= 27 {
                let sign = SpaceSwitcher.modernSign(direction)
                for phase in [DockPhase.began, .changed, .ended] { DockSwipeEncoder.postModern(phase: phase, sign: sign) }
            } else {
                let sign = direction == .right ? 1.0 : -1.0
                for phase in [DockPhase.began, .changed, .ended] { DockSwipeEncoder.postLegacy(phase: phase, sign: sign, velocity: velocity) }
            }
        } else {
            postKeyboard(direction)
        }
        Thread.sleep(forTimeInterval: wait)
        let after = SkyLightSpaces.spaceInfo(at: pointer)
        let b = before.map { "\($0.currentIndex)/\($0.count)" } ?? "?"
        let a = after.map { "\($0.currentIndex)/\($0.count)" } ?? "?"
        let moved = (before != nil && after != nil) ? after!.currentIndex - before!.currentIndex : 0
        let verdict: String
        switch (direction, moved) {
        case (.right, 1), (.left, -1): verdict = "OK (moved \(direction.rawValue))"
        case (.right, -1), (.left, 1): verdict = "INVERTED (moved the other way)"
        case (_, 0): verdict = "NO EFFECT"
        default: verdict = "moved \(moved)"
        }
        return "\(style.rawValue) \(direction.rawValue): space \(b) → \(a)  \(verdict)"
    }

    // MARK: - Event posting

    private func post(_ direction: SwipeDirection, style: SpaceSwitchStyle) {
        guard let velocity = style.dockSwipeVelocity else {
            postKeyboard(direction)
            return
        }
        if osMajor >= 27 {
            let sign = SpaceSwitcher.modernSign(direction) * signCorrection
            for phase in [DockPhase.began, .changed, .ended] {
                DockSwipeEncoder.postModern(phase: phase, sign: sign)
            }
        } else {
            let sign = (direction == .right ? 1.0 : -1.0) * signCorrection
            for phase in [DockPhase.began, .changed, .ended] {
                DockSwipeEncoder.postLegacy(phase: phase, sign: sign, velocity: velocity)
            }
        }
    }

    /// macOS 27: "right" is negative under natural scrolling and positive without it.
    static func modernSign(_ direction: SwipeDirection) -> Double {
        var valid: DarwinBoolean = false
        let natural = CFPreferencesGetAppBooleanValue(
            "com.apple.swipescrolldirection" as CFString,
            kCFPreferencesAnyApplication,
            &valid
        )
        let isNatural = !valid.boolValue || natural
        let sign = direction == .right ? -1.0 : 1.0
        return isNatural ? sign : -sign
    }

    private func postKeyboard(_ direction: SwipeDirection) {
        let source = CGEventSource(stateID: .privateState)
        let arrow: CGKeyCode = direction == .right ? 124 : 123
        let control: CGKeyCode = 59
        // Matches a physical ⌃+arrow press (arrow keys carry the Fn and keypad flags), which is
        // how the "Move left/right a space" shortcut is registered (modifiers 0x840000).
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        guard let controlDown = CGEvent(keyboardEventSource: source, virtualKey: control, keyDown: true),
              let arrowDown = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: true),
              let arrowUp = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: source, virtualKey: control, keyDown: false) else { return }
        controlDown.flags = .maskControl
        arrowDown.flags = arrowFlags
        arrowUp.flags = arrowFlags
        controlUp.flags = []
        for event in [controlDown, arrowDown, arrowUp, controlUp] {
            event.setIntegerValueField(.eventSourceUserData, value: CGEventInputBackend.eventTag)
            event.post(tap: .cghidEventTap)
            usleep(6_000)
        }
    }
}

enum DockPhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
}

/// Builds synthetic Dock-swipe events.
enum DockSwipeEncoder {
    static func field(_ raw: UInt32) -> CGEventField {
        unsafeBitCast(raw, to: CGEventField.self)
    }

    static let eventType = field(55)          // kCGSEventTypeField
    static let gestureHIDType = field(110)    // kCGEventGestureHIDType
    static let swipeMask = field(115)
    static let swipeMotion = field(123)       // kCGEventGestureSwipeMotion
    static let swipeProgress = field(124)     // kCGEventGestureSwipeProgress
    static let swipePositionX = field(125)
    static let swipePositionY = field(126)
    static let swipeVelocityX = field(129)
    static let swipeVelocityY = field(130)
    static let gesturePhase = field(132)
    static let gesturePhaseAlias = field(134)
    static let zoomDeltaY = field(138)
    static let sourcePIDAlias = field(169)

    static let kCGSEventGesture: Int64 = 29
    static let kCGSEventDockControl: Int64 = 30
    static let kIOHIDEventTypeDockSwipe: Int64 = 23
    static let kGestureMotionHorizontal: Int64 = 1
    /// Smallest non-zero 16.16 fixed-point value: carries direction with nothing to animate.
    static let minimalProgress = 0.000016

    /// macOS ≤ 26 encoding.
    static func makeLegacy(phase: DockPhase, sign: Double, velocity: Double) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(eventType, value: kCGSEventDockControl)
        event.setIntegerValueField(gestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(gesturePhase, value: phase.rawValue)
        event.setDoubleValueField(swipeProgress, value: sign * minimalProgress)
        event.setIntegerValueField(swipeMotion, value: kGestureMotionHorizontal)
        event.setDoubleValueField(swipeVelocityX, value: sign * velocity)
        event.setDoubleValueField(swipeVelocityY, value: sign * velocity)
        return event
    }

    static func postLegacy(phase: DockPhase, sign: Double, velocity: Double) {
        makeLegacy(phase: phase, sign: sign, velocity: velocity)?.post(tap: .cgSessionEventTap)
    }

    /// macOS 27+ encoding (port of InstantSpaceSwitcher's augmented event): the dock-control
    /// event carrying its IOHID payload, plus the companion gesture event the Dock requires.
    static func makeModern(phase: DockPhase, sign: Double) -> (event: CGEvent, companion: CGEvent)? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(eventType, value: kCGSEventDockControl)
        event.setIntegerValueField(gestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(gesturePhase, value: phase.rawValue)
        event.setIntegerValueField(swipeMotion, value: kGestureMotionHorizontal)
        event.setDoubleValueField(swipeProgress, value: sign * minimalProgress)
        event.setIntegerValueField(gesturePhaseAlias, value: phase.rawValue)
        event.setDoubleValueField(zoomDeltaY, value: 3.0)
        event.setDoubleValueField(sourcePIDAlias, value: Double(mach_absolute_time()))
        event.setDoubleValueField(swipePositionX, value: 0.1)
        if phase == .ended {
            // The payload stores velocity as 16.16 fixed point (max ≈ 32767).
            event.setDoubleValueField(swipeVelocityX, value: sign * 9999.0)
        }
        guard let augmented = augment(event),
              let companion = CGEvent(source: nil) else { return nil }
        // The Dock ignores a DockControl event without a companion gesture event.
        companion.setIntegerValueField(eventType, value: kCGSEventGesture)
        return (augmented, companion)
    }

    static func postModern(phase: DockPhase, sign: Double) {
        guard let pair = makeModern(phase: phase, sign: sign) else { return }
        pair.event.post(tap: .cgSessionEventTap)
        pair.companion.post(tap: .cgSessionEventTap)
    }

    // MARK: macOS 27 IOHID payload

    static func fixed1616(_ value: Double) -> Int32 {
        let clamped = max(-32767.0, min(32767.0, value))
        let fixed = Int32(clamped * 65536.0)
        if fixed == 0 && value != 0 {
            return value > 0 ? 1 : -1
        }
        return fixed
    }

    /// Appends the IOHID fluid-touch-gesture (+ velocity) payload macOS 27 expects to the
    /// serialized event and deserializes the result.
    static func augment(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data as Data?, data.count >= 4,
              data[data.startIndex] == 0, data[data.startIndex + 1] == 0,
              data[data.startIndex + 2] == 0, data[data.startIndex + 3] == 2 else { return nil }
        let payload = iohidPayload(for: event)
        var bytes = data
        bytes.append(UInt8((payload.count >> 8) & 0xFF))
        bytes.append(UInt8(payload.count & 0xFF))
        bytes.append(UInt8((4205 >> 8) & 0xFF))
        bytes.append(UInt8(4205 & 0xFF))
        bytes.append(payload)
        return CGEvent(withDataAllocator: nil, data: bytes as CFData)
    }

    static func iohidPayload(for event: CGEvent) -> Data {
        let phase = event.getIntegerValueField(gesturePhase)
        let motion = event.getIntegerValueField(swipeMotion)
        let progress = event.getDoubleValueField(swipeProgress)
        let positionX = event.getDoubleValueField(swipePositionX)
        let positionY = event.getDoubleValueField(swipePositionY)
        let velocityX = event.getDoubleValueField(swipeVelocityX)
        let velocityY = event.getDoubleValueField(swipeVelocityY)
        let mask = event.getIntegerValueField(swipeMask)
        let includeVelocity = velocityX != 0 || velocityY != 0 || phase == DockPhase.ended.rawValue

        var out = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        let timestamp = event.timestamp != 0 ? event.timestamp : mach_absolute_time()
        // IOHIDSystemQueueElementHeader (28 bytes)
        put(UInt64(timestamp))
        put(UInt64(0))                      // sender id
        put(UInt32(0))                      // options
        put(UInt32(0))                      // attribute length
        put(UInt32(includeVelocity ? 2 : 1)) // event count
        // IOHIDFluidTouchGestureData (40 bytes)
        put(UInt32(40))                     // size
        put(UInt32(23))                     // kIOHIDEventTypeFluidTouchGesture
        put(UInt32(UInt32(truncatingIfNeeded: phase & 0xFF) << 24)) // options: phase
        out.append(contentsOf: [0, 0, 0, 0]) // depth + reserved
        put(fixed1616(positionX))
        put(fixed1616(positionY))
        put(Int32(0))
        put(UInt32(truncatingIfNeeded: mask))
        put(UInt16(truncatingIfNeeded: motion))
        put(UInt16(3))                      // kIOHIDGestureFlavorDockPrimary
        put(fixed1616(progress))
        if includeVelocity {
            // IOHIDVelocityEventData (28 bytes)
            put(UInt32(28))
            put(UInt32(9))                  // kIOHIDEventTypeVelocity
            put(UInt32(0))
            out.append(contentsOf: [1, 0, 0, 0]) // depth 1
            put(fixed1616(velocityX))
            put(fixed1616(velocityY))
            put(Int32(0))
        }
        return out
    }
}
