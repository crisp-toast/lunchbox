import AppKit
import os

/// One running app we manage windows for. Every Accessibility call to the app
/// runs on its own serial queue, so a slow or hung app can only ever delay its
/// own windows, never the keyboard, the animations of other apps, or Tessel.
final class AppHandle {
    let pid: pid_t
    let bundleID: String?
    let element: AXUIElement
    let queue: DispatchQueue
    var observer: AXObserver?
    /// Window elements we've seen, so notifications about a destroyed element
    /// can still be matched to a window ID. Main thread only.
    var windowIDs: [AXUIElement: CGWindowID] = [:]
    var pendingScan: DispatchWorkItem?
    var observerAttempts = 0

    /// Rolling average of how long one Accessibility write takes, in seconds.
    private let latencyLock = OSAllocatedUnfairLock(initialState: 0.008)

    init(pid: pid_t, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.element = AXUIElementCreateApplication(pid)
        self.queue = DispatchQueue(label: "com.tyleryouens.tessel.app.\(pid)", qos: .userInteractive)
        AXUIElementSetMessagingTimeout(element, 0.5)
    }

    var latency: Double { latencyLock.withLock { $0 } }

    func recordLatency(_ seconds: Double) {
        latencyLock.withLock { $0 = $0 * 0.7 + seconds * 0.3 }
    }
}

final class WindowHandle {
    let id: CGWindowID
    let element: AXUIElement
    let app: AppHandle

    init(id: CGWindowID, element: AXUIElement, app: AppHandle) {
        self.id = id
        self.element = element
        self.app = app
        AXUIElementSetMessagingTimeout(element, 0.5)
    }
}
