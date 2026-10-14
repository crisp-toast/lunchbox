import AppKit
import QuartzCore

/// Moves real windows, smoothly where the app can keep up and instantly where it can't.
///
/// Each app's measured response time picks the style per window:
/// - fast apps (< 6 ms a call) slide and resize every frame;
/// - slower apps get their final size once and then slide into place;
/// - apps slower than 30 ms just snap, so a struggling app never adds lag.
/// A frame is skipped rather than queued while the previous one is still
/// being applied, so the window always heads for the newest target.
final class Animator {
    enum Kind {
        case animate
        case snap
        case positionOnly
    }

    static let duration: CFTimeInterval = 0.2
    static let fullAnimationLatency = 0.006
    static let slideLatency = 0.030

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
        let latency = window.app.latency
        var start = from
        if let existing = running[window.id] { start = existing.frame(at: now) }

        let snaps = kind != .animate || latency > Self.slideLatency || start.isClose(to: to, tolerance: 1)
        guard !snaps else {
            running[window.id] = nil
            let element = window.element, app = window.app
            app.queue.async {
                let t0 = CACurrentMediaTime()
                if kind == .positionOnly { element.setPosition(to.origin) } else { element.setFrame(to) }
                app.recordLatency((CACurrentMediaTime() - t0) / (kind == .positionOnly ? 1 : 2))
            }
            return
        }
        let resizeEveryFrame = latency < Self.fullAnimationLatency
        running[window.id] = Animation(
            window: window, from: start, to: to, start: now,
            resizeEveryFrame: resizeEveryFrame, token: nextToken,
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

            let element = anim.window.element, app = anim.window.app, token = anim.token, to = anim.to
            app.queue.async { [weak self] in
                let t0 = CACurrentMediaTime()
                var calls = 1.0
                if isFinal {
                    element.setFrame(to)
                    calls = 2
                } else {
                    if let size = sendSize { element.setSize(size); calls = 2 }
                    element.setPosition(frame.origin)
                }
                app.recordLatency((CACurrentMediaTime() - t0) / calls)
                self?.queue.async { self?.finished(id, token: token) }
            }
        }
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
