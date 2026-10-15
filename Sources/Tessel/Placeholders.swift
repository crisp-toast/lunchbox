import AppKit
import QuartzCore

/// The tile Tessel holds for a window on its way (see `Tiler.expectWindow`): a
/// soft frosted panel with the app's icon, breathing gently, in exactly the spot
/// the window will get. It sits just above the desktop, under every real window,
/// so it never covers anything: the arriving window glides in over it while it
/// fades. Clicks go straight through.
final class PlaceholderTile {
    private let panel: NSPanel
    private let iconView = NSImageView()
    private let label: NSTextField
    private var iconSize: NSLayoutConstraint!
    private var shown = false
    private var gone = false

    private static let cornerRadius: CGFloat = 16
    /// Ease-out cubic, the curve windows glide with.
    private static let glide = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(icon: NSImage, name: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the desktop and its icons, below every app's windows.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.alphaValue = 0

        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Self.cornerRadius
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        glass.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.25).cgColor

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        iconSize = iconView.widthAnchor.constraint(equalToConstant: 96)
        NSLayoutConstraint.activate([
            iconSize,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: glass.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: glass.widthAnchor, constant: -24),
        ])
        panel.contentView = glass
    }

    /// Puts the tile at `frame` (top-left screen coordinates): growing into it the
    /// first time, gliding along when the windows around it move, appearing in
    /// place when you come back to its Workspace.
    func show(at frame: CGRect, animated: Bool) {
        guard !gone else { return }
        let target = Self.cocoaRect(frame)
        let side = min(frame.width, frame.height)
        iconSize.constant = min(112, max(40, (side * 0.2).rounded()))
        label.isHidden = side < 180
        let motion = animated && !reduceMotion

        if !shown {
            shown = true
            panel.setFrame(motion ? target.insetBy(dx: target.width * 0.03, dy: target.height * 0.03) : target, display: false)
            panel.orderFrontRegardless()
            startPulse()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = motion ? 0.24 : 0
                ctx.timingFunction = Self.glide
                panel.animator().alphaValue = 1
                if motion { panel.animator().setFrame(target, display: true) }
            }
            return
        }
        if !panel.isVisible {
            // Back in its Workspace: everything snaps there, so it does too.
            panel.setFrame(target, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            startPulse()
            return
        }
        guard panel.frame != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = motion ? Animator.duration : 0
            ctx.timingFunction = Self.glide
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Hidden while its Workspace isn't the one in view.
    func conceal() {
        guard shown, !gone else { return }
        panel.orderOut(nil)
    }

    /// Fades away for good: its window arrived, or isn't coming.
    func dismiss(animated: Bool) {
        guard !gone else { return }
        gone = true
        guard panel.isVisible, animated, !reduceMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }

    /// The icon breathes slowly, so the tile reads as "on its way", not stuck.
    private func startPulse() {
        guard !reduceMotion, let layer = iconView.layer, layer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }

    private static func cocoaRect(_ frame: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        return NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

enum Dock {
    /// The app whose Dock icon is at `point` (top-left screen coordinates), if
    /// any, as the Dock itself reports it. Asks the Dock over Accessibility, so
    /// call it off the main thread.
    static func app(at point: CGPoint) -> URL? {
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success {
            // The hit can land on part of the icon; the item is at most a step or two up.
            var element = hit
            for _ in 0..<3 {
                guard let e = element else { break }
                if e.subrole == kApplicationItem { return url(of: e) }
                element = e.element(kAXParentAttribute)
            }
        }
        // Otherwise look through the Dock's icons for the one there.
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        for list in AXUIElement.application(dock.processIdentifier).elements(kAXChildrenAttribute) {
            for item in list.elements(kAXChildrenAttribute) where item.frame?.contains(point) == true {
                return item.subrole == kApplicationItem ? url(of: item) : nil
            }
        }
        return nil
    }

    private static let kApplicationItem = "AXApplicationDockItem"

    private static func url(of item: AXUIElement) -> URL? {
        guard let url = item.value(kAXURLAttribute), CFGetTypeID(url) == CFURLGetTypeID() else { return nil }
        return (url as! CFURL) as URL
    }
}
