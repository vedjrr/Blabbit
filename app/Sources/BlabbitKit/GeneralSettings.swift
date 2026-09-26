import AppKit
import ServiceManagement

/// Settings → General (BRIEF §10).
public struct GeneralSettings: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, CaseIterable, Sendable {
        case system, light, dark

        public var title: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    public var appearance: Appearance = .system
    /// Keep the menu bar icon visible when idle (it always shows while dictating).
    public var showMenuBarIcon = true
    /// Open the setup window at launch when a permission is missing.
    public var showSetupWhenNeeded = true
    /// Let `blabbit://` links start, stop or cancel dictation (PARITY F14). Off by
    /// default: a web page can open such a link, and start would turn on the microphone.
    public var allowURLCommands = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case appearance, showMenuBarIcon, showSetupWhenNeeded, allowURLCommands }

    /// Settings saved by an older version lack newer keys: they keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        showSetupWhenNeeded = try c.decodeIfPresent(Bool.self, forKey: .showSetupWhenNeeded) ?? true
        allowURLCommands = try c.decodeIfPresent(Bool.self, forKey: .allowURLCommands) ?? false
    }

    public static let defaultsKey = "general.settings"

    public static func load(from defaults: UserDefaults = .standard) -> GeneralSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(GeneralSettings.self, from: data) else { return GeneralSettings() }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    @MainActor public func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}

/// Launch at login through SMAppService (the system's Login Items list).
public enum LaunchAtLogin {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns a plain-English problem, or nil on success.
    @discardableResult
    public static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            Log.error("launch at login \(on) failed: \(error)")
            if SMAppService.mainApp.status == .requiresApproval {
                return "macOS needs your approval: System Settings → General → Login Items → allow Blabbit."
            }
            return "Blabbit couldn't change Launch at Login. Try again from System Settings → General → Login Items."
        }
    }
}
