import AppKit

/// Start Fresh, setup's other choice for a messy desktop: closes every window the way its red
/// button would, so apps still ask before closing anything unsaved, and nothing is forced. It
/// never quits an app, and leaves alone windows with no close button and Lunchbox's own.
enum StartFresh {
    struct Window {
        let pid: pid_t
        let element: AXUIElement
        let frame: CGRect?
    }

    /// Every window it would close (only `bundleID`'s, for tests), read off the main thread;
    /// `done` gets them on the main thread.
    static func windows(onlyApp bundleID: String? = nil, then done: @escaping ([Window]) -> Void) {
        let me = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && (bundleID == nil || $0.bundleIdentifier == bundleID)
        }.map(\.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {
            // An app that's stuck answers within a second or is skipped, never holding up the rest.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
            let lock = NSLock()
            var found: [Window] = []
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                let mine = closable(of: apps[i]).map { Window(pid: apps[i], element: $0, frame: $0.frame) }
                lock.lock()
                found += mine
                lock.unlock()
            }
            DispatchQueue.main.async { done(found) }
        }
    }

    /// Presses each window's close button, an app's windows one after another and the apps at the
    /// same time; a moment later counts the ones still open (an app asking to save, say). `done`
    /// runs on the main thread.
    static func close(_ windows: [Window], then done: @escaping (_ closed: Int, _ stillOpen: Int) -> Void) {
        let byApp = Dictionary(grouping: windows, by: \.pid)
        let group = DispatchGroup()
        for list in byApp.values {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for w in list {
                    if let button = w.element.element(kAXCloseButtonAttribute) {
                        AXUIElementPerformAction(button, kAXPressAction as CFString)
                    }
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            // Apps close their windows a beat after the press; give them a moment.
            Thread.sleep(forTimeInterval: 1.5)
            var open = 0
            for (pid, list) in byApp {
                let now = AXUIElement.application(pid).elements(kAXWindowsAttribute)
                open += list.filter { w in now.contains { CFEqual($0, w.element) } }.count
            }
            DispatchQueue.main.async { done(windows.count - open, open) }
        }
    }

    /// An app's standard windows that have a close button.
    private static func closable(of pid: pid_t) -> [AXUIElement] {
        AXUIElement.application(pid).elements(kAXWindowsAttribute).filter { w in
            w.subrole == kAXStandardWindowSubrole as String && w.element(kAXCloseButtonAttribute) != nil
        }
    }
}
