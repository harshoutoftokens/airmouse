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
            HStack(spacing: 12) {
                Circle()
                    .fill(appState.isRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("AirTrackpad Debug HUD")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                // Camera Output Toggle Button with strictly FIXED geometry
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.showCameraFeed.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: appState.showCameraFeed ? "video.fill" : "video.slash.fill")
                            .font(.system(size: 11))
                        Text(appState.showCameraFeed ? "Camera On" : "Camera Off")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .frame(width: 116, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(appState.showCameraFeed ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(appState.showCameraFeed ? Color.green.opacity(0.5) : Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .foregroundColor(appState.showCameraFeed ? .green : .white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help(appState.showCameraFeed ? "Switch to minimal black screen (hide face/camera)" : "Show camera video feed")
                
                if appState.showPerformanceMetrics {
                    Divider()
                        .frame(height: 16)
                        .background(Color.white.opacity(0.2))
                    
                    // Fixed-width performance cluster: values never push neighboring buttons
                    HStack(spacing: 8) {
                        Text(String(format: "%4.1f FPS", appState.fps))
                            .font(.system(.subheadline, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(.green)
                            .frame(width: 76, alignment: .trailing)
                        
                        Text(String(format: "%4.1f ms", appState.latencyMs))
                            .font(.system(.subheadline, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(.cyan)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .frame(width: 156, alignment: .trailing)
                    .contentShape(Rectangle())
                    .help("Live engine performance (FPS & processing latency). Click to hide.")
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            appState.showPerformanceMetrics.toggle()
                        }
                    }
                } else {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            appState.showPerformanceMetrics = true
                        }
                    }) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Show FPS & latency metrics")
                }
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
                Color.black
                
                if appState.showCameraFeed, let cgImg = appState.currentFrameImage {
                    Image(decorative: cgImg, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: -1, y: 1)
                        .opacity(0.6)
                }
                
                SkeletonOverlayView(observations: appState.observations)
                
                // Top controls overlay inside Viewport
                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.showCameraFeed ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                            Text(appState.showCameraFeed ? "Feed: Camera" : "Feed: Black Screen")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(6)
                        
                        Spacer()
                        
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                appState.showCameraFeed.toggle()
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: appState.showCameraFeed ? "video.slash" : "video")
                                    .font(.system(size: 10))
                                Text(appState.showCameraFeed ? "Black Screen" : "Show Camera")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .foregroundColor(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    
                    Spacer()
                }
                
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
