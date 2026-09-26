import Foundation
import Testing
@testable import SayLessKit

/// PARITY F14: Handy's CLI flags and sayless:// links.
@Suite struct RemoteCommandTests {
    @Test func handyFlagsMapToCommands() {
        #expect(RemoteCommand(arguments: ["Say Less", "--toggle-transcription"]) == .toggle)
        #expect(RemoteCommand(arguments: ["Say Less", "--toggle-post-process"]) == .toggleProcess)
        #expect(RemoteCommand(arguments: ["Say Less", "--cancel"]) == .cancel)
        #expect(RemoteCommand(arguments: ["Say Less", "--start-transcription"]) == .start)
        #expect(RemoteCommand(arguments: ["Say Less", "--stop-transcription"]) == .stop)
        #expect(RemoteCommand(arguments: ["Say Less"]) == nil)
        #expect(RemoteCommand(arguments: ["Say Less", "--start-hidden"]) == nil, "a launch option, not a command")
    }

    @Test func urlsMapToCommands() throws {
        #expect(RemoteCommand(url: try #require(URL(string: "sayless://toggle"))) == .toggle)
        #expect(RemoteCommand(url: try #require(URL(string: "SAYLESS://Cancel"))) == .cancel)
        #expect(RemoteCommand(url: try #require(URL(string: "sayless://toggle-ai"))) == .toggleProcess)
        #expect(RemoteCommand(url: try #require(URL(string: "sayless://settings"))) == .settings)
        #expect(RemoteCommand(url: try #require(URL(string: "sayless://rm-rf"))) == nil)
        #expect(RemoteCommand(url: try #require(URL(string: "https://toggle"))) == nil)
    }

    @Test func launchOptions() {
        let o = LaunchOptions(arguments: ["Say Less", "--start-hidden", "--no-tray", "--debug"])
        #expect(o.startHidden && o.noTray && o.debug)
        let none = LaunchOptions(arguments: ["Say Less"])
        #expect(!none.startHidden && !none.noTray && !none.debug)
    }

    /// Settings saved before `allowURLCommands` existed still load (and keep the user's choices).
    @Test func olderGeneralSettingsStillLoad() throws {
        let old = #"{"appearance":"dark","showMenuBarIcon":false,"showSetupWhenNeeded":true}"#
        let s = try JSONDecoder().decode(GeneralSettings.self, from: Data(old.utf8))
        #expect(s.appearance == .dark && !s.showMenuBarIcon && !s.allowURLCommands)
    }
}
