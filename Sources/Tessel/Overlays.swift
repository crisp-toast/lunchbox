import AppKit
import QuartzCore

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

    func flash(_ frame: CGRect, on displays: [Display]) {
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
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.opacity = 1
        CATransaction.commit()

        for (id, other) in panels where id != display.id { other.panel.orderOut(nil) }
        panel.orderFrontRegardless()
        shownOn = display.id

        fade?.cancel()
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

/// The badge that shows which of the three spaces you're on.
final class SpaceBadge {
    private var panel: NSPanel?
    private var dots: [NSTextField] = []
    private var caption: NSTextField?
    private var hide: DispatchWorkItem?

    func show(space: Int, count: Int, caption text: String? = nil, on display: Display?) {
        let panel = self.panel ?? makePanel(count: count)
        for (i, label) in dots.enumerated() {
            let active = i == space
            label.layer?.backgroundColor = active ? NSColor.controlAccentColor.cgColor : NSColor.white.withAlphaComponent(0.08).cgColor
            label.textColor = active ? .white : NSColor.white.withAlphaComponent(0.55)
        }
        caption?.stringValue = text ?? ""
        caption?.isHidden = text == nil

        let size = NSSize(width: 168, height: text == nil ? 64 : 88)
        let screen = display.flatMap { d in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.id }
        } ?? NSScreen.main ?? NSScreen.screens.first
        if let s = screen?.visibleFrame {
            panel.setFrame(NSRect(x: s.midX - size.width / 2, y: s.minY + s.height * 0.12, width: size.width, height: size.height), display: true)
        }

        hide?.cancel()
        panel.alphaValue = reduceMotion ? 1 : panel.alphaValue
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func makePanel(count: Int) -> NSPanel {
        let panel = overlayPanel(frame: NSRect(x: 0, y: 0, width: 168, height: 64))
        panel.alphaValue = 0
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        for i in 0..<count {
            let label = NSTextField(labelWithString: "\(i + 1)")
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.cornerRadius = 15
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 30).isActive = true
            label.heightAnchor.constraint(equalToConstant: 30).isActive = true
            dots.append(label)
            row.addArrangedSubview(label)
        }
        let caption = NSTextField(labelWithString: "")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = NSColor.white.withAlphaComponent(0.75)
        caption.alignment = .center
        self.caption = caption

        let column = NSStackView(views: [row, caption])
        column.orientation = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])
        panel.contentView = blur
        self.panel = panel
        return panel
    }
}
