import AppKit
import Darwin

/// Where Lunchbox runs from. It belongs in an Applications folder: run from its disk image, it
/// stops when the image is ejected, can't update itself, and would try to open at login from a
/// disk that's gone. And dragged to the Trash, it should stop and stop opening at login, or
/// launchd keeps starting it from the Trash.
enum Install {
    private static let appName = "LunchboxWM.app"
    private static let declinedKey = "moveToApplicationsDeclined"
    /// The app as launched, followed if it's moved while running.
    private static let reference = (Bundle.main.bundleURL as NSURL).fileReferenceURL() as NSURL?
    private static var watcher: DispatchSourceFileSystemObject?

    /// Whether a path is in a Trash (the home folder's or another volume's).
    static func inTrash(_ path: String) -> Bool {
        let parts = (path as NSString).pathComponents
        return parts.contains(".Trash") || parts.contains(".Trashes")
    }

    static func inApplications(_ path: String) -> Bool {
        let parts = (path as NSString).pathComponents
        return parts.contains("Applications")
    }

    // MARK: The Trash

    /// Started from the Trash (launchd starting a login item whose app was thrown away, or a
    /// double click in the Trash): stop opening at login if that's where the login item points,
    /// and quit. Call before anything else runs.
    static func quitIfInTrash() {
        guard inTrash(Bundle.main.bundlePath) else { return }
        log.notice("started from the Trash; quitting")
        let registered = UserDefaults.standard.string(forKey: "loginItemRegisteredFrom")
        if LoginItem.startedByLaunchd || registered.map({ !FileManager.default.fileExists(atPath: $0) }) ?? false {
            stopOpeningAtLogin()
        }
        exit(0)
    }

    /// Calls `trashed` when the app is dragged to the Trash (or deleted) while running.
    static func watchForTrash(_ trashed: @escaping () -> Void) {
        let fd = open(Bundle.main.bundlePath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.rename, .delete], queue: .main)
        source.setEventHandler {
            // Renamed or moved somewhere else is fine (the login item follows it at next launch).
            if let now = reference?.filePathURL?.path, !inTrash(now) { return }
            source.cancel()
            trashed()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Thrown away: no more opening at login. A copy installed again later opens at login again.
    static func stopOpeningAtLogin() {
        if LoginItem.isEnabled { LoginItem.set(false) }
        UserDefaults.standard.set(false, forKey: "loginItemConfigured")
    }

    // MARK: Applications

    /// Running from a disk image, Downloads or anywhere outside an Applications folder: offers to
    /// move to Applications, and if so copies itself there, opens that copy and returns true
    /// (this copy should quit). Asks once for a copy that isn't on a disk image.
    static func offerMoveToApplications() -> Bool {
        let running = Bundle.main.bundlePath
        let original = originalPath(of: Bundle.main.bundleURL) ?? running
        guard !inApplications(original), !inTrash(original) else { return false }
        let diskImage = volume(of: original).flatMap { DiskImages.isMounted(named: ($0 as NSString).lastPathComponent) ? $0 : nil }
        if diskImage == nil, UserDefaults.standard.string(forKey: declinedKey) == original { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Lunchbox to Applications?"
        alert.informativeText = diskImage != nil
            ? "Lunchbox is running from its disk image. In your Applications folder, it keeps running after you eject the image, opens at login and keeps itself up to date."
            : "Lunchbox opens at login and keeps itself up to date from your Applications folder."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(original, forKey: declinedKey)
            return false
        }

        guard let moved = copyToApplications(from: Bundle.main.bundleURL) else { return false }
        log.notice("moved to \(moved.path, privacy: .public)")
        // Only one Lunchbox runs at a time, so the new copy opens once this one is gone; then the
        // disk image, with nothing left to do, is ejected.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"; "
            + "if [ -n \"$2\" ]; then /bin/sleep 2; /usr/bin/hdiutil detach \"$2\" -quiet; fi",
            moved.path, String(getpid()), diskImage ?? ""]
        do { try relaunch.run() } catch { return false }
        NSApp.terminate(nil)
        return true
    }

    /// Copies the app into /Applications (or ~/Applications, for an account that can't write
    /// there), replacing an older copy, which goes to the Trash. Nil, after saying why, if it can't.
    private static func copyToApplications(from source: URL) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        var lastError: Error?
        for folder in [URL(fileURLWithPath: "/Applications"), home] {
            let target = folder.appendingPathComponent(appName)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
                try fm.copyItem(at: source, to: target)
                // The same notarized app was just opened: don't have macOS ask about it again.
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-dr", "com.apple.quarantine", target.path]
                try? xattr.run()
                xattr.waitUntilExit()
                return target
            } catch {
                lastError = error
            }
        }
        let alert = NSAlert()
        alert.messageText = "Lunchbox couldn't move itself"
        alert.informativeText = "Drag it to your Applications folder in the Finder, then open it from there. (\(lastError?.localizedDescription ?? "Unknown error"))"
        alert.runModal()
        return nil
    }

    /// "/Volumes/Name" for a path on another volume, else nil.
    private static func volume(of path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard parts.count > 2, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return "/Volumes/" + parts[2]
    }

    /// Where a quarantined app really is when macOS runs it from a hidden copy (App
    /// Translocation), from Security's SecTranslocate functions; nil when it isn't translocated.
    private static func originalPath(of url: URL) -> String? {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let all = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let isSym = dlsym(all, "SecTranslocateIsTranslocatedURL"),
              let originalSym = dlsym(all, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let isTranslocated = unsafeBitCast(isSym, to: IsTranslocated.self)
        let original = unsafeBitCast(originalSym, to: Original.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil), translocated,
              let path = original(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (path as URL).path
    }
}
