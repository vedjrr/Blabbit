import Foundation
import Testing
@testable import UtterKit

/// PARITY F14: Handy's CLI flags and utter:// links.
@Suite struct RemoteCommandTests {
    @Test func handyFlagsMapToCommands() {
        #expect(RemoteCommand(arguments: ["Utter", "--toggle-transcription"]) == .toggle)
        #expect(RemoteCommand(arguments: ["Utter", "--toggle-post-process"]) == .toggleProcess)
        #expect(RemoteCommand(arguments: ["Utter", "--cancel"]) == .cancel)
        #expect(RemoteCommand(arguments: ["Utter", "--start-transcription"]) == .start)
        #expect(RemoteCommand(arguments: ["Utter", "--stop-transcription"]) == .stop)
        #expect(RemoteCommand(arguments: ["Utter"]) == nil)
        #expect(RemoteCommand(arguments: ["Utter", "--start-hidden"]) == nil, "a launch option, not a command")
    }

    @Test func urlsMapToCommands() throws {
        #expect(RemoteCommand(url: try #require(URL(string: "utter://toggle"))) == .toggle)
        #expect(RemoteCommand(url: try #require(URL(string: "UTTER://Cancel"))) == .cancel)
        #expect(RemoteCommand(url: try #require(URL(string: "utter://toggle-ai"))) == .toggleProcess)
        #expect(RemoteCommand(url: try #require(URL(string: "utter://settings"))) == .settings)
        #expect(RemoteCommand(url: try #require(URL(string: "utter://rm-rf"))) == nil)
        #expect(RemoteCommand(url: try #require(URL(string: "https://toggle"))) == nil)
    }

    @Test func launchOptions() {
        let o = LaunchOptions(arguments: ["Utter", "--start-hidden", "--no-tray", "--debug"])
        #expect(o.startHidden && o.noTray && o.debug)
        let none = LaunchOptions(arguments: ["Utter"])
        #expect(!none.startHidden && !none.noTray && !none.debug)
    }

    /// Settings saved before `allowURLCommands` existed still load (and keep the user's choices).
    @Test func olderGeneralSettingsStillLoad() throws {
        let old = #"{"appearance":"dark","showMenuBarIcon":false,"showSetupWhenNeeded":true}"#
        let s = try JSONDecoder().decode(GeneralSettings.self, from: Data(old.utf8))
        #expect(s.appearance == .dark && !s.showMenuBarIcon && !s.allowURLCommands)
    }
}
