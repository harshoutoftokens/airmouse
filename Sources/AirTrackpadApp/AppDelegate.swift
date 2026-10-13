import Cocoa
import SwiftUI
import AirTrackpadCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hudWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pauseItem: NSMenuItem?
    private var statusHeaderItem: NSMenuItem?

    private let appState = AppState()
    private var coordinator: TrackingPipelineCoordinator?
    private var overlay: CursorFeedbackOverlay?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Menu bar app

        if CommandLine.arguments.contains("--diagnose-spaces") {
            runSpaceDiagnostics()
            return
        }

        let coordinator = TrackingPipelineCoordinator(appState: appState)
        self.coordinator = coordinator
        let overlay = CursorFeedbackOverlay(appState: appState)
        self.overlay = overlay

        let settings = AppSettings.load()
        overlay.setEnabled(settings.showCursorFeedback)

        setupStatusMenu()
        setupKeyMonitor()
        observeChanges()
        if settings.showHUDAtLaunch {
            showDebugHUD(activate: false)
        }

        Task {
            var cameraReady = PermissionsHelper.isCameraAuthorized
            if !cameraReady {
                cameraReady = await PermissionsHelper.requestCameraAccess()
            }
            if cameraReady {
                self.coordinator?.start()
            }
            if !PermissionsHelper.isAccessibilityAuthorized {
                PermissionsHelper.promptAccessibilityPermission()
            }
        }
    }

    // MARK: - Diagnostics

    /// `open AirTrackpad.app --args --diagnose-spaces`: no camera, no gestures. Moves one desktop
    /// over and back with the Dock swipe, then with ⌃←/⌃→, records which way each actually went
    /// to ~/Library/Logs/AirTrackpad/space-diagnostics.txt, and quits.
    private func runSpaceDiagnostics() {
        let trusted = PermissionsHelper.isAccessibilityAuthorized
        DispatchQueue.global(qos: .userInitiated).async {
            let switcher = SpaceSwitcher()
            var lines = [
                "AirTrackpad space diagnostics — \(Date())",
                "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), accessibility trusted: \(trusted)"
            ]
            let pointer = CGEvent(source: nil)?.location ?? .zero
            if let info = SkyLightSpaces.spaceInfo(at: pointer) {
                lines.append("start: space \(info.currentIndex + 1) of \(info.count) on display \(info.displayIdentifier)")
                let first: SwipeDirection = info.canMove(.right) ? .right : .left
                let back: SwipeDirection = first == .right ? .left : .right
                if CommandLine.arguments.contains("--interactive") {
                    lines += switcher.diagnoseInteractive()
                } else {
                    for style in [SpaceSwitchStyle.animated, .keyboard] {
                        lines.append(switcher.diagnose(first, style: style))
                        lines.append(switcher.diagnose(back, style: style))
                    }
                }
            } else {
                lines.append("Space list unavailable (SkyLight lookup failed)")
            }
            let report = lines.joined(separator: "\n") + "\n"
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AirTrackpad", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? report.write(to: dir.appendingPathComponent("space-diagnostics.txt"), atomically: true, encoding: .utf8)
            print(report)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Observers

    private func observeChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AppSettings.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let settings = AppSettings.load()
                self?.coordinator?.applySettings(settings)
                self?.overlay?.setEnabled(settings.showCursorFeedback)
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.refreshDisplayLayout() }
        })
        observers.append(center.addObserver(forName: .airTrackpadTestSwitch, object: nil, queue: .main) { [weak self] note in
            guard let direction = note.object as? SwipeDirection else { return }
            MainActor.assumeIsolated { self?.coordinator?.testSpaceSwitch(direction) }
        })
    }

    private func setupKeyMonitor() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Ignore AirTrackpad's own synthetic shortcuts (⌃← / ⌃→ desktop fallback).
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == CGEventInputBackend.eventTag {
                return
            }
            let isEmergencyStop = event.keyCode == 53 && event.modifierFlags.contains(.control)
            Task { @MainActor in
                if isEmergencyStop {
                    self?.setPaused(true)
                } else {
                    self?.coordinator?.noteKeyboardActivity()
                }
            }
        }
        // Global monitors never see keys sent to AirTrackpad itself (HUD / Settings focused).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.contains(.control) else { return event }
            MainActor.assumeIsolated { self?.setPaused(true) }
            return nil
        }
    }

    // MARK: - Menu

    private func setupStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        let header = NSMenuItem(title: "AirTrackpad — Active", action: nil, keyEquivalent: "")
        header.isEnabled = false
        statusHeaderItem = header
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let pause = NSMenuItem(title: "Pause Gestures", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem = pause
        menu.addItem(pause)
        menu.addItem(NSMenuItem(title: "Open Live HUD", action: #selector(openHUDFromMenu), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())

        let test = NSMenuItem(title: "Test Desktop Switch", action: nil, keyEquivalent: "")
        let testMenu = NSMenu()
        testMenu.addItem(NSMenuItem(title: "◀︎ Previous Desktop", action: #selector(testSwitchLeft), keyEquivalent: ""))
        testMenu.addItem(NSMenuItem(title: "Next Desktop ▶︎", action: #selector(testSwitchRight), keyEquivalent: ""))
        testMenu.addItem(NSMenuItem.separator())
        testMenu.addItem(NSMenuItem(title: "Reset Learned Direction", action: #selector(resetSwitchCalibration), keyEquivalent: ""))
        test.submenu = testMenu
        menu.addItem(test)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Emergency Stop (⌃⎋)", action: #selector(triggerEmergencyStop), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit AirTrackpad", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = appState.isPaused ? "hand.raised.slash" : "hand.raised.fill"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AirTrackpad") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.title = appState.isPaused ? "✋⏸" : "🖐"
        }
        statusHeaderItem?.title = appState.isPaused ? "AirTrackpad — Paused" : "AirTrackpad — Active"
        pauseItem?.title = appState.isPaused ? "Resume Gestures" : "Pause Gestures"
    }

    private func setPaused(_ paused: Bool) {
        if !paused && !appState.isRunning {
            coordinator?.start()
        } else {
            coordinator?.setPaused(paused)
        }
        appState.isPaused = paused
        updateStatusIcon()
    }

    @objc private func togglePause() {
        setPaused(!appState.isPaused)
    }

    @objc private func openHUDFromMenu() {
        showDebugHUD(activate: true)
    }

    public func showDebugHUD(activate: Bool) {
        if hudWindow == nil {
            let contentView = DebugHUDView(appState: appState, onToggleRecording: { [weak self] recording in
                self?.coordinator?.setRecording(recording)
            })
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AirTrackpad — Live HUD"
            window.contentView = NSHostingView(rootView: contentView)
            window.isReleasedWhenClosed = false
            window.level = appState.isAlwaysOnTop ? .floating : .normal
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.center()
            hudWindow = window

            appState.onWindowLevelChange = { [weak window] isTop in
                window?.level = isTop ? .floating : .normal
            }
        }
        if activate {
            hudWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            hudWindow?.orderFrontRegardless()
        }
    }

    @objc public func showSettings() {
        if settingsWindow == nil {
            let contentView = SettingsView(appState: appState)
            let window = NSWindow(
                contentRect: NSRect(x: 150, y: 150, width: 620, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AirTrackpad Settings"
            window.contentView = NSHostingView(rootView: contentView)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func testSwitchLeft() {
        coordinator?.testSpaceSwitch(.left)
    }

    @objc private func testSwitchRight() {
        coordinator?.testSpaceSwitch(.right)
    }

    @objc private func resetSwitchCalibration() {
        coordinator?.resetSpaceSwitchCalibration()
        appState.noteAction("Desktop switch calibration reset")
    }

    @objc private func triggerEmergencyStop() {
        setPaused(true)
    }

    @objc private func quitApp() {
        coordinator?.stop()
        NSApp.terminate(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        coordinator?.stop()
    }
}
