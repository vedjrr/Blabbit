import AVFoundation
import ApplicationServices

public enum Permissions {
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt if not yet granted.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt (the C global is not concurrency-safe in Swift 6).
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
