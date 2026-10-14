import AppKit
import os
import QuartzCore

/// Moves real windows, smoothly where the app can keep up and instantly where it can't.
///
/// Each app's measured response time picks the style per window:
/// - fast apps (< 6 ms a call) slide and resize every frame;
/// - slower apps get their final size once and then slide into place;
/// - apps slower than 30 ms just snap, so a struggling app never adds lag.
/// A frame is skipped rather than queued while the previous one is still
/// being applied, so the window always heads for the newest target.
///
/// Every final placement is read back. An app that's busy or swapped out can
/// time out and silently ignore a move, which used to leave Tessel believing a
/// window was somewhere it wasn't. Now the move is retried, and the frame the
/// window really ended up with is reported through `onSettled`.
final class Animator {
    enum Kind {
        case animate
        case snap
        /// Parking a window off screen: only its position changes.
        case positionOnly
    }

    static let duration: CFTimeInterval = 0.2
    static let fullAnimationLatency = 0.006
    static let slideLatency = 0.030
    static let retryDelays: [Double] = [0.1, 0.25, 0.6]

    /// Called on the main thread with the frame a window really settled at
    /// (nil if the app didn't answer).
    var onSettled: ((CGWindowID, CGRect?, _ landed: Bool) -> Void)?

    private struct Animation {
        let window: WindowHandle
        let from: CGRect
        let to: CGRect
        let start: CFTimeInterval
        let resizeEveryFrame: Bool
        let token: UInt64
        var sizeSent: Bool
        var inFlight = false
        var finalSent = false

        func frame(at now: CFTimeInterval) -> CGRect {
            let t = min(1, max(0, (now - start) / Animator.duration))
            let e = 1 - pow(1 - t, 3) // ease-out cubic: most of the move happens right away
            return CGRect(
                x: (from.minX + (to.minX - from.minX) * e).rounded(),
                y: (from.minY + (to.minY - from.minY) * e).rounded(),
                width: (from.width + (to.width - from.width) * e).rounded(),
                height: (from.height + (to.height - from.height) * e).rounded()
            )
        }
    }

    private let queue = DispatchQueue(label: "com.tyleryouens.tessel.animator", qos: .userInteractive)
    private var running: [CGWindowID: Animation] = [:]
    private var timer: DispatchSourceTimer?
    private var nextToken: UInt64 = 0
    /// The newest move for each window, readable from the app queues so a
    /// retry never overrides a later move.
    private let latest = OSAllocatedUnfairLock(initialState: [CGWindowID: UInt64]())

    func run(_ moves: [(window: WindowHandle, from: CGRect, to: CGRect, kind: Kind)]) {
        guard !moves.isEmpty else { return }
        queue.async { [self] in
            let now = CACurrentMediaTime()
            for move in moves { schedule(move.window, from: move.from, to: move.to, kind: move.kind, now: now) }
            tick()
            updateTimer()
        }
    }

    private func schedule(_ window: WindowHandle, from: CGRect, to: CGRect, kind: Kind, now: CFTimeInterval) {
        nextToken &+= 1
        let token = nextToken
        latest.withLock { $0[window.id] = token }
        let latency = window.app.latency
        var start = from
        if let existing = running[window.id] { start = existing.frame(at: now) }

        let snaps = kind != .animate || latency > Self.slideLatency || start.isClose(to: to, tolerance: 1)
        guard !snaps else {
            running[window.id] = nil
            window.app.queue.async { [weak self] in
                self?.place(window, at: to, positionOnly: kind == .positionOnly, token: token, attempt: 0)
            }
            return
        }
        running[window.id] = Animation(
            window: window, from: start, to: to, start: now,
            resizeEveryFrame: latency < Self.fullAnimationLatency, token: token,
            sizeSent: start.size == to.size
        )
    }

    private func tick() {
        let now = CACurrentMediaTime()
        for (id, var anim) in running where !anim.inFlight && !anim.finalSent {
            let isFinal = now - anim.start >= Self.duration
            let frame = isFinal ? anim.to : anim.frame(at: now)
            let sendSize: CGSize? = anim.resizeEveryFrame ? frame.size : (anim.sizeSent ? nil : anim.to.size)
            anim.sizeSent = true
            anim.inFlight = true
            anim.finalSent = isFinal
            running[id] = anim

            let window = anim.window, token = anim.token
            window.app.queue.async { [weak self] in
                guard let self else { return }
                if isFinal {
                    self.place(window, at: frame, positionOnly: false, token: token, attempt: 0)
                } else {
                    let t0 = CACurrentMediaTime()
                    if let size = sendSize { window.element.setSize(size) }
                    window.element.setPosition(frame.origin)
                    window.app.recordLatency((CACurrentMediaTime() - t0) / (sendSize == nil ? 1 : 2))
                }
                self.queue.async { self.finished(id, token: token) }
            }
        }
    }

    /// Runs on the window's app queue: sets the final frame, reads it back, and
    /// retries a few times if the window didn't get there.
    private func place(_ window: WindowHandle, at target: CGRect, positionOnly: Bool, token: UInt64, attempt: Int) {
        guard latest.withLock({ $0[window.id] }) == token else { return } // a newer move took over
        let element = window.element
        let t0 = CACurrentMediaTime()
        if positionOnly { element.setPosition(target.origin) } else { element.setFrame(target) }
        window.app.recordLatency((CACurrentMediaTime() - t0) / (positionOnly ? 1 : 2))

        let actual = element.frame
        // Parking only needs the window pushed off the right edge (macOS may clamp
        // its height); a normal move needs its position to land. Size may differ
        // when an app enforces a minimum or maximum size, and that's fine.
        let landed: Bool = actual.map { a in
            positionOnly ? a.minX >= target.minX - 2
                : abs(a.minX - target.minX) <= 2 && abs(a.minY - target.minY) <= 2
        } ?? false
        if !landed, attempt < Self.retryDelays.count {
            window.app.queue.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
                self?.place(window, at: target, positionOnly: positionOnly, token: token, attempt: attempt + 1)
            }
            return
        }
        if !landed {
            log.error("window \(window.id) (\(window.app.bundleID ?? "?", privacy: .public)) didn't move to \(NSStringFromRect(target), privacy: .public); it's at \(actual.map { NSStringFromRect($0) } ?? "unknown", privacy: .public)")
        }
        DispatchQueue.main.async { [weak self] in self?.onSettled?(window.id, actual, landed) }
    }

    private func finished(_ id: CGWindowID, token: UInt64) {
        guard var anim = running[id], anim.token == token else { return }
        if anim.finalSent {
            running[id] = nil
        } else {
            anim.inFlight = false
            running[id] = anim
        }
        updateTimer()
    }

    private func updateTimer() {
        if running.isEmpty {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(16), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }
}
