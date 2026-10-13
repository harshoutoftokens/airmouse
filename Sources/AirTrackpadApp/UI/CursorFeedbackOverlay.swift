import AppKit
import AirTrackpadCore

/// What the pointer feedback ring shows.
public enum CursorFeedback: Equatable, Sendable {
    case hidden
    /// Pointing; `progress` 0…1 shrinks the ring as a pinch closes.
    case tracking(progress: Double)
    case pressed
    case dragging
    case scrolling
    case openHand
}

/// Brief confirmation animations.
public struct CursorFlash: Sendable {
    public enum Kind: Sendable {
        case swipeLeft, swipeRight, missionControl, blocked
    }
    public var kind: Kind
    public var date: Date
}

/// Click-through ring that follows the pointer and mirrors gesture state.
///
/// Air gestures have no physical click, so seeing the ring tighten as the fingers close —
/// and snap solid when the press registers — is what makes pinching feel dependable.
@MainActor
final class CursorFeedbackOverlay {
    private let appState: AppState
    private let panel: NSPanel
    private let ringView = FeedbackRingView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    private var timer: Timer?
    private(set) var isEnabled = false

    init(appState: AppState) {
        self.appState = appState
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = ringView
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
        }
    }

    private func tick() {
        var flash: CursorFlash?
        if let f = appState.feedbackFlash {
            if Date().timeIntervalSince(f.date) < FeedbackRingView.flashDuration {
                flash = f
            } else {
                appState.feedbackFlash = nil
            }
        }
        let state = appState.isPaused ? .hidden : appState.feedback
        guard state != .hidden || flash != nil else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2))
        ringView.update(state: state, flash: flash)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

final class FeedbackRingView: NSView {
    static let flashDuration: TimeInterval = 0.45

    private var state: CursorFeedback = .hidden
    private var flash: CursorFlash?

    override var isFlipped: Bool { false }

    func update(state: CursorFeedback, flash: CursorFlash?) {
        let changed = state != self.state || flash != nil || self.flash != nil
        self.state = state
        self.flash = flash
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let accent = NSColor.controlAccentColor

        switch state {
        case .hidden:
            break
        case .tracking(let progress):
            let p = max(0.0, min(1.0, progress))
            let radius = 15.0 - 7.0 * p
            ring(center, radius: radius, width: 1.6 + 1.2 * p, color: NSColor.white.withAlphaComponent(0.75 + 0.25 * p))
            if p > 0.05 {
                disc(center, radius: radius * p * 0.8, color: accent.withAlphaComponent(0.35 + 0.4 * p))
            }
        case .pressed:
            ring(center, radius: 8, width: 3, color: accent)
            disc(center, radius: 5, color: accent)
        case .dragging:
            ring(center, radius: 11, width: 3.5, color: accent)
            disc(center, radius: 4, color: accent)
        case .scrolling:
            ring(center, radius: 13, width: 1.6, color: NSColor.white.withAlphaComponent(0.8))
            chevron(center: NSPoint(x: center.x, y: center.y + 20), pointingUp: true, size: 6)
            chevron(center: NSPoint(x: center.x, y: center.y - 20), pointingUp: false, size: 6)
        case .openHand:
            let dash = NSBezierPath(ovalIn: NSRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))
            dash.lineWidth = 1.5
            dash.setLineDash([4, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.7).setStroke()
            withShadow { dash.stroke() }
        }

        if let flash {
            let t = Date().timeIntervalSince(flash.date) / FeedbackRingView.flashDuration
            let alpha = max(0.0, 1.0 - t)
            switch flash.kind {
            case .swipeLeft:
                arrow(center, toRight: false, offset: 10 + 18 * t, alpha: alpha)
            case .swipeRight:
                arrow(center, toRight: true, offset: 10 + 18 * t, alpha: alpha)
            case .missionControl:
                let side = 10.0 + 8 * t
                for dx in [-1.0, 1.0] {
                    for dy in [-1.0, 1.0] {
                        let r = NSRect(x: center.x + dx * side - 6, y: center.y + dy * side - 4.5, width: 12, height: 9)
                        let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
                        NSColor.white.withAlphaComponent(alpha).setFill()
                        withShadow { path.fill() }
                    }
                }
            case .blocked:
                ring(center, radius: 16 + 6 * t, width: 3, color: NSColor.systemRed.withAlphaComponent(alpha))
            }
        }
    }

    private func withShadow(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func ring(_ c: NSPoint, radius: Double, width: Double, color: NSColor) {
        let path = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        path.lineWidth = width
        color.setStroke()
        withShadow { path.stroke() }
    }

    private func disc(_ c: NSPoint, radius: Double, color: NSColor) {
        guard radius > 0.3 else { return }
        let path = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        color.setFill()
        withShadow { path.fill() }
    }

    private func chevron(center c: NSPoint, pointingUp: Bool, size s: Double) {
        let path = NSBezierPath()
        let dir = pointingUp ? 1.0 : -1.0
        path.move(to: NSPoint(x: c.x - s, y: c.y - dir * s * 0.5))
        path.line(to: NSPoint(x: c.x, y: c.y + dir * s * 0.5))
        path.line(to: NSPoint(x: c.x + s, y: c.y - dir * s * 0.5))
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        withShadow { path.stroke() }
    }

    private func arrow(_ c: NSPoint, toRight: Bool, offset: Double, alpha: Double) {
        let dir = toRight ? 1.0 : -1.0
        let tip = NSPoint(x: c.x + dir * (offset + 12), y: c.y)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: tip.x - dir * 10, y: tip.y + 10))
        path.line(to: tip)
        path.line(to: NSPoint(x: tip.x - dir * 10, y: tip.y - 10))
        path.move(to: tip)
        path.line(to: NSPoint(x: tip.x - dir * 24, y: tip.y))
        path.lineWidth = 3.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(alpha).setStroke()
        withShadow { path.stroke() }
    }
}
