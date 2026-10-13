import SwiftUI
import AirTrackpadCore

public struct DebugHUDView: View {
    @ObservedObject public var appState: AppState
    private let onToggleRecording: (Bool) -> Void

    public init(appState: AppState, onToggleRecording: @escaping (Bool) -> Void = { _ in }) {
        self.appState = appState
        self.onToggleRecording = onToggleRecording
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            if !appState.isAccessibilityGranted {
                accessibilityBanner
            }

            ZStack {
                Color.black

                if appState.showCameraFeed, let cgImg = appState.currentFrameImage {
                    Image(decorative: cgImg, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: -1, y: 1)
                        .opacity(0.6)
                }

                SkeletonOverlayView(observations: appState.observations)

                VStack {
                    HStack(alignment: .top) {
                        chip(icon: appState.showCameraFeed ? "video.fill" : "video.slash",
                             text: appState.cameraDescription.isEmpty ? "Camera" : appState.cameraDescription)
                        Spacer()
                        if !appState.lastAction.isEmpty, let date = appState.lastActionDate,
                           Date().timeIntervalSince(date) < 3 {
                            Text(appState.lastAction)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.85))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                                .transition(.opacity)
                        }
                    }
                    .padding(10)
                    Spacer()
                    gestureGuide
                        .padding(.bottom, 8)
                }

                if appState.observations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.raised.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text(appState.isRunning ? "No Hand Detected" : "Tracking Stopped")
                            .foregroundColor(.gray)
                            .font(.callout)
                    }
                }
            }

            if let metrics = appState.metrics {
                fingerBar(metrics)
            }

            footer
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(appState.isRunning ? (appState.isPaused ? Color.orange : Color.green) : Color.red)
                .frame(width: 10, height: 10)
            Text("AirTrackpad")
                .font(.headline)
            Text(appState.cursorMode == .relative ? "Trackpad mode" : "Direct mode")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            toggleButton(
                active: appState.isRecording,
                icon: appState.isRecording ? "record.circle.fill" : "record.circle",
                label: appState.isRecording ? "Recording" : "Record",
                tint: .red,
                width: 104
            ) {
                onToggleRecording(!appState.isRecording)
            }
            .help("Record hand-tracking data to a JSON file for offline tuning and tests.")

            toggleButton(
                active: appState.isAlwaysOnTop,
                icon: appState.isAlwaysOnTop ? "pin.fill" : "pin.slash",
                label: appState.isAlwaysOnTop ? "Pinned" : "Normal",
                tint: .orange,
                width: 84
            ) {
                appState.isAlwaysOnTop.toggle()
            }
            .help("Keep this window above other apps.")

            toggleButton(
                active: appState.showCameraFeed,
                icon: appState.showCameraFeed ? "video.fill" : "video.slash.fill",
                label: appState.showCameraFeed ? "Camera On" : "Camera Off",
                tint: .green,
                width: 112
            ) {
                appState.showCameraFeed.toggle()
            }
            .help("Show the camera image behind the skeleton.")

            if appState.showPerformanceMetrics {
                HStack(spacing: 8) {
                    Text(String(format: "%4.1f FPS", appState.fps))
                        .foregroundColor(.green)
                        .frame(width: 76, alignment: .trailing)
                    Text(String(format: "%4.1f ms", appState.latencyMs))
                        .foregroundColor(.cyan)
                        .frame(width: 70, alignment: .trailing)
                }
                .font(.system(.subheadline, design: .monospaced))
                .monospacedDigit()
                .contentShape(Rectangle())
                .help("Camera frame rate and Vision processing time. Click to hide.")
                .onTapGesture { appState.showPerformanceMetrics.toggle() }
            } else {
                Button(action: { appState.showPerformanceMetrics = true }) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 26)
                }
                .buttonStyle(.plain)
                .help("Show FPS & latency")
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var accessibilityBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility Permission Required")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text("macOS needs Accessibility access for AirTrackpad to move the pointer, click, scroll and switch desktops.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button("Grant Permission") {
                PermissionsHelper.promptAccessibilityPermission()
                PermissionsHelper.openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.85))
    }

    private var gestureGuide: some View {
        HStack(spacing: 10) {
            guideItem("☝", "Move")
            guideItem("🤏", "Click · hold/move to drag")
            guideItem("🤌", "Thumb+middle: right-click")
            guideItem("✌", "Scroll")
            guideItem("🖐↔", "Desktops")
            guideItem("🖐🤏🖐", "Mission Control")
            guideItem("✊", "Lift / reposition")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.55))
        .cornerRadius(8)
    }

    private func guideItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Text(symbol).font(.system(size: 11))
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private func fingerBar(_ metrics: HandMetrics) -> some View {
        HStack(spacing: 8) {
            Text("FINGERS:")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            ForEach([Finger.thumb, .index, .middle, .ring, .little], id: \.self) { f in
                let isUp = metrics.state(for: f).isUp
                HStack(spacing: 3) {
                    Text(f == .little ? "PINKY" : f.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    Text(isUp ? "▲" : "▼")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(isUp ? Color.green.opacity(0.22) : Color.white.opacity(0.06))
                .foregroundColor(isUp ? .green : .secondary)
                .cornerRadius(4)
            }
            Spacer()
            Text(String(format: "hand %.2f", metrics.handScale))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .help("Hand size in the image. Very small values mean you're far from the camera.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.7))
    }

    /// Typed explicitly: passed straight to `String(format:)`, a bare `?? 0` is inferred as an
    /// `Int` CVarArg when no hand is visible, which `%.2f` misreads.
    private var pinchReading: Double { appState.metrics?.pinchDistance ?? 0 }

    private var footer: some View {
        HStack(spacing: 20) {
            MetricCard(title: "POSE", value: poseLabel(appState.pose), color: .green)
            VStack(alignment: .leading, spacing: 4) {
                Text("PINCH")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Text(String(format: "%.2f", pinchReading))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                    ProgressView(value: appState.pinchProgress)
                        .progressViewStyle(.linear)
                        .tint(appState.pinchProgress >= 1 ? .accentColor : .orange)
                        .frame(width: 60)
                }
            }
            .frame(minWidth: 120, alignment: .leading)
            MetricCard(title: "HAND SPEED", value: String(format: "%.1f /s", appState.handSpeed), color: .purple)
            MetricCard(title: "STATE", value: appState.activeGestureName, color: .cyan)
            Spacer()
        }
        .padding()
        .background(Color(NSColor.underPageBackgroundColor))
    }

    // MARK: - Helpers

    private func poseLabel(_ pose: HandPose) -> String {
        switch pose {
        case .none: return "—"
        case .pointing: return "☝ Point"
        case .scroll: return "✌ Scroll"
        case .openHand: return "🖐 Open"
        case .fist: return "✊ Fist"
        case .other: return "· Other"
        }
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.65))
        .cornerRadius(6)
    }

    private func toggleButton(active: Bool, icon: String, label: String, tint: Color, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { action() } }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .frame(width: width, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? tint.opacity(0.2) : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? tint.opacity(0.5) : Color.white.opacity(0.18), lineWidth: 1))
            .foregroundColor(active ? tint : .primary.opacity(0.75))
        }
        .buttonStyle(.plain)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .frame(minWidth: 96, alignment: .leading)
    }
}
