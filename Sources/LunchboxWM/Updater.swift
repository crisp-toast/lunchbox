import AppKit
import Sparkle

/// Auto-updates for copies sold from the website: Sparkle checks the appcast about once an hour,
/// asks before installing, and only accepts updates signed with LunchboxWM's update key
/// (SUPublicEDKey in Info.plist; the private key is in the release Mac's Keychain).
/// While a newer version is out, `available` names it and the menu bar icon wears an orange dot,
/// until it's installed or skipped, across relaunches too.
final class Updater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    /// The newer version found ("1.4"), or nil.
    private(set) var available: String? {
        didSet { if available != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    private static let key = "updateAvailable"

    override init() {
        super.init()
        // Only the store's copy updates itself: one built from the source would be replaced by the
        // store's, which asks for a license.
        controller = SPUStandardUpdaterController(startingUpdater: Build.isStoreCopy, updaterDelegate: self, userDriverDelegate: nil)
        // Found before a relaunch, and still newer than this copy.
        let saved = UserDefaults.standard.dictionary(forKey: Self.key)
        if Build.isStoreCopy, let build = saved?["build"] as? String, let name = saved?["name"] as? String, Self.isNewer(build) {
            available = name
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }

    var canCheck: Bool { Build.isStoreCopy && controller.updater.canCheckForUpdates }

    /// The hourly check (Settings › Check for Updates Automatically). Installing always asks.
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() {
        guard Build.isStoreCopy else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private static func isNewer(_ build: String) -> Bool {
        let current = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return SUStandardVersionComparator.default.compareVersion(build, toVersion: current) == .orderedDescending
    }

    private func found(_ item: SUAppcastItem) {
        guard Self.isNewer(item.versionString) else { return forget() }
        UserDefaults.standard.set(["build": item.versionString, "name": item.displayVersionString], forKey: Self.key)
        available = item.displayVersionString
    }

    private func forget() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        available = nil
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        found(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        forget()
    }

    /// Skip This Version: no dot for it. Install, or Remind Me Later, keeps it until it's in.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip { forget() }
    }
}
