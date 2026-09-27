import SwiftUI
import AirTrackpadCore

public struct SettingsView: View {
    @State private var settings = AppSettings.load()
    @State private var cameraGranted = PermissionsHelper.isCameraAuthorized
    @State private var accessibilityGranted = PermissionsHelper.isAccessibilityAuthorized
    
    public init() {}
    
    public var body: some View {
        TabView {
            // Tab 1: Permissions & System
            Form {
                Section(header: Text("System Permissions").font(.headline)) {
                    HStack {
                        Image(systemName: cameraGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(cameraGranted ? .green : .red)
                        VStack(alignment: .leading) {
                            Text("Camera Access")
                                .font(.body.bold())
                            Text("Required for Vision hand landmark tracking.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if !cameraGranted {
                            Button("Open Settings") {
                                PermissionsHelper.openCameraSettings()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    
                    HStack {
                        Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(accessibilityGranted ? .green : .red)
                        VStack(alignment: .leading) {
                            Text("Accessibility Permissions")
                                .font(.body.bold())
                            Text("Required to synthesize mouse movements, clicks, and Mission Control gestures.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if !accessibilityGranted {
                            Button("Grant Access") {
                                PermissionsHelper.promptAccessibilityPermission()
                                PermissionsHelper.openAccessibilitySettings()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Camera & Capture").font(.headline)) {
                    Picker("Target Frame Rate", selection: $settings.targetFPS) {
                        Text("30 FPS").tag(Int32(30))
                        Text("60 FPS").tag(Int32(60))
                    }
                    Toggle("Mirror Webcam Horizontally", isOn: $settings.mirrorsHorizontal)
                }
            }
            .padding()
            .tabItem {
                Label("General", systemImage: "gear")
            }
            
            // Tab 2: Cursor & Smoothing
            Form {
                Section(header: Text("Cursor Navigation (1-Finger)").font(.headline)) {
                    VStack(alignment: .leading) {
                        Text(String(format: "Sensitivity: %.2f", settings.cursorSensitivity))
                        Slider(value: $settings.cursorSensitivity, in: 0.5...3.0, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Acceleration Curve: %.2f", settings.cursorAcceleration))
                        Slider(value: $settings.cursorAcceleration, in: 1.0...1.5, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Dead-Zone Threshold: %.1f px", settings.cursorDeadzonePixels))
                        Slider(value: $settings.cursorDeadzonePixels, in: 0.5...4.0, step: 0.1)
                    }
                }
                
                Section(header: Text("One Euro Filter (Jitter & Latency Tuning)").font(.headline)) {
                    VStack(alignment: .leading) {
                        Text(String(format: "Min Cutoff (Stationary Jitter Reduction): %.2f Hz", settings.filterMinCutoff))
                        Slider(value: $settings.filterMinCutoff, in: 0.1...3.0, step: 0.1)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Beta (High-Speed Lag Elimination): %.4f", settings.filterBeta))
                        Slider(value: $settings.filterBeta, in: 0.001...0.030, step: 0.001)
                    }
                }
            }
            .padding()
            .tabItem {
                Label("Cursor", systemImage: "cursorarrow")
            }
            
            // Tab 3: Gestures & Timings
            Form {
                Section(header: Text("Pinch & Drag (2-Finger)").font(.headline)) {
                    HStack {
                        Text(String(format: "Pinch Start: %.2f", settings.pinchStartThreshold))
                        Slider(value: $settings.pinchStartThreshold, in: 0.10...0.30, step: 0.01)
                    }
                    HStack {
                        Text(String(format: "Pinch Release: %.2f", settings.pinchReleaseThreshold))
                        Slider(value: $settings.pinchReleaseThreshold, in: 0.20...0.40, step: 0.01)
                    }
                    HStack {
                        Text(String(format: "Drag Hold Delay: %.2fs", settings.dragHoldDelay))
                        Slider(value: $settings.dragHoldDelay, in: 0.20...0.60, step: 0.05)
                    }
                }
                
                Section(header: Text("Desktop Switch (4-Finger Swipe)").font(.headline)) {
                    HStack {
                        Text(String(format: "Min Velocity: %.2f", settings.swipeMinVelocity))
                        Slider(value: $settings.swipeMinVelocity, in: 0.2...1.0, step: 0.05)
                    }
                    HStack {
                        Text(String(format: "Min Displacement: %.2f", settings.swipeMinDisplacement))
                        Slider(value: $settings.swipeMinDisplacement, in: 0.05...0.25, step: 0.01)
                    }
                }
                
                Section(header: Text("Mission Control (5-Finger Sequence)").font(.headline)) {
                    HStack {
                        Text(String(format: "Pinch Spread: %.2f", settings.fiveFingerPinchThreshold))
                        Slider(value: $settings.fiveFingerPinchThreshold, in: 0.15...0.30, step: 0.01)
                    }
                    HStack {
                        Text(String(format: "Open Spread: %.2f", settings.fiveFingerOpenThreshold))
                        Slider(value: $settings.fiveFingerOpenThreshold, in: 0.35...0.65, step: 0.01)
                    }
                }
            }
            .padding()
            .tabItem {
                Label("Gestures", systemImage: "hand.raised")
            }
        }
        .frame(width: 580, height: 420)
        .onDisappear {
            settings.save()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            cameraGranted = PermissionsHelper.isCameraAuthorized
            accessibilityGranted = PermissionsHelper.isAccessibilityAuthorized
        }
    }
}
