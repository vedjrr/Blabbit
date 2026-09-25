import Foundation

/// How text gets into the focused app (ADR-006).
public enum InsertionStrategy: String, Codable, CaseIterable, Sendable {
    /// Set the focused element's selected text via the Accessibility API.
    /// No clipboard, no keystrokes; verified by reading the field back.
    case accessibility
    /// Clipboard + synthetic ⌘V, with the clipboard restored afterwards.
    case paste
    /// Synthetic Unicode key events (slowest; works where paste is blocked).
    case typing

    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .paste: "Paste"
        case .typing: "Type"
        }
    }
}

/// Per-app strategy order. Defaults come from what each class of app handles
/// reliably; the user can override any app (persisted in UserDefaults).
public struct AppInsertionTable: Sendable {
    /// Native Cocoa text views implement AXSelectedText writes properly.
    public static let nativeChain: [InsertionStrategy] = [.accessibility, .paste, .typing]
    /// Terminals, Chromium and Electron apps: AX writes are unreliable or ignored.
    public static let pasteFirstChain: [InsertionStrategy] = [.paste, .typing]
    /// Anything we don't know: try AX (verified), then paste, then typing.
    public static let unknownChain: [InsertionStrategy] = [.accessibility, .paste, .typing]

    public static let defaults: [String: [InsertionStrategy]] = {
        var table: [String: [InsertionStrategy]] = [:]
        let native = [
            "com.apple.TextEdit", "com.apple.Notes", "com.apple.mail", "com.apple.dt.Xcode",
            "com.apple.MobileSMS", "com.apple.Pages", "com.apple.iWork.Pages", "com.apple.reminders",
        ]
        let pasteFirst = [
            // Terminals
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
            // Browsers (web content text fields)
            "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
            "com.microsoft.edgemac", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
            // Electron / Chromium-based desktop apps
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
            "notion.id", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop",
            "md.obsidian", "com.linear", "com.figma.Desktop", "com.spotify.client",
        ]
        for id in native { table[id] = nativeChain }
        for id in pasteFirst { table[id] = pasteFirstChain }
        return table
    }()

    public var overrides: [String: [InsertionStrategy]]

    public init(overrides: [String: [InsertionStrategy]] = [:]) {
        self.overrides = overrides
    }

    public func chain(for bundleID: String?, bundleURL: URL? = nil) -> [InsertionStrategy] {
        guard let bundleID else { return Self.unknownChain }
        if let custom = overrides[bundleID], !custom.isEmpty { return custom }
        if let known = Self.defaults[bundleID] { return known }
        // Apps not in the table that embed Chromium/Electron update their AX tree
        // asynchronously, so an AX write can land after verification gives up;
        // paste first there to rule out duplicate text.
        if let bundleURL, Self.embedsChromium(bundleURL) { return Self.pasteFirstChain }
        return Self.unknownChain
    }

    static let chromiumFrameworks = ["Electron Framework.framework", "Chromium Embedded Framework.framework"]

    /// True if the app bundle ships Electron or CEF (a cheap directory check).
    public static func embedsChromium(_ bundleURL: URL) -> Bool {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        return chromiumFrameworks.contains { FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path) }
    }

    // MARK: Persistence

    public static let defaultsKey = "insertion.overrides"

    public static func load(from defaults: UserDefaults = .standard) -> AppInsertionTable {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [InsertionStrategy]].self, from: data)
        else { return AppInsertionTable() }
        return AppInsertionTable(overrides: decoded)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
