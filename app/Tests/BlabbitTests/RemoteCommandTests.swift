import Foundation
import Testing
@testable import BlabbitKit

/// PARITY F14: Handy's CLI flags and blabbit:// links.
@Suite struct RemoteCommandTests {
    @Test func handyFlagsMapToCommands() {
        #expect(RemoteCommand(arguments: ["Blabbit", "--toggle-transcription"]) == .toggle)
        #expect(RemoteCommand(arguments: ["Blabbit", "--toggle-post-process"]) == .toggleProcess)
        #expect(RemoteCommand(arguments: ["Blabbit", "--cancel"]) == .cancel)
        #expect(RemoteCommand(arguments: ["Blabbit", "--start-transcription"]) == .start)
        #expect(RemoteCommand(arguments: ["Blabbit", "--stop-transcription"]) == .stop)
        #expect(RemoteCommand(arguments: ["Blabbit"]) == nil)
        #expect(RemoteCommand(arguments: ["Blabbit", "--start-hidden"]) == nil, "a launch option, not a command")
    }

    @Test func urlsMapToCommands() throws {
        #expect(RemoteCommand(url: try #require(URL(string: "blabbit://toggle"))) == .toggle)
        #expect(RemoteCommand(url: try #require(URL(string: "BLABBIT://Cancel"))) == .cancel)
        #expect(RemoteCommand(url: try #require(URL(string: "blabbit://toggle-ai"))) == .toggleProcess)
        #expect(RemoteCommand(url: try #require(URL(string: "blabbit://settings"))) == .settings)
        #expect(RemoteCommand(url: try #require(URL(string: "blabbit://rm-rf"))) == nil)
        #expect(RemoteCommand(url: try #require(URL(string: "https://toggle"))) == nil)
    }

    @Test func launchOptions() {
        let o = LaunchOptions(arguments: ["Blabbit", "--start-hidden", "--no-tray", "--debug"])
        #expect(o.startHidden && o.noTray && o.debug)
        let none = LaunchOptions(arguments: ["Blabbit"])
        #expect(!none.startHidden && !none.noTray && !none.debug)
    }

    /// Settings saved before `allowURLCommands` existed still load (and keep the user's choices).
    @Test func olderGeneralSettingsStillLoad() throws {
        let old = #"{"appearance":"dark","showMenuBarIcon":false,"showSetupWhenNeeded":true}"#
        let s = try JSONDecoder().decode(GeneralSettings.self, from: Data(old.utf8))
        #expect(s.appearance == .dark && !s.showMenuBarIcon && !s.allowURLCommands)
    }
}
