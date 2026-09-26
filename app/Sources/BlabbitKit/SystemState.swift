import CoreGraphics
import Foundation
import IOKit

/// Machine conditions that decide whether live input and window contents exist
/// (a closed MacBook lid switches the built-in mic off; a locked screen hides windows).
public enum SystemState {
    public static var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    public static var displayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    public static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// nil if live microphone input should be available, else why not.
    public static var liveInputUnavailableReason: String? {
        if lidClosed { return "the lid is closed (built-in microphone off)" }
        if displayAsleep { return "the display is asleep" }
        if screenLocked { return "the screen is locked" }
        return nil
    }
}
