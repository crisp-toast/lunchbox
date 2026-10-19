import AppKit

/// Lunchbox was called Tessel (com.tyleryouens.tessel) until it went on sale. On a Mac that had
/// Tessel, Lunchbox stops it whenever it starts, and the first time also takes over its settings
/// (license, trial, shortcuts, Workspaces, layouts) and what it learned. Tessel's login item keeps
/// coming back until Tessel.app is deleted (scripts/build.sh says so). Customers never had Tessel;
/// this is for the Macs Lunchbox was built and tested on.
///
/// Not carried over: Accessibility (macOS asks again for the new app; onboarding walks through
/// it) and the Keychain's copy of the trial's start (reading Tessel's item would ask for the
/// login password; `Licensing` writes it again from the settings).
enum OldAppID {
    static let id = "com.tyleryouens.tessel"
    private static let doneKey = "carriedOverFromTessel"

    /// Runs before anything else at launch, before the check for another copy.
    static func carryOver() {
        // Every launch: Tessel's login item comes back at each login (macOS reloads it for as long
        // as Tessel.app exists, even in the Trash), and two window managers fight.
        let hadLoginItem = stopTessel()
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        if let old = defaults.persistentDomain(forName: id), !old.isEmpty {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            log.notice("carried over \(old.count) settings from Tessel")
        }
        // Lunchbox opens at login where Tessel did: set up like a first launch, once it's running.
        if hadLoginItem { defaults.removeObject(forKey: "loginItemConfigured") }

        // What it learned, its window classes and its state (Learning, classes.json…).
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let from = support.appendingPathComponent("Tessel"), to = support.appendingPathComponent("Lunchbox")
        if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
            do {
                try FileManager.default.moveItem(at: from, to: to)
                log.notice("moved Tessel's Application Support folder to Lunchbox's")
            } catch {
                log.error("couldn't move Tessel's Application Support folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Stops Tessel and unloads its login item, if either is there (Tessel puts parked windows
    /// back when it's told to stop). Returns whether the login item was loaded.
    private static func stopTessel() -> Bool {
        let agent = "gui/\(getuid())/\(id).agent"
        let loaded = launchctl("print", agent)
        if loaded { _ = launchctl("bootout", agent) }
        // A Tessel opened by hand: ask it to quit, as ⌘Q would.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.1) }
        if loaded || !running.isEmpty { log.notice("stopped Tessel") }
        return loaded
    }

    private static func launchctl(_ arguments: String...) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
