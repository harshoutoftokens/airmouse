import Foundation
import CoreGraphics
import AppKit

/// Posts synthetic input through Quartz Event Services.
///
/// - Every event is posted once, at the HID tap. (Posting to both the HID and session taps
///   delivers it twice: two mouse-downs per click confuse apps and break drags.)
/// - Mouse events come from a HID-state source, so modifier keys physically held on the
///   keyboard still apply (⌘-click, ⇧-click), with local-event suppression disabled so the
///   real trackpad keeps working alongside.
/// - Events are tagged with `eventSourceUserData` so they can be told apart from real input.
public final class CGEventInputBackend: InputBackendProtocol, @unchecked Sendable {
    /// `eventSourceUserData` value on every event AirTrackpad posts ("AIRT").
    public static let eventTag: Int64 = 0x4149_5254

    public let spaceSwitcher: SpaceSwitcher
    private let source: CGEventSource?
    private let lock = NSLock()
    private var isButtonDown = false

    public init(spaceSwitcher: SpaceSwitcher = SpaceSwitcher()) {
        self.spaceSwitcher = spaceSwitcher
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        self.source = source
    }

    public func currentPointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Pointer

    public func moveCursor(to point: CGPoint, delta: CGVector, buttonDown: Bool) {
        // Warping first keeps the reported location in sync for the next relative step; the
        // event then updates hover state, tooltips and Dock magnification.
        CGWarpMouseCursorPosition(point)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: buttonDown ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.dy.rounded()))
        post(event)
    }

    public func mouseDown(at point: CGPoint, clickCount: Int) {
        lock.lock()
        isButtonDown = true
        lock.unlock()
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        post(event)
    }

    public func mouseUp(at point: CGPoint, clickCount: Int) {
        lock.lock()
        isButtonDown = false
        lock.unlock()
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        post(event)
    }

    public func rightClick(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        post(down)
        usleep(12_000)
        post(up)
    }

    // MARK: - Scrolling

    public func scroll(deltaX: Double, deltaY: Double, phase: ScrollEventPhase, momentumPhase: ScrollMomentumPhase) {
        let wheelY = Int32(clamping: Int(deltaY.rounded()))
        let wheelX = Int32(clamping: Int(deltaX.rounded()))
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheelY,
            wheel2: wheelX,
            wheel3: 0
        ) else { return }
        // Continuous + gesture/momentum phases is what a trackpad sends; apps use it for
        // rubber-banding, inertia and swipe-between-pages.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase.rawValue)
        post(event)
    }

    // MARK: - Desktops & Mission Control

    public func switchSpace(direction: SwipeDirection) {
        spaceSwitcher.switchSpace(direction)
    }

    public func beginDesktopSwipe() {
        spaceSwitcher.beginInteractive()
    }

    public func updateDesktopSwipe(progress: Double) {
        spaceSwitcher.updateInteractive(progress: progress)
    }

    public func endDesktopSwipe(progress: Double, commit: Bool) {
        spaceSwitcher.endInteractive(progress: progress, commit: commit)
    }

    public func triggerMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    // MARK: - Safety

    public func emergencyRelease() {
        lock.lock()
        let wasDown = isButtonDown
        isButtonDown = false
        lock.unlock()
        guard wasDown else { return }
        let position = currentPointerLocation()
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left) {
            post(up)
        }
    }
}
