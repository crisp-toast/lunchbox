import AppKit
import os

/// One running app we manage windows for. Every Accessibility call to the app
/// runs on its own serial queue, so a slow or hung app can only ever delay its
/// own windows, never the keyboard, the animations of other apps, or LunchboxWM.
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

    /// How long one Accessibility write takes, in seconds: a rolling average, and the slowest
    /// lately (per call of a move, fading with every move after it).
    private let latencyLock = OSAllocatedUnfairLock(initialState: (average: 0.008, slowest: 0.0))

    init(pid: pid_t, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.element = AXUIElementCreateApplication(pid)
        self.queue = DispatchQueue(label: "com.sentientdonut.lunchbox.app.\(pid)", qos: .userInteractive)
        AXUIElementSetMessagingTimeout(element, 0.5)
    }

    var latency: Double { latencyLock.withLock { $0.average } }
    /// An app that's quick on average can still stall now and then (busy, or Arc at times): a
    /// glide through it would stop and jump, so it's placed in one go instead.
    var slowest: Double { latencyLock.withLock { $0.slowest } }

    /// - took: how long a whole move (or read) took, `calls` Accessibility calls.
    func recordLatency(_ took: Double, calls: Int) {
        latencyLock.withLock {
            $0.average = $0.average * 0.7 + took / Double(max(1, calls)) * 0.3
            $0.slowest = max($0.slowest * 0.85, took / Double(max(1, calls)))
        }
    }
}

final class WindowHandle {
    let id: CGWindowID
    let element: AXUIElement
    let app: AppHandle
    /// Moves of this window, in order. Each window has its own, so an app's windows move
    /// together: its calls arrive back to back and the app answers them in one go, where one
    /// queue per app made a slow app's windows land one after another.
    let queue: DispatchQueue

    init(id: CGWindowID, element: AXUIElement, app: AppHandle) {
        self.id = id
        self.element = element
        self.app = app
        self.queue = Self.queue(for: id)
        AXUIElementSetMessagingTimeout(element, 0.5)
    }

    private static let queues = OSAllocatedUnfairLock(initialState: [CGWindowID: DispatchQueue]())

    /// The queue a window's moves go through, the same for every handle to it (a window
    /// placed before LunchboxWM registers it, then moved by the layout).
    static func queue(for id: CGWindowID) -> DispatchQueue {
        queues.withLock { queues in
            if let queue = queues[id] { return queue }
            let queue = DispatchQueue(label: "com.sentientdonut.lunchbox.window.\(id)", qos: .userInteractive)
            queues[id] = queue
            return queue
        }
    }

    /// The window is gone.
    static func forget(_ id: CGWindowID) { _ = queues.withLock { $0.removeValue(forKey: id) } }
}
