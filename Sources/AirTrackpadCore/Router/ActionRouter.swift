import Foundation
import CoreGraphics
import QuartzCore

/// Dispatches abstract gesture events to the input backend while enforcing safety invariants.
///
/// With `smoothing` on (the live app), events go through an output stage on its own queue:
/// - Pointer motion arrives at camera rate (30 fps) but is eased out at ~125 Hz, so the
///   pointer glides instead of stepping, for ~12 ms of extra latency.
/// - Motion is applied relative to wherever the pointer actually is, so a physical mouse or
///   trackpad can be used at the same time without the two fighting.
/// - Scrolling is posted as continuous trackpad-style events with gesture phases, followed by
///   momentum after the hand stops — which gives apps rubber-banding and inertia.
/// - Clicks and button changes first flush pending motion so they land exactly under the pointer.
///
/// With `smoothing` off (tests, replay), everything is applied synchronously and deterministically.
public final class ActionRouter: @unchecked Sendable {
    public let backend: InputBackendProtocol
    public let smoothing: Bool

    private let queue = DispatchQueue(label: "com.airtrackpad.output", qos: .userInteractive)
    private let stateLock = NSLock()
    private var enabled = true
    private var _layout = DisplayLayout(displays: [])
    private var _momentumEnabled = true

    // Output state. Confined to `queue` when smoothing, to the caller otherwise.
    private var timer: DispatchSourceTimer?
    private var lastTick: CFTimeInterval = 0
    private var idleTicks = 0
    private var pendingMotion = CGVector.zero
    private var absoluteTarget: CGPoint?
    private var leftDown = false
    private var clickInFlight = false

    private var scrollActive = false
    private var scrollStarted = false
    private var scrollEndRequested = false
    private var scrollPendingX = 0.0
    private var scrollPendingY = 0.0
    private var scrollVelocityX = 0.0
    private var scrollVelocityY = 0.0
    private var scrollFractionX = 0.0
    private var scrollFractionY = 0.0
    private var momentumActive = false
    private var momentumStarted = false
    private var momentumVX = 0.0
    private var momentumVY = 0.0

    /// Pointer easing time constant.
    private let pointerTau: Double = 0.012
    /// Scroll easing time constant.
    private let scrollTau: Double = 0.030
    /// Momentum decay time constant (≈ trackpad inertia).
    private let momentumTau: Double = 0.33

    public init(backend: InputBackendProtocol, smoothing: Bool = false) {
        self.backend = backend
        self.smoothing = smoothing
    }

