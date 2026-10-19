import AppKit
import OSLog
import LunchboxCore

/// Settings › Copy Diagnostics: puts a `SupportSummary` on the clipboard for someone writing to
/// support, and says so with a quiet line.
enum SupportDiagnostics {
    private static let line = QuietLineView()

    static func copy(tiler: Tiler, licensing: Licensing, trusted: Bool) {
        var summary = gather(tiler: tiler, licensing: licensing, trusted: trusted)
        // Reading the log can take a moment; the rest is read now, on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let errors = recentErrors()
            let readMs = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                summary.errors = errors
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(summary.text, forType: .string)
                log.notice("copied diagnostics (read the log in \(readMs) ms)")
                line.show("Diagnostics copied. Paste them into an email to support@sentientdonut.com.", on: nil, seconds: 4)
            }
        }
    }

    private static func gather(tiler: Tiler, licensing: Licensing, trusted: Bool) -> SupportSummary {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osBuild = sysctl("kern.osversion").map { " (\($0))" } ?? ""
        let model = sysctl("hw.model") ?? "unknown Mac"

        let license: String
        if licensing.license != nil {
            license = "licensed"
        } else {
            let started = licensing.trialStart.map { ", started \($0.formatted(.iso8601.year().month().day()))" } ?? ""
            switch licensing.trial {
            case .active(let days): license = "free trial, \(days) day\(days == 1 ? "" : "s") left\(started)"
            case .ended: license = "free trial ended\(started)"
            }
        }

        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        let settings = [
            "Accessibility: \(trusted ? "allowed" : "not allowed")",
            "Screen Recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed")",
            "tiling: \(tiler.enabled ? "on" : "paused")",
            "Use All Displays: \(onOff(tiler.useAllDisplays))",
            "Learn Where Windows Go: \(onOff(Learning.shared.isOn))",
            "Launch at Login: \(onOff(LoginItem.isEnabled))",
        ]

        let scales = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, Double)? in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, Double(screen.backingScaleFactor))
        }, uniquingKeysWith: { a, _ in a })
        let screens = Display.current().map { d in
            SupportSummary.Screen(name: d.name, frame: d.frame, visible: d.visible, scale: scales[d.id] ?? 1,
                                  isMain: d.isMain, tiled: tiler.useAllDisplays || d.isMain)
        }

        let windows = tiler.supportWindows()
        return SupportSummary(
            app: "Lunchbox \(version) (\(build)), \(Build.name)",
            system: "macOS \(os.majorVersion).\(os.minorVersion)\(os.patchVersion > 0 ? ".\(os.patchVersion)" : "")\(osBuild), \(model)",
            license: license, settings: settings, screens: screens,
            currentWorkspace: tiler.currentSpace + 1, workspaces: windows.workspaces, untiled: windows.untiled
        )
    }

    /// Lunchbox's errors and faults from the last day (since it started, if that's sooner: the log
    /// only gives a process its own), the latest `limit` of them, oldest first, each through
    /// `SupportSummary.scrub`. A day keeps the read quick in a Lunchbox that has run for weeks.
    private static func recentErrors(limit: Int = 30) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-86_400))
            let entries = try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@", logSubsystem))
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "MM-dd HH:mm:ss"
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries where entry.level == .error || entry.level == .fault {
                lines.append("\(stamp.string(from: entry.date)) \(entry.category): \(SupportSummary.scrub(entry.composedMessage))")
                if lines.count > limit { lines.removeFirst() }
            }
            return lines
        } catch {
            return ["couldn't read Lunchbox's log: \(SupportSummary.scrub(error.localizedDescription))"]
        }
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
