import SwiftUI
import AirTrackpadCore

public struct DebugHUDView: View {
    @ObservedObject public var appState: AppState
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Circle()
                    .fill(appState.isRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("AirTrackpad Debug HUD")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text(String(format: "%.1f FPS", appState.fps))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.green)
                Text(String(format: "%.1f ms", appState.latencyMs))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            // Accessibility Warning Banner
            if !appState.isAccessibilityGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility Permission Required")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                        Text("macOS requires Accessibility permission to execute clicks, window drags, and Space swipes.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
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
            
            // Viewport & Skeleton Overlay
            ZStack {
                Color.black.opacity(0.85)
                
                if let cgImg = appState.currentFrameImage {
                    Image(decorative: cgImg, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: -1, y: 1)
                        .opacity(0.6)
                }
                
                SkeletonOverlayView(observations: appState.observations)
                
                if appState.observations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.raised.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No Hand Detected")
                            .foregroundColor(.gray)
                            .font(.callout)
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 400)
            
            // Metrics Dashboard Footer
            HStack(spacing: 24) {
                MetricCard(
                    title: "EXTENDED",
                    value: "\(appState.metrics?.extendedFingerCount ?? 0)",
                    color: .green
                )
                
                MetricCard(
                    title: "PINCH DIST",
                    value: String(format: "%.2f", appState.metrics?.pinchDistance ?? 0.0),
                    color: .orange
                )
                
                MetricCard(
                    title: "SPREAD (σ)",
                    value: String(format: "%.2f", appState.metrics?.spread ?? 0.0),
                    color: .purple
                )
                
                MetricCard(
                    title: "SPEED",
                    value: appState.cursorSpeedMultiplier < 0.99 ? String(format: "%.2fx SLOW", appState.cursorSpeedMultiplier) : "1.0x",
                    color: appState.cursorSpeedMultiplier < 0.99 ? .cyan : .green
                )
                
                MetricCard(
                    title: "ACTIVE STATE",
                    value: appState.activeGestureName,
                    color: .cyan
                )
            }
            .padding()
            .background(Color(NSColor.underPageBackgroundColor))
        }
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
        }
        .frame(minWidth: 100, alignment: .leading)
    }
}