    public var layout: DisplayLayout {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _layout }
        set { stateLock.lock(); _layout = newValue; stateLock.unlock() }
    }

    public var momentumEnabled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _momentumEnabled }
        set { stateLock.lock(); _momentumEnabled = newValue; stateLock.unlock() }
    }

    public func setEnabled(_ isEnabled: Bool) {
        stateLock.lock()
        enabled = isEnabled
        stateLock.unlock()
        if !isEnabled {
            emergencyStop()
        }
    }

    public func handle(event: AbstractGestureEvent) {
        stateLock.lock()
        let isEnabled = enabled
        stateLock.unlock()
        guard isEnabled else { return }

        if smoothing {
            queue.async { [weak self] in self?.apply(event) }
        } else {
            apply(event)
        }
    }

    /// Releases any held button and stops motion / scrolling immediately.
    public func emergencyStop() {
        if smoothing {
            queue.sync { self.stopEverything() }
        } else {
            stopEverything()
        }
    }

    /// Waits until queued events have been applied (smoothing mode). Test hook.
    public func waitUntilIdle() {
        if smoothing {
            queue.sync {}
        }
    }

    // MARK: - Event application

    private func apply(_ event: AbstractGestureEvent) {
        // Re-check on the output queue: events queued before a stop must not post afterwards.
        stateLock.lock()
        let isEnabled = enabled
        stateLock.unlock()
        guard isEnabled else { return }
        
        switch event {
        case .pointerDelta(let dx, let dy):
            absoluteTarget = nil
            if smoothing {
                pendingMotion.dx += dx
                pendingMotion.dy += dy
                startTimer()
            } else {
                movePointer(by: CGVector(dx: dx, dy: dy))
            }

        case .pointerWarp(let target):
            if smoothing {
                pendingMotion = .zero
                absoluteTarget = target
                startTimer()
            } else {
                let current = backend.currentPointerLocation()
                movePointer(by: CGVector(dx: target.x - current.x, dy: target.y - current.y))
            }

        case .leftClick(let count):
            stopMomentum()
            flushPointer()
            let point = backend.currentPointerLocation()
            backend.mouseDown(at: point, clickCount: count)
            if smoothing {
                // A short, realistic hold without blocking the output queue.
                leftDown = true
                clickInFlight = true
                queue.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    guard let self, self.clickInFlight else { return }
                    self.clickInFlight = false
                    self.leftDown = false
                    self.backend.mouseUp(at: self.backend.currentPointerLocation(), clickCount: count)
                }
            } else {
                backend.mouseUp(at: point, clickCount: count)
            }

        case .leftMouseDown:
            stopMomentum()
            finishPendingClick()
            flushPointer()
            leftDown = true
            backend.mouseDown(at: backend.currentPointerLocation(), clickCount: 1)

        case .leftMouseUp:
            finishPendingClick()
            flushPointer()
            if leftDown {
                leftDown = false
                backend.mouseUp(at: backend.currentPointerLocation(), clickCount: 1)
            }

        case .rightClick:
            stopMomentum()
            flushPointer()
            backend.rightClick(at: backend.currentPointerLocation())

        case .scroll(let dx, let dy, let phase):
            handleScroll(dx: dx, dy: dy, phase: phase)
            
        case .cancelMomentum:
            stopMomentum()

        case .switchSpace(let direction):
            backend.switchSpace(direction: direction)

        case .triggerMissionControl:
            backend.triggerMissionControl()

        case .emergencyStop, .trackingPaused:
            stopEverything()

        case .trackingResumed:
            break
        }
    }

    private func movePointer(by delta: CGVector) {
        guard abs(delta.dx) > 1e-6 || abs(delta.dy) > 1e-6 else { return }
        let current = backend.currentPointerLocation()
        let target = layout.clamp(CGPoint(x: current.x + delta.dx, y: current.y + delta.dy))
        backend.moveCursor(
            to: target,
            delta: CGVector(dx: target.x - current.x, dy: target.y - current.y),
            buttonDown: leftDown
        )
    }

    private func flushPointer() {
        if let target = absoluteTarget {
            let current = backend.currentPointerLocation()
            movePointer(by: CGVector(dx: target.x - current.x, dy: target.y - current.y))
            absoluteTarget = nil
        }
        if abs(pendingMotion.dx) > 1e-6 || abs(pendingMotion.dy) > 1e-6 {
            movePointer(by: pendingMotion)
            pendingMotion = .zero
        }
    }

    private func finishPendingClick() {
        guard clickInFlight else { return }
        clickInFlight = false
        leftDown = false
        backend.mouseUp(at: backend.currentPointerLocation(), clickCount: 1)
    }

    // MARK: - Scrolling

    private func handleScroll(dx: Double, dy: Double, phase: ScrollPhase) {
        if !smoothing {
            switch phase {
            case .began:
                scrollActive = true
                backend.scroll(deltaX: dx, deltaY: dy, phase: .began, momentumPhase: .none)
            case .changed:
                backend.scroll(deltaX: dx, deltaY: dy, phase: scrollActive ? .changed : .began, momentumPhase: .none)
                scrollActive = true
            case .ended:
                if scrollActive {
                    backend.scroll(deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: .none)
                }
                scrollActive = false
            }
            return
        }

        switch phase {
        case .began, .changed:
            if momentumActive {
                endMomentum()
            }
            if !scrollActive {
                scrollActive = true
                scrollStarted = false
                scrollVelocityX = 0
                scrollVelocityY = 0
            }
            scrollEndRequested = false
            scrollPendingX += dx
            scrollPendingY += dy
            startTimer()
        case .ended:
            if scrollActive {
                scrollEndRequested = true
                startTimer()
            }
        }
    }

    /// Posts a scroll step, carrying sub-pixel remainders so slow scrolling stays smooth.
    private func postScroll(dx: Double, dy: Double, phase: ScrollEventPhase, momentum: ScrollMomentumPhase, force: Bool = false) -> Bool {
        scrollFractionX += dx
        scrollFractionY += dy
        let ix = scrollFractionX.rounded(.towardZero)
        let iy = scrollFractionY.rounded(.towardZero)
        guard force || ix != 0 || iy != 0 else { return false }
        scrollFractionX -= ix
        scrollFractionY -= iy
        backend.scroll(deltaX: ix, deltaY: iy, phase: phase, momentumPhase: momentum)
        return true
    }

    private func stopMomentum() {
        if momentumActive {
            endMomentum()
        }
    }
    
    private func endMomentum() {
        if momentumStarted {
            _ = postScroll(dx: 0, dy: 0, phase: .none, momentum: .end, force: true)
        }
        momentumActive = false
        momentumStarted = false
        momentumVX = 0
        momentumVY = 0
    }

    // MARK: - Output timer

    private func startTimer() {
        idleTicks = 0
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .microseconds(500))
        source.setEventHandler { [weak self] in self?.tick() }
        lastTick = CACurrentMediaTime()
        timer = source
        source.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(0.001, min(now - lastTick, 0.05))
        lastTick = now
        var busy = false

        // Pointer easing
        if let target = absoluteTarget {
            let current = backend.currentPointerLocation()
            pendingMotion = CGVector(dx: target.x - current.x, dy: target.y - current.y)
            if hypot(pendingMotion.dx, pendingMotion.dy) < 0.5 {
                absoluteTarget = nil
            }
        }
        let remaining = hypot(pendingMotion.dx, pendingMotion.dy)
        if remaining > 0.01 {
            let k = 1.0 - exp(-dt / pointerTau)
            let step = remaining < 0.6
                ? pendingMotion
                : CGVector(dx: pendingMotion.dx * k, dy: pendingMotion.dy * k)
            pendingMotion.dx -= step.dx
            pendingMotion.dy -= step.dy
            movePointer(by: step)
            busy = true
        } else {
            pendingMotion = .zero
        }

        // Scroll easing
        if scrollActive {
            busy = true
            let k = 1.0 - exp(-dt / scrollTau)
            var sx = scrollPendingX * k
            var sy = scrollPendingY * k
            if abs(scrollPendingX) < 0.5 { sx = scrollPendingX }
            if abs(scrollPendingY) < 0.5 { sy = scrollPendingY }
            if scrollEndRequested {
                sx = scrollPendingX
                sy = scrollPendingY
            }
            scrollPendingX -= sx
            scrollPendingY -= sy
            if sx != 0 || sy != 0 {
                let phase: ScrollEventPhase = scrollStarted ? .changed : .began
                if postScroll(dx: sx, dy: sy, phase: phase, momentum: .none) {
                    scrollStarted = true
                }
            }
            scrollVelocityX = 0.75 * scrollVelocityX + 0.25 * (sx / dt)
            scrollVelocityY = 0.75 * scrollVelocityY + 0.25 * (sy / dt)

            if scrollEndRequested {
                if scrollStarted {
                    _ = postScroll(dx: 0, dy: 0, phase: .ended, momentum: .none, force: true)
                }
                scrollActive = false
                scrollStarted = false
                scrollEndRequested = false
                scrollFractionX = 0
                scrollFractionY = 0
                let speed = hypot(scrollVelocityX, scrollVelocityY)
                if momentumEnabled && speed > 120 {
                    momentumActive = true
                    momentumStarted = false
                    momentumVX = scrollVelocityX
                    momentumVY = scrollVelocityY
                }
            }
        } else if momentumActive {
            busy = true
            let decay = exp(-dt / momentumTau)
            momentumVX *= decay
            momentumVY *= decay
            if hypot(momentumVX, momentumVY) < 25 {
                endMomentum()
            } else {
                let phase: ScrollMomentumPhase = momentumStarted ? .continue : .begin
                if postScroll(dx: momentumVX * dt, dy: momentumVY * dt, phase: .none, momentum: phase) {
                    momentumStarted = true
                }
            }
        }

        if busy {
            idleTicks = 0
        } else {
            idleTicks += 1
            if idleTicks > 60 {
                stopTimer()
            }
        }
    }

    // MARK: - Safety

    private func stopEverything() {
        pendingMotion = .zero
        absoluteTarget = nil
        if scrollActive && (scrollStarted || !smoothing) {
            backend.scroll(deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: .none)
        }
        scrollActive = false
        scrollStarted = false
        scrollEndRequested = false
        scrollPendingX = 0
        scrollPendingY = 0
        if momentumActive {
            endMomentum()
        }
        let wasDown = leftDown || clickInFlight
        clickInFlight = false
        leftDown = false
        if wasDown {
            backend.mouseUp(at: backend.currentPointerLocation(), clickCount: 1)
        }
        backend.emergencyRelease()
    }
}
