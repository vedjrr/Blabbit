import Foundation
import Sparkle

/// Sparkle 2 updates (G7): an EdDSA-signed appcast on the GitHub releases page
/// (`SUFeedURL`, `SUPublicEDKey` in Info.plist). Network is used only for this
/// and model downloads (hard rule 5). Sparkle asks the user before turning on
/// automatic checks.
@MainActor
public final class Updates {
    private let controller: SPUStandardUpdaterController

    public init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    public var canCheck: Bool { controller.updater.canCheckForUpdates }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    public var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
