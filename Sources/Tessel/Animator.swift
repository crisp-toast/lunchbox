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
        /// Its final size at once, then a slide into place: for a window that keeps its own
        /// size or shape, which would jitter if resized every frame.
        case slide
        case snap
        /// Bringing a parked window back into view: its size is set while it's still out of
        /// sight, then it moves in.
        case reveal
        /// Parking a window off screen: only its position changes.
        case positionOnly
    }

    static let duration: CFTimeInterval = 0.2
    static let frameInterval: CFTimeInterval = 1.0 / 60
    static let fullAnimationLatency = 0.006
    static let slideLatency = 0.030
    /// A frame this slow means the app stalls: a glide through it would stop and jump. An app
    /// whose calls took half that lately can't keep a glide going either.
    static let stallLatency = 0.040
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
        var finishNow = false
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
    /// The newest move for each window, readable from the window queues so a
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

        let snaps = (kind != .animate && kind != .slide) || latency > Self.slideLatency || window.app.slowest > Self.stallLatency / 2
            || start.isClose(to: to, tolerance: 1)
        guard !snaps else {
            running[window.id] = nil
            window.queue.async { [weak self] in
                self?.place(window, at: to, positionOnly: kind == .positionOnly, sizeFirst: kind == .reveal, token: token, attempt: 0)
            }
            return
        }
        // Its clock starts a frame back, so the frame sent right away is already a step on the way
        // (at zero it would only repeat where the window is, and the first step would wait a frame).
        running[window.id] = Animation(
            window: window, from: start, to: to, start: now - Self.frameInterval,
            resizeEveryFrame: kind == .animate && latency < Self.fullAnimationLatency, token: token,
            sizeSent: start.size == to.size
        )
    }

    private func tick() {
        let now = CACurrentMediaTime()
        for (id, var anim) in running where !anim.inFlight && !anim.finalSent {
            let isFinal = now - anim.start >= Self.duration || anim.finishNow
            let frame = isFinal ? anim.to : anim.frame(at: now)
            let sendSize: CGSize? = anim.resizeEveryFrame ? frame.size : (anim.sizeSent ? nil : anim.to.size)
            anim.sizeSent = true
            anim.inFlight = true
            anim.finalSent = isFinal
            running[id] = anim

            let window = anim.window, token = anim.token
            window.queue.async { [weak self] in
                guard let self else { return }
                if isFinal {
                    self.place(window, at: frame, positionOnly: false, token: token, attempt: 0)
                    self.queue.async { self.finished(id, token: token, stalled: false) }
                } else {
                    let t0 = CACurrentMediaTime()
                    if let size = sendSize { window.element.setSize(size) }
                    window.element.setPosition(frame.origin)
                    let took = CACurrentMediaTime() - t0
                    window.app.recordLatency(took, calls: sendSize == nil ? 1 : 2)
                    self.queue.async { self.finished(id, token: token, stalled: took > Self.stallLatency) }
                }
            }
        }
    }

    /// Runs on the window's queue: sets the final frame, reads it back, and
    /// retries a few times if the window didn't get there.
    private func place(_ window: WindowHandle, at target: CGRect, positionOnly: Bool, sizeFirst: Bool = false, token: UInt64, attempt: Int) {
        guard latest.withLock({ $0[window.id] }) == token else { return } // a newer move took over
        let element = window.element
        let t0 = CACurrentMediaTime()
        let actual: CGRect?
        if positionOnly {
            element.setPosition(target.origin)
            actual = element.frame
        } else {
            // A window that won't take this size sits centered on its slot (until Tessel learns
            // what it takes), not in its corner.
            actual = element.place(in: target, sizeFirst: sizeFirst)
        }
        window.app.recordLatency(CACurrentMediaTime() - t0, calls: positionOnly ? 3 : 4)
        // Parking only needs the window pushed off the right edge (macOS may clamp its
        // height); a normal move needs it centered where it was sent.
        let landed: Bool = actual.map { a in
            positionOnly ? a.minX >= target.minX - 2
                : abs(a.midX - target.midX) <= 2 && abs(a.midY - target.midY) <= 2
        } ?? false
        if !landed, attempt < Self.retryDelays.count {
            window.queue.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
                self?.place(window, at: target, positionOnly: positionOnly, sizeFirst: sizeFirst, token: token, attempt: attempt + 1)
            }
            return
        }
        if !landed {
            log.error("window \(window.id) (\(window.app.bundleID ?? "?", privacy: .public)) didn't move to \(NSStringFromRect(target), privacy: .public); it's at \(actual.map { NSStringFromRect($0) } ?? "unknown", privacy: .public)")
        }
        DispatchQueue.main.async { [weak self] in self?.onSettled?(window.id, actual, landed) }
    }

    /// - stalled: the app took so long over that frame that the glide stopped on screen. The
    ///   rest of it would only stop and jump again, so the window goes the rest of the way at once.
    private func finished(_ id: CGWindowID, token: UInt64, stalled: Bool) {
        guard var anim = running[id], anim.token == token else { return }
        if anim.finalSent {
            running[id] = nil
        } else {
            anim.inFlight = false
            if stalled { anim.finishNow = true }
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
            t.schedule(deadline: .now() + .milliseconds(16), repeating: .nanoseconds(Int(Self.frameInterval * 1e9)), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }
}
