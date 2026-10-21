import AppKit
import Sparkle

/// Auto-updates for copies sold from the website: Sparkle checks the appcast once a day,
/// asks before installing, and only accepts updates signed with LunchboxWM's update key
/// (SUPublicEDKey in Info.plist; the private key is in the release Mac's Keychain).
final class Updater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    /// The daily check (Settings › Check for Updates Automatically). Installing always asks.
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
