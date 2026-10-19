import AppKit
import QuartzCore
import LunchboxCore

private func overlayPanel(frame: NSRect) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    return panel
}

private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// A thin accent-colored outline that glides to the window that just got focus
/// (or just moved) and fades away. Drawn by Core Animation in a click-through
/// overlay, so it costs the apps nothing.
final class FocusRing {
    private var panels: [CGDirectDisplayID: (panel: NSPanel, ring: CALayer)] = [:]
    private var shownOn: CGDirectDisplayID?
    private var fade: DispatchWorkItem?

    var isShowing: Bool { shownOn != nil }

    /// - color: the accent color, or green while resize mode works on the window.
    /// - hold: stay until `hide()` instead of fading after a moment.
    func flash(_ frame: CGRect, on displays: [Display], color: NSColor = .controlAccentColor, hold: Bool = false) {
        guard let display = displays.first(where: { $0.frame.contains(frame.center) }) ?? displays.first,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
              })
        else { return }
        let (panel, ring) = overlay(for: display.id, screen: screen)
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }

        // Window frames are top-left based; the overlay's layers are bottom-left
        // based (AppKit owns a layer-backed view's flip, so asking it to flip
        // doesn't stick). Convert explicitly, relative to where the panel really is.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let local = CGRect(
            x: frame.minX - panel.frame.minX,
            y: primaryHeight - frame.maxY - panel.frame.minY,
            width: frame.width, height: frame.height
        ).insetBy(dx: -2, dy: -2)
        let glide = shownOn == display.id && ring.opacity > 0.01 && !reduceMotion
        CATransaction.begin()
        if glide {
            CATransaction.setAnimationDuration(Animator.duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        ring.frame = local
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.borderColor = color.cgColor
        ring.opacity = 1
        CATransaction.commit()

        for (id, other) in panels where id != display.id { other.panel.orderOut(nil) }
        panel.orderFrontRegardless()
        shownOn = display.id

        fade?.cancel()
        guard !hold else { return }
        let work = DispatchWorkItem { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setCompletionBlock {
                if ring.opacity == 0 { panel.orderOut(nil); self?.shownOn = nil }
            }
            ring.opacity = 0
            CATransaction.commit()
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    /// Fades the ring out now.
    func hide() {
        fade?.cancel()
        guard let id = shownOn, let (panel, ring) = panels[id] else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setCompletionBlock { [weak self] in
            if ring.opacity == 0 { panel.orderOut(nil); self?.shownOn = nil }
        }
        ring.opacity = 0
        CATransaction.commit()
    }

    private func overlay(for id: CGDirectDisplayID, screen: NSScreen) -> (panel: NSPanel, ring: CALayer) {
        if let existing = panels[id] { return existing }
        let panel = overlayPanel(frame: screen.frame)
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        let ring = CALayer()
        ring.borderWidth = 3
        ring.cornerRadius = 14
        ring.cornerCurve = .continuous
        ring.opacity = 0
        view.layer?.addSublayer(ring)
        panel.contentView = view
        panels[id] = (panel, ring)
        return (panel, ring)
    }
}

/// The badge that shows which Workspace you're on, among all of them.
/// Which Workspace you're in, for a moment after you switch: "Workspace 2" (or what just happened,
/// like "Moved to Workspace 3") in a frosted pill at the top of the screen, with a dot for each
/// Workspace. Click-through, never focused.
final class SpaceBadge {
    private var panel: NSPanel?
    private var dots: [NumberDot] = []
    private var builtFor = 0
    private var title: NSTextField?
    private var row: NSStackView?
    private var hide: DispatchWorkItem?

    func show(space: Int, count: Int, caption text: String? = nil, on display: Display?) {
        if builtFor != count {
            // You added or took away a Workspace: a dot each.
            panel?.orderOut(nil)
            panel = nil
            dots = []
        }
        let panel = self.panel ?? makePanel(count: count)
        for (i, dot) in dots.enumerated() { dot.isActive = i == space }
        title?.stringValue = text ?? "Workspace \(space + 1)"
        row?.layoutSubtreeIfNeeded()
        let fit = row?.fittingSize ?? NSSize(width: 160, height: 24)
        let size = NSSize(width: ceil(fit.width) + 40, height: 44)
        let screen = display.flatMap { d in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.id }
        } ?? NSScreen.main ?? NSScreen.screens.first

        hide?.cancel()
        if let s = screen?.visibleFrame {
            // Just under the menu bar; it drops in a little the first time, then stays put.
            let target = NSRect(x: (s.midX - size.width / 2).rounded(), y: (s.maxY - size.height - 10).rounded(),
                                width: size.width, height: size.height)
            let appearing = panel.alphaValue < 0.05 && !reduceMotion
            panel.setFrame(appearing ? target.offsetBy(dx: 0, dy: 8) : target, display: true)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduceMotion ? 0 : 0.16
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
                panel.animator().alphaValue = 1
                if appearing { panel.animator().setFrame(target, display: true) }
            }
        }
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = reduceMotion ? 0 : 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func makePanel(count: Int) -> NSPanel {
        builtFor = count
        let panel = overlayPanel(frame: NSRect(x: 0, y: 0, width: 220, height: 44))
        panel.alphaValue = 0
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua) // dark glass, so white text reads on any wallpaper
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 22
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        self.title = title

        let dotRow = NSStackView()
        dotRow.orientation = .horizontal
        dotRow.spacing = 6
        for i in 0..<count {
            let dot = NumberDot(number: i + 1)
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 20).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 20).isActive = true
            dots.append(dot)
            dotRow.addArrangedSubview(dot)
        }

        let row = NSStackView(views: [title, dotRow])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        self.row = row
        blur.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])
        panel.contentView = blur
        self.panel = panel
        return panel
    }
}

