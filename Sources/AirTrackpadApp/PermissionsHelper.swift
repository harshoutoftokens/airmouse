import Foundation
import AppKit
import AVFoundation

@MainActor
public enum PermissionsHelper {
    
    public static var isCameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
    
    public static func requestCameraAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return status == .authorized
    }
    
    public static var isAccessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }
    
    public static func promptAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options: NSDictionary = [key: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }
    
    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    public static func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
