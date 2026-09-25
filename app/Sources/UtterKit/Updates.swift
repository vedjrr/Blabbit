import Foundation
import Sparkle

/// An administrator can turn update checks off (PARITY F23), as Handy's
/// `is_update_checks_locked` does: a managed (MDM profile) or
/// `defaults write dev.utter.mac UpdateChecksDisabled -bool true` value.
public enum UpdatePolicy {
    public static let key = "UpdateChecksDisabled"

    public static func isLocked(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    /// Set by a configuration profile rather than by the user.
    public static func isManaged(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.objectIsForced(forKey: key)
    }
}

/// Sparkle 2 updates (G7): an EdDSA-signed appcast on the GitHub releases page
/// (`SUFeedURL`, `SUPublicEDKey` in Info.plist). Network is used only for this
/// and model downloads (hard rule 5). Sparkle asks the user before turning on
/// automatic checks.
@MainActor
public final class Updates: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    /// True while dictating: a check then waits, so an update prompt never
    /// appears mid-sentence.
    public var isBusy: () -> Bool = { false }
    public let isLocked: Bool

    public init(defaults: UserDefaults = .standard) {
        isLocked = UpdatePolicy.isLocked(defaults)
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: !isLocked, updaterDelegate: self, userDriverDelegate: nil)
        if isLocked { Log.info("update checks turned off by \(UpdatePolicy.isManaged(defaults) ? "a managed profile" : "UpdateChecksDisabled")") }
    }

    public func checkForUpdates() {
        guard !isLocked else { return }
        controller.checkForUpdates(nil)
    }

    public var automaticallyChecks: Bool {
        get { !isLocked && controller.updater.automaticallyChecksForUpdates }
        set { if !isLocked { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    public nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let busy = MainActor.assumeIsolated { isBusy() }
        // Scheduled checks wait for the next cycle; a check the user asked for goes ahead.
        if busy && updateCheck == .updatesInBackground {
            throw NSError(domain: "dev.utter.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dictating; the check will run later."])
        }
    }
}