/// A space number in a circle. Drawn by hand so the digit is centered on its
/// own height: a text field centers its whole line box, which leaves room for
/// descenders that digits don't have, so the number sat high.
final class NumberDot: NSView {
    private let number: String
    var isActive = false { didSet { needsDisplay = true } }

    init(number: Int) {
        self.number = String(number)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.08)).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let font = NSFont.systemFont(ofSize: (bounds.height * 0.5).rounded(), weight: .semibold)
        let text = NSAttributedString(string: number, attributes: [
            .font: font,
            .foregroundColor: isActive ? NSColor.white : NSColor.white.withAlphaComponent(0.55),
        ])
        // Put the middle of the digits (half their cap height above the
        // baseline) on the middle of the circle. draw(at:) takes the bottom of
        // the line box, which sits `descender` below the baseline.
        let baseline = bounds.midY - font.capHeight / 2
        let origin = NSPoint(x: (bounds.midX - text.size().width / 2).rounded(), y: (baseline + font.descender).rounded())
        text.draw(at: origin)
    }
}

/// One line saying what Lunchbox just did on its own, and which key undoes it: a small frosted
/// pill near the bottom of the screen for a couple of seconds. Click-through, never focused,
/// one at a time (a newer line replaces it), and gone on its own.
final class QuietLineView {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hide: DispatchWorkItem?

    /// - seconds: how long it stays (the usual couple of seconds by default).
    func show(_ text: String, on display: Display?, seconds: Double? = nil) {
        let panel = self.panel ?? makePanel()
        guard let label else { return }
        label.stringValue = text
        let width = min(720, ceil(label.intrinsicContentSize.width) + 36)
        let size = NSSize(width: width, height: 34)
        let screen = display.flatMap { d in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.id }
        } ?? NSScreen.main ?? NSScreen.screens.first
        if let s = screen?.visibleFrame {
            panel.setFrame(NSRect(x: (s.midX - size.width / 2).rounded(), y: (s.minY + s.height * 0.06).rounded(),
                                  width: size.width, height: size.height), display: true)
        }
        hide?.cancel()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = reduceMotion ? 0 : 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (seconds ?? Etiquette.lineSeconds), execute: work)
    }

    /// Takes the line away now.
    func dismiss() {
        hide?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = overlayPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 34))
        panel.alphaValue = 0
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua) // dark glass, so white text reads on any wallpaper
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 17
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: blur.leadingAnchor, constant: 18),
        ])
        panel.contentView = blur
        self.panel = panel
        self.label = label
        return panel
    }
}
