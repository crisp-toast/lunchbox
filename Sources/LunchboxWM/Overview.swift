import AppKit

private func overviewCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<DockOverview>.fromOpaque(refcon).takeUnretainedValue().received(notification as String)
}

/// Mission Control, App Exposé and Show Desktop. While one is up, windows go out of sight without
/// going anywhere (App Exposé hides every other app's), so they keep their tiles. The Dock draws
/// them and says when, through Accessibility notifications of its own (yabai listens for the same).
final class DockOverview {
    static let shown = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]
    static let exit = "AXExposeExit"
    /// After the Dock says it's done, its windows take this long to fly back.
    static let exitSeconds = 0.4
    /// Taken as over after this long without the Dock saying so, in case it never does.
    static let longest: CFTimeInterval = 180

    /// Called on the main thread when it ends, with the windows back in place.
    var onEnd: (() -> Void)?

    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var since: CFTimeInterval?
    private var ending: DispatchWorkItem?

    var isActive: Bool {
        guard let since else { return false }
        return CACurrentMediaTime() - since < Self.longest
    }

    /// Listens to the Dock that's running now (again after it restarts).
    func attach() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first(where: { !$0.isTerminated }) else { return }
        guard observer == nil || dock.processIdentifier != pid else { return }
        detach()
        var created: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, overviewCallback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let results = (Self.shown + [Self.exit]).map { AXObserverAddNotification(created, element, $0 as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        pid = dock.processIdentifier
        log.notice("watching the Dock for Mission Control: \(results.map { String($0.rawValue) }.joined(separator: " "), privacy: .public)")
    }

    func detach() {
        ending?.cancel()
        ending = nil
        since = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        pid = 0
    }

    fileprivate func received(_ name: String) {
        if name == Self.exit {
            guard since != nil else { return }
            ending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.ending = nil
                self.since = nil
                log.notice("Mission Control is over")
                self.onEnd?()
            }
            ending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitSeconds, execute: work)
            return
        }
        ending?.cancel()
        ending = nil
        if since == nil { log.notice("\(name, privacy: .public): windows out of sight keep their tiles") }
        since = CACurrentMediaTime()
    }
}
