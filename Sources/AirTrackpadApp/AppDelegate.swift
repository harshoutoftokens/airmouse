import Cocoa
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hudWindow: NSWindow?
    
    private let appState = AppState()
    private var coordinator: TrackingPipelineCoordinator?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Runs primarily in Menu Bar
        
        coordinator = TrackingPipelineCoordinator(appState: appState)
        setupStatusMenu()
        showDebugHUD()
        coordinator?.start()
    }
    
    private func setupStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        
        button.title = "🖐 AirTrackpad"
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Debug HUD", action: #selector(showDebugHUD), keyEquivalent: "d"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Start Tracking", action: #selector(startTracking), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop Tracking", action: #selector(stopTracking), keyEquivalent: "p"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit AirTrackpad", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc public func showDebugHUD() {
        if hudWindow == nil {
            let contentView = DebugHUDView(appState: appState)
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 720, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AirTrackpad — Debug HUD"
            window.contentView = NSHostingView(rootView: contentView)
            window.isReleasedWhenClosed = false
            window.level = .floating // Stays on top for easy debugging
            hudWindow = window
        }
        hudWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func startTracking() {
        coordinator?.start()
    }
    
    @objc private func stopTracking() {
        coordinator?.stop()
    }
    
    @objc private func quitApp() {
        coordinator?.stop()
        NSApp.terminate(nil)
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
