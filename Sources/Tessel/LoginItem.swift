import AppKit
import ServiceManagement

/// "Open at login", done as a launchd agent so Tessel also comes back by itself after a
/// crash, putting parked windows back where they belong (it doesn't after Quit).
enum LoginItem {
    static let label = "com.tyleryouens.tessel.agent"
    private static let agent = SMAppService.agent(plistName: label + ".plist")

    static var isEnabled: Bool { agent.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Earlier versions registered the app itself as the login item: switch to the agent, once.
    static func migrate() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        set(true)
    }

    /// Whether launchd started this copy (only then does it come back after a crash).
    static var startedByLaunchd: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    /// Opened by hand while the agent is on: have launchd run Tessel instead, so it's
    /// looked after, and step aside. Returns true if this copy should quit, only once
    /// launchd's copy is really running: opening Tessel must never end with no Tessel.
    static func handOff() -> Bool {
        guard !startedByLaunchd, isEnabled else { return false }
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        do { try kick.run() } catch { return false }
        kick.waitUntilExit()
        guard kick.terminationStatus == 0 else { return false }
        // launchd waits out ThrottleInterval (5 s) after its last copy exited (Tessel was
        // just quit, updated or reinstalled), so allow a little more than that.
        for _ in 0..<65 {
            if anotherProcessRunsThisApp() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        log.error("login item: launchd didn't start Tessel; running this copy instead")
        return false
    }

    /// Whether another process is running Tessel's executable. Unlike the list of running
    /// apps, this sees launchd's copy the moment it starts, before it has set itself up as an app.
    private static func anotherProcessRunsThisApp() -> Bool {
        guard let mine = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return false }
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, count)) where pid > 0 && pid != me {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if String(cString: path) == mine { return true }
        }
        return false
    }

    /// Another copy is running (a moment ago one may have been handing off to launchd and
    /// still be on its way out): wait briefly, then report whether one is still there.
    static func anotherCopyIsRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = { NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me && !$0.isTerminated } }
        for _ in 0..<30 where others() { Thread.sleep(forTimeInterval: 0.1) }
        return others()
    }
}
