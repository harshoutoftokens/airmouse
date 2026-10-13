import XCTest
@testable import AirTrackpadCore

final class ActionRouterTests: XCTestCase {
    private func makeRouter(pointer: CGPoint = CGPoint(x: 500, y: 400)) -> (ActionRouter, MockInputBackend) {
        let backend = MockInputBackend(pointer: pointer)
        let router = ActionRouter(backend: backend)
        router.layout = DisplayLayout(displays: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        return (router, backend)
    }

    func testPointerDeltaMovesRelativeToCurrentPosition() {
        let (router, backend) = makeRouter()
        router.handle(event: .pointerDelta(dx: 10, dy: -5))
        XCTAssertEqual(backend.pointer, CGPoint(x: 510, y: 395))
    }

    func testPointerIsClampedToDisplays() {
        let (router, backend) = makeRouter(pointer: CGPoint(x: 990, y: 10))
        router.handle(event: .pointerDelta(dx: 50, dy: -50))
        XCTAssertLessThan(backend.pointer.x, 1000)
        XCTAssertGreaterThanOrEqual(backend.pointer.y, 0)
    }

    func testMovesBecomeDragsWhileButtonHeld() {
        let (router, backend) = makeRouter()
        router.handle(event: .leftMouseDown)
        router.handle(event: .pointerDelta(dx: 5, dy: 0))
        router.handle(event: .leftMouseUp)
        XCTAssertEqual(backend.mouseEvents, ["down", "drag", "up"])
        XCTAssertFalse(backend.isMouseDown)
    }

    func testDoubleClickCarriesClickCount() {
        let (router, backend) = makeRouter()
        router.handle(event: .leftClick(count: 1))
        router.handle(event: .leftClick(count: 2))
        XCTAssertEqual(backend.clicks.map(\.count), [1, 2])
    }

    func testScrollPhasesPassThrough() {
        let (router, backend) = makeRouter()
        router.handle(event: .scroll(deltaX: 0, deltaY: -12, phase: .began))
        router.handle(event: .scroll(deltaX: 0, deltaY: -8, phase: .changed))
        router.handle(event: .scroll(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(backend.scrollEvents.map(\.phase), [.began, .changed, .ended])
    }

    func testEmergencyStopReleasesHeldButton() {
        let (router, backend) = makeRouter()
        router.handle(event: .leftMouseDown)
        router.emergencyStop()
        XCTAssertFalse(backend.isMouseDown)
        XCTAssertTrue(backend.mouseEvents.contains("up"))
    }

    func testDisabledRouterIgnoresEvents() {
        let (router, backend) = makeRouter()
        router.setEnabled(false)
        router.handle(event: .leftClick(count: 1))
        XCTAssertTrue(backend.clicks.isEmpty)
    }

    func testSmoothedOutputDeliversFullMotion() {
        let backend = MockInputBackend(pointer: CGPoint(x: 500, y: 400))
        let router = ActionRouter(backend: backend, smoothing: true)
        router.layout = DisplayLayout(displays: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        router.handle(event: .pointerDelta(dx: 60, dy: 30))
        let done = expectation(description: "eased into place")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { done.fulfill() }
        wait(for: [done], timeout: 1.0)
        router.waitUntilIdle()
        XCTAssertEqual(Double(backend.pointer.x), 560, accuracy: 0.6)
        XCTAssertEqual(Double(backend.pointer.y), 430, accuracy: 0.6)
        XCTAssertGreaterThan(backend.cursorPositions.count, 2, "motion is spread over several output frames")
    }

    func testSmoothedClickFlushesPendingMotionFirst() {
        let backend = MockInputBackend(pointer: CGPoint(x: 500, y: 400))
        let router = ActionRouter(backend: backend, smoothing: true)
        router.layout = DisplayLayout(displays: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        router.handle(event: .pointerDelta(dx: 40, dy: 0))
        router.handle(event: .leftClick(count: 1))
        let done = expectation(description: "click completes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 1.0)
        router.waitUntilIdle()
        XCTAssertEqual(backend.clicks.count, 1)
        XCTAssertEqual(Double(backend.clicks.first?.point.x ?? 0), 540, accuracy: 0.6)
    }
}

final class DisplayLayoutTests: XCTestCase {
    // Mirrors a MacBook with an external display arranged above it.
    let layout = DisplayLayout(displays: [
        CGRect(x: 0, y: 0, width: 1470, height: 956),
        CGRect(x: 897, y: -768, width: 1366, height: 768)
    ])

    func testPointsOnAnyDisplayAreKept() {
        XCTAssertEqual(layout.clamp(CGPoint(x: 100, y: 100)), CGPoint(x: 100, y: 100))
        XCTAssertEqual(layout.clamp(CGPoint(x: 1500, y: -300)), CGPoint(x: 1500, y: -300))
    }

    func testPointerCanCrossOntoTheUpperDisplay() {
        let p = layout.clamp(CGPoint(x: 1200, y: -10))
        XCTAssertEqual(p, CGPoint(x: 1200, y: -10))
    }

    func testDeadZoneIsClampedToNearestDisplay() {
        // Above the main display, left of the external one: not on any screen.
        let p = layout.clamp(CGPoint(x: 300, y: -200))
        XCTAssertTrue(layout.displays.contains { $0.contains(p) })
        XCTAssertEqual(Double(p.y), 0, accuracy: 0.01)
    }

    func testDisplayContaining() {
        XCTAssertEqual(layout.display(containing: CGPoint(x: 1000, y: -100)), layout.displays[1])
        XCTAssertEqual(layout.display(containing: CGPoint(x: -50, y: 50)), layout.displays[0])
    }
}

final class AppSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "AirTrackpadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testVersion1SettingsMigrateToNewTuningButKeepPreferences() throws {
        let legacy = """
        {"cursorSensitivity":1,"filterMinCutoff":1,"filterBeta":0.007,"pinchStartThreshold":0.15,
         "pinchReleaseThreshold":0.22,"naturalScrolling":false,"isAlwaysOnTop":true,"showCameraFeed":true,
         "showPerformanceMetrics":false,"mirrorsHorizontal":true,"swipeMinDisplacement":0.09}
        """
        let defaults = freshDefaults()
        defaults.set(Data(legacy.utf8), forKey: "com.airtrackpad.settings")
        let settings = AppSettings.load(from: defaults)
        XCTAssertEqual(settings.settingsVersion, AppSettings.currentVersion)
        XCTAssertEqual(settings.pinchStartThreshold, AppSettings().pinchStartThreshold, "old tuning is replaced")
        XCTAssertTrue(settings.isAlwaysOnTop, "UI preferences are kept")
        XCTAssertTrue(settings.showCameraFeed)
        XCTAssertFalse(settings.showPerformanceMetrics)
    }

    func testRoundTripPreservesCurrentSettings() {
        let defaults = freshDefaults()
        var s = AppSettings()
        s.cursorMode = .absolute
        s.pointerSpeed = 1.7
        s.spaceSwitchStyle = .instant
        s.naturalSwipeDirection = true
        s.cameraDeviceID = "abc"
        s.save(to: defaults)
        XCTAssertEqual(AppSettings.load(from: defaults), s)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let partial = #"{"settingsVersion":2,"pointerSpeed":2.0}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(partial.utf8))
        XCTAssertEqual(decoded.pointerSpeed, 2.0)
        XCTAssertEqual(decoded.spaceSwitchStyle, AppSettings().spaceSwitchStyle)
    }

    func testSwipeSensitivityScalesThresholds() {
        var s = AppSettings()
        s.swipeSensitivity = 2.0
        let easy = s.gestureConfig()
        s.swipeSensitivity = 0.5
        let strict = s.gestureConfig()
        XCTAssertLessThan(easy.swipeFullDistance, strict.swipeFullDistance)
    }
}

final class SpaceSwitchEncodingTests: XCTestCase {
    func testLegacyEncodingMatchesInstantSpaceSwitcher() throws {
        let event = try XCTUnwrap(DockSwipeEncoder.makeLegacy(phase: .ended, sign: 1, velocity: 40))
        XCTAssertEqual(event.getIntegerValueField(DockSwipeEncoder.eventType), 30)
        XCTAssertEqual(event.getIntegerValueField(DockSwipeEncoder.gestureHIDType), 23)
        XCTAssertEqual(event.getIntegerValueField(DockSwipeEncoder.gesturePhase), 4)
        XCTAssertEqual(event.getIntegerValueField(DockSwipeEncoder.swipeMotion), 1)
        XCTAssertGreaterThan(event.getDoubleValueField(DockSwipeEncoder.swipeProgress), 0, "positive = desktop on the right")
        XCTAssertLessThan(event.getDoubleValueField(DockSwipeEncoder.swipeProgress), 0.001, "commit comes from velocity, not progress")
        XCTAssertEqual(event.getDoubleValueField(DockSwipeEncoder.swipeVelocityX), 40, accuracy: 1e-6)

        let left = try XCTUnwrap(DockSwipeEncoder.makeLegacy(phase: .began, sign: -1, velocity: 40))
        XCTAssertLessThan(left.getDoubleValueField(DockSwipeEncoder.swipeVelocityX), 0)
    }

    func testStyleVelocities() {
        XCTAssertEqual(SpaceSwitchStyle.animated.dockSwipeVelocity, 40)
        XCTAssertGreaterThan(SpaceSwitchStyle.instant.dockSwipeVelocity ?? 0, 1000)
        XCTAssertNil(SpaceSwitchStyle.keyboard.dockSwipeVelocity)
    }

    func testFixedPointConversion() {
        XCTAssertEqual(DockSwipeEncoder.fixed1616(1.0), 65536)
        XCTAssertEqual(DockSwipeEncoder.fixed1616(-0.5), -32768)
        XCTAssertEqual(DockSwipeEncoder.fixed1616(0.000001), 1, "tiny values keep their sign")
        XCTAssertEqual(DockSwipeEncoder.fixed1616(-0.000001), -1)
    }

    func testModernPayloadLayout() throws {
        let ended = try XCTUnwrap(DockSwipeEncoder.makeLegacy(phase: .ended, sign: 1, velocity: 9999))
        XCTAssertEqual(DockSwipeEncoder.iohidPayload(for: ended).count, 28 + 40 + 28, "header + fluid gesture + velocity")
        let began = try XCTUnwrap(DockSwipeEncoder.makeLegacy(phase: .began, sign: 1, velocity: 0))
        XCTAssertEqual(DockSwipeEncoder.iohidPayload(for: began).count, 28 + 40)
    }

    func testModernEventIncludesCompanion() throws {
        let pair = try XCTUnwrap(DockSwipeEncoder.makeModern(phase: .ended, sign: -1))
        XCTAssertEqual(pair.companion.getIntegerValueField(DockSwipeEncoder.eventType), 29)
        XCTAssertEqual(pair.event.getIntegerValueField(DockSwipeEncoder.eventType), 30)
    }

    func testSpaceInfoEdges() {
        let first = SpaceInfo(currentIndex: 0, count: 3, displayIdentifier: "d")
        XCTAssertFalse(first.canMove(.left))
        XCTAssertTrue(first.canMove(.right))
        let last = SpaceInfo(currentIndex: 2, count: 3, displayIdentifier: "d")
        XCTAssertFalse(last.canMove(.right))
    }
}
