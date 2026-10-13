import SwiftUI
import AirTrackpadCore

public struct SettingsView: View {
    /// Written to (HUD preferences), never observed: observing it would re-render Settings on
    /// every camera frame.
    public let appState: AppState
    @State private var settings = AppSettings.load()
    @State private var cameraGranted = PermissionsHelper.isCameraAuthorized
    @State private var accessibilityGranted = PermissionsHelper.isAccessibilityAuthorized
    @State private var cameras: [CameraDescriptor] = CameraManager.availableCameras()

    public init(appState: AppState = AppState()) {
        self.appState = appState
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            cursorTab
                .tabItem { Label("Pointer", systemImage: "cursorarrow.motionlines") }
            clickScrollTab
                .tabItem { Label("Click & Scroll", systemImage: "hand.tap") }
            desktopsTab
                .tabItem { Label("Desktops", systemImage: "rectangle.split.3x1") }
        }
        .frame(width: 620, height: 560)
        .onChange(of: settings) { newValue in
            newValue.save()
            if appState.showCameraFeed != newValue.showCameraFeed { appState.showCameraFeed = newValue.showCameraFeed }
            if appState.showPerformanceMetrics != newValue.showPerformanceMetrics { appState.showPerformanceMetrics = newValue.showPerformanceMetrics }
            if appState.isAlwaysOnTop != newValue.isAlwaysOnTop { appState.isAlwaysOnTop = newValue.isAlwaysOnTop }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.didChangeNotification)) { _ in
            let fresh = AppSettings.load()
            if fresh != settings { settings = fresh }
        }
        .task {
            while !Task.isCancelled {
                cameraGranted = PermissionsHelper.isCameraAuthorized
                accessibilityGranted = PermissionsHelper.isAccessibilityAuthorized
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(header: Text("Permissions").font(.headline)) {
                permissionRow(
                    granted: cameraGranted,
                    title: "Camera",
                    detail: "Used only on this Mac to find your hand. Nothing is recorded or uploaded.",
                    action: PermissionsHelper.openCameraSettings
                )
                permissionRow(
                    granted: accessibilityGranted,
                    title: "Accessibility",
                    detail: "Lets AirTrackpad move the pointer, click, scroll and switch desktops.",
                    action: {
                        PermissionsHelper.promptAccessibilityPermission()
                        PermissionsHelper.openAccessibilitySettings()
                    }
                )
            }

            Section(header: Text("Camera").font(.headline)) {
                Picker("Camera", selection: $settings.cameraDeviceID) {
                    Text("Automatic (built-in)").tag(String?.none)
                    ForEach(cameras) { camera in
                        Text(camera.name).tag(String?.some(camera.id))
                    }
                }
                .onAppear { cameras = CameraManager.availableCameras() }
                Toggle("Mirror camera (move right → pointer moves right)", isOn: $settings.mirrorsHorizontal)
            }

            Section(header: Text("Behaviour").font(.headline)) {
                Toggle("Pause gestures while typing", isOn: $settings.pauseWhileTyping)
                Toggle("Show feedback ring around the pointer", isOn: $settings.showCursorFeedback)
                Toggle("Open the live HUD at launch", isOn: $settings.showHUDAtLaunch)
                Toggle("HUD: show camera image", isOn: $settings.showCameraFeed)
                Toggle("HUD: show FPS & latency", isOn: $settings.showPerformanceMetrics)
                Toggle("HUD: keep on top", isOn: $settings.isAlwaysOnTop)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore All Defaults") {
                        var fresh = AppSettings()
                        fresh.cameraDeviceID = settings.cameraDeviceID
                        settings = fresh
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Pointer

    private var cursorTab: some View {
        Form {
            Section(header: Text("Pointer Mode").font(.headline)) {
                Picker("Mode", selection: $settings.cursorMode) {
                    Text("Trackpad (move hand to move pointer)").tag(CursorMode.relative)
                    Text("Direct (hand position = pointer position)").tag(CursorMode.absolute)
                }
                .pickerStyle(.radioGroup)
                Text(settings.cursorMode == .relative
                     ? "Point with your index finger and move your hand. Make a fist to lift, reposition, and continue — like lifting a finger off a trackpad."
                     : "The camera's field of view maps onto the screen under the pointer. No lifting needed, but it takes more arm movement.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if settings.cursorMode == .relative {
                Section(header: Text("Trackpad Feel").font(.headline)) {
                    labeledSlider("Pointer speed", value: $settings.pointerSpeed, range: 0.3...3.0, format: "%.2f×")
                    labeledSlider("Acceleration", value: $settings.pointerAcceleration, range: 0.0...1.0, format: "%.2f",
                                  hint: "Higher: slow movements are more precise, fast flicks travel further.")
                }
            } else {
                Section(header: Text("Direct Mapping").font(.headline)) {
                    labeledSlider("Sensitivity", value: $settings.cursorSensitivity, range: 0.5...3.0, format: "%.2f×",
                                  hint: "Higher: less hand travel covers the whole screen.")
                }
            }

            Section(header: Text("Smoothing").font(.headline)) {
                labeledSlider("Responsive ↔ Steady", value: $settings.cursorSmoothing, range: 0.0...1.0, format: "%.2f",
                              hint: "Steadier removes more hand tremor at the cost of a little lag.")
            }
        }
        .padding()
    }

    // MARK: - Click & Scroll

    private var clickScrollTab: some View {
        Form {
            Section(header: Text("Pinch to Click").font(.headline)) {
                labeledSlider("Pinch trigger distance", value: Binding(
                    get: { settings.pinchStartThreshold },
                    set: {
                        settings.pinchStartThreshold = $0
                        settings.pinchReleaseThreshold = $0 + 0.10
                    }
                ), range: 0.12...0.34, format: "%.2f",
                   hint: "How close thumb and index fingertips must get. Raise it if pinches are missed; lower it if clicks fire by accident.")
                labeledSlider("Hold to drag after", value: $settings.dragHoldDelay, range: 0.25...0.9, format: "%.2f s",
                              hint: "Moving while pinched starts a drag immediately; holding still this long also does.")
                Toggle("Right-click with thumb + middle finger pinch", isOn: $settings.rightClickEnabled)
            }

            Section(header: Text("Two-Finger Scroll (✌)").font(.headline)) {
                Toggle("Enable scrolling", isOn: $settings.scrollEnabled)
                labeledSlider("Scroll speed", value: $settings.scrollSensitivity, range: 0.3...3.0, format: "%.2f×")
                Toggle("Natural scrolling (content follows your hand)", isOn: $settings.naturalScrolling)
                Toggle("Momentum (keep gliding after a quick flick)", isOn: $settings.scrollMomentum)
            }
        }
        .padding()
    }

    // MARK: - Desktops

    private var desktopsTab: some View {
        Form {
            Section(header: Text("Switch Desktops (🖐 swipe ← →)").font(.headline)) {
                Toggle("Enable desktop swipes", isOn: $settings.swipeEnabled)
                Picker("Direction", selection: $settings.naturalSwipeDirection) {
                    Text("Hand right → desktop on the right").tag(false)
                    Text("Natural: the desktop follows your hand (like a trackpad)").tag(true)
                }
                labeledSlider("Swipe sensitivity", value: $settings.swipeSensitivity, range: 0.6...1.6, format: "%.2f",
                              hint: "Higher: less hand travel drags a whole desktop. Lower if the desktop moves when you just reposition your hand.")
                Picker("Finish", selection: $settings.spaceSwitchStyle) {
                    Text("Animated slide").tag(SpaceSwitchStyle.animated)
                    Text("Fast slide").tag(SpaceSwitchStyle.fast)
                    Text("Instant").tag(SpaceSwitchStyle.instant)
                    Text("Keyboard shortcut (⌃← / ⌃→, no live slide)").tag(SpaceSwitchStyle.keyboard)
                }
                HStack {
                    Text("Test:")
                    Button("◀︎ Previous") { NotificationCenter.default.post(name: .airTrackpadTestSwitch, object: SwipeDirection.left) }
                    Button("Next ▶︎") { NotificationCenter.default.post(name: .airTrackpadTestSwitch, object: SwipeDirection.right) }
                }
                Text("Open your hand (all four fingers up) and move it sideways: the desktop follows, like three fingers on the trackpad. Let go by closing your hand, holding still or flicking — past halfway (or with a flick) it switches, otherwise it slides back. Bringing your hand back afterwards is ignored.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Mission Control (🖐 → 🤏 → 🖐)").font(.headline)) {
                Toggle("Enable Mission Control gesture", isOn: $settings.missionControlEnabled)
                labeledSlider("Gathered fingertips", value: $settings.fiveFingerPinchThreshold, range: 0.12...0.32, format: "%.2f")
                labeledSlider("Open palm", value: $settings.fiveFingerOpenThreshold, range: 0.32...0.65, format: "%.2f")
            }
        }
        .padding()
    }

    // MARK: - Components

    private func permissionRow(granted: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .red)
            VStack(alignment: .leading) {
                Text(title).font(.body.bold())
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings", action: action)
            }
        }
        .padding(.vertical, 2)
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        hint: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
            if let hint {
                Text(hint).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

extension Notification.Name {
    static let airTrackpadTestSwitch = Notification.Name("com.airtrackpad.testSpaceSwitch")
}
