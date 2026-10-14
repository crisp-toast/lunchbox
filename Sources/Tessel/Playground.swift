import AppKit
import QuartzCore
import TesselCore

/// A pretend Mac screen for practicing Tessel's shortcuts during onboarding.
/// It runs the same layout engine as the real thing on fake windows, so
/// focusing, moving, resizing, Focus, Tidy and Workspaces behave exactly as
/// they will on the desktop, without touching a single real window.
final class Playground: NSView {
    private struct FakeApp {
        let name: String
        let tint: NSColor
        let kind: Kind
    }

    private static let apps: [WindowID: FakeApp] = [
        1: FakeApp(name: "Notes", tint: NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.9, alpha: 1), kind: .notes),
        2: FakeApp(name: "Browser", tint: NSColor(calibratedRed: 0.95, green: 0.96, blue: 1.0, alpha: 1), kind: .browser),
        3: FakeApp(name: "Terminal", tint: NSColor(calibratedWhite: 0.11, alpha: 1), kind: .terminal),
        4: FakeApp(name: "Finder", tint: NSColor(calibratedWhite: 0.97, alpha: 1), kind: .finder),
        5: FakeApp(name: "Music", tint: NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.96, alpha: 1), kind: .music),
    ]

    private let world = CALayer()
    private let menuBar = CALayer()
    private let menuTitle = CATextLayer()
    private var workspaceDots: [CATextLayer] = []
    private let halo = CALayer()
    private var windows: [WindowID: FakeWindow] = [:]
    private var workspaces: [Layout] = []
    private var current = 0
    private var focused: WindowID?
    private static let menuHeight: CGFloat = 22
    private static let gap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let wallpaper = CAGradientLayer()
        wallpaper.colors = [NSColor(calibratedRed: 0.55, green: 0.66, blue: 0.98, alpha: 1).cgColor,
                            NSColor(calibratedRed: 0.93, green: 0.71, blue: 0.86, alpha: 1).cgColor,
                            NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.68, alpha: 1).cgColor]
        wallpaper.startPoint = CGPoint(x: 0, y: 1)
        wallpaper.endPoint = CGPoint(x: 1, y: 0)
        wallpaper.name = "wallpaper"
        layer?.addSublayer(wallpaper)

        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 700
        world.sublayerTransform = perspective
        layer?.addSublayer(world)

        halo.borderWidth = 2.5
        halo.borderColor = NSColor.controlAccentColor.cgColor
        halo.cornerRadius = 9
        halo.cornerCurve = .continuous
        halo.zPosition = 50
        world.addSublayer(halo)

        menuBar.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        menuBar.zPosition = 100
        menuTitle.string = "Practice space: nothing here touches your real windows"
        menuTitle.fontSize = 11
        menuTitle.foregroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        menuTitle.contentsScale = 2
        menuBar.addSublayer(menuTitle)
        for i in 0..<3 {
            let dot = CATextLayer()
            dot.string = "\(i + 1)"
            dot.fontSize = 10
            dot.alignmentMode = .center
            dot.cornerRadius = 7
            dot.contentsScale = 2
            menuBar.addSublayer(dot)
            workspaceDots.append(dot)
        }
        layer?.addSublayer(menuBar)
        reset()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Back to the starting arrangement: four windows here, Music in Workspace 2.
    func reset() {
        windows.values.forEach { $0.removeFromSuperlayer() }
        windows = [:]
        for (id, app) in Self.apps {
            let w = FakeWindow(name: app.name, tint: app.tint, kind: app.kind)
            windows[id] = w
            world.addSublayer(w)
        }
        workspaces = [Layout(columns: [Column(windows: [1]), Column(windows: [2]), Column(windows: [3, 4])]),
                      Layout(columns: [Column(windows: [5])]),
                      Layout()]
        current = 0
        focused = 2
        apply(animated: false)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.first { $0.name == "wallpaper" }?.frame = bounds
        world.frame = bounds
        menuBar.frame = flip(CGRect(x: 0, y: 0, width: bounds.width, height: Self.menuHeight))
        menuTitle.frame = CGRect(x: 12, y: 4, width: bounds.width - 120, height: 14)
        for (i, dot) in workspaceDots.enumerated() {
            dot.frame = CGRect(x: bounds.width - 76 + CGFloat(i) * 20, y: 4, width: 14, height: 14)
        }
        CATransaction.commit()
        apply(animated: false)
    }

    // MARK: Shortcuts

    /// Runs a shortcut on the fake windows.
    func perform(_ action: KeyAction) {
        var layout = workspaces[current]
        switch action {
        case .focus(let direction):
            let frames = visibleFrames()
            guard let id = focused, let from = frames[id] else { focused = frames.keys.first; break }
            var others = frames
            others[id] = nil
            if let next = nearest(from: from, direction: direction, in: others) {
                focused = next
                // As on the real desktop: focusing a shelved window ends Focus.
                if layout.spotlight != nil, layout.spotlight != next { layout.spotlight = nil }
            }
        case .move(let direction):
            if let id = focused { _ = layout.move(id, direction) }
        case .grow:
            if let id = focused { layout.resize(id, by: 0.08) }
        case .shrink:
            if let id = focused { layout.resize(id, by: -0.08) }
        case .spotlight:
            if let id = focused { layout.toggleSpotlight(id) }
        case .normalize:
            layout.balance()
        case .close:
            if let id = focused {
                layout.remove(id)
                windows[id]?.opacity = 0
                focused = layout.windows.last
            }
        case .hide:
            send(to: 2, follow: false, layout: &layout)
        case .sendToSpace(let i):
            send(to: i, follow: true, layout: &layout)
            return
        case .switchSpace(let i):
            guard i != current else { return }
            current = i
            focused = workspaces[i].windows.max { a, b in
                (frames(for: workspaces[i])[a]?.maxX ?? 0) < (frames(for: workspaces[i])[b]?.maxX ?? 0)
            }
            apply(animated: true)
            return
        case .launcher, .help:
            return
        }
        workspaces[current] = layout
        apply(animated: true)
    }

    private func send(to index: Int, follow: Bool, layout: inout Layout) {
        guard let id = focused, index != current else { return }
        layout.remove(id)
        workspaces[current] = layout
        workspaces[index].insert(id, near: workspaces[index].windows.last, maxColumns: 3)
        if follow {
            current = index
        } else {
            focused = layout.windows.last
        }
        apply(animated: true)
    }

    // MARK: Drawing

    private var usable: CGRect {
        CGRect(x: 0, y: Self.menuHeight, width: bounds.width, height: bounds.height - Self.menuHeight)
    }

    private func frames(for layout: Layout) -> [WindowID: CGRect] {
        layout.frames(in: usable, gap: Self.gap)
    }

    private func visibleFrames() -> [WindowID: CGRect] { frames(for: workspaces[current]) }

    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func apply(animated: Bool) {
        guard bounds.width > 0 else { return }
        let layout = workspaces[current]
        let frames = frames(for: layout)
        let shelved = Set(layout.shelved)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.32 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1))
        if !animated { CATransaction.setDisableActions(true) }
        for (id, window) in windows {
            if let frame = frames[id] {
                window.place(in: flip(frame))
                window.opacity = 1
                window.zPosition = shelved.contains(id) ? 1 : (id == focused ? 20 : 10)
                window.transform = shelved.contains(id)
                    ? CATransform3DScale(CATransform3DMakeRotation(0.55, 0, 1, 0), 0.92, 0.92, 1)
                    : CATransform3DIdentity
            } else if workspaces.firstIndex(where: { $0.contains(id) }) != nil {
                // In another Workspace: slide out of view.
                window.opacity = 0
                window.transform = CATransform3DMakeTranslation(-40, 0, 0)
            }
        }
        if let id = focused, let f = frames[id], !shelved.contains(id) {
            halo.frame = flip(f).insetBy(dx: -3, dy: -3)
            halo.opacity = 1
        } else {
            halo.opacity = 0
        }
        for (i, dot) in workspaceDots.enumerated() {
            dot.backgroundColor = (i == current ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.08)).cgColor
            dot.foregroundColor = (i == current ? NSColor.white : NSColor(calibratedWhite: 0.25, alpha: 1)).cgColor
        }
        CATransaction.commit()
    }
}

/// One fake window, drawn with layers so it can tilt onto the Shelf.
private final class FakeWindow: CALayer {
    private let face = CALayer()
    private let bar = CALayer()
    private let title = CATextLayer()
    private var dots: [CALayer] = []
    private var blocks: [(CALayer, CGRect)] = [] // fractions of the content area
    private let isDark: Bool

    init(name: String, tint: NSColor, kind: PlaygroundKind) {
        isDark = kind == .terminal
        super.init()
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.25
        shadowRadius = 10
        shadowOffset = CGSize(width: 0, height: -4)
        face.backgroundColor = tint.cgColor
        face.cornerRadius = 8
        face.cornerCurve = .continuous
        face.masksToBounds = true
        face.borderWidth = 0.5
        face.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        addSublayer(face)
        bar.backgroundColor = (isDark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)).cgColor
        face.addSublayer(bar)
        for color in [NSColor.systemRed, .systemYellow, .systemGreen] {
            let d = CALayer()
            d.backgroundColor = color.cgColor
            d.cornerRadius = 3.5
            bar.addSublayer(d)
            dots.append(d)
        }
        title.string = name
        title.fontSize = 10
        title.foregroundColor = (isDark ? NSColor(calibratedWhite: 0.7, alpha: 1) : NSColor(calibratedWhite: 0.3, alpha: 1)).cgColor
        title.contentsScale = 2
        bar.addSublayer(title)

        let line = isDark ? NSColor(calibratedWhite: 0.25, alpha: 1) : NSColor.black.withAlphaComponent(0.08)
        let accent: NSColor
        let shapes: [CGRect]
        switch kind {
        case .notes:
            accent = NSColor(calibratedRed: 0.8, green: 0.7, blue: 0.5, alpha: 1)
            shapes = [CGRect(x: 0.08, y: 0.08, width: 0.45, height: 0.05), CGRect(x: 0.08, y: 0.2, width: 0.84, height: 0.03),
                      CGRect(x: 0.08, y: 0.28, width: 0.7, height: 0.03), CGRect(x: 0.08, y: 0.36, width: 0.8, height: 0.03)]
        case .browser:
            accent = NSColor(calibratedRed: 0.75, green: 0.8, blue: 1.0, alpha: 1)
            shapes = [CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.3), CGRect(x: 0.08, y: 0.45, width: 0.6, height: 0.04),
                      CGRect(x: 0.08, y: 0.53, width: 0.8, height: 0.03)]
        case .terminal:
            accent = NSColor.systemGreen
            shapes = [CGRect(x: 0.08, y: 0.08, width: 0.3, height: 0.04), CGRect(x: 0.08, y: 0.17, width: 0.7, height: 0.03),
                      CGRect(x: 0.08, y: 0.25, width: 0.5, height: 0.03)]
        case .finder:
            accent = NSColor(calibratedRed: 0.45, green: 0.68, blue: 0.98, alpha: 1)
            shapes = (0..<6).map { i in CGRect(x: 0.08 + CGFloat(i % 3) * 0.3, y: 0.1 + CGFloat(i / 3) * 0.32, width: 0.22, height: 0.2) }
        case .music:
            accent = NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.65, alpha: 1)
            shapes = (0..<3).map { i in CGRect(x: 0.08 + CGFloat(i) * 0.3, y: 0.1, width: 0.24, height: 0.3) }
        }
        for (i, r) in shapes.enumerated() {
            let b = CALayer()
            b.backgroundColor = (i == 0 || kind == .finder || kind == .music ? accent : line).cgColor
            b.cornerRadius = 3
            face.addSublayer(b)
            blocks.append((b, r))
        }
    }

    override init(layer: Any) {
        isDark = false
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Sets the window's frame (bottom-left coordinates) and lays out its insides.
    func place(in frame: CGRect) {
        bounds = CGRect(origin: .zero, size: frame.size)
        position = CGPoint(x: frame.midX, y: frame.midY)
        face.frame = bounds
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        let barHeight: CGFloat = 18
        bar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        for (i, d) in dots.enumerated() { d.frame = CGRect(x: 8 + CGFloat(i) * 11, y: 5.5, width: 7, height: 7) }
        title.frame = CGRect(x: 46, y: 3, width: max(0, bounds.width - 54), height: 13)
        let content = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
        for (b, r) in blocks {
            b.frame = CGRect(x: content.width * r.minX, y: content.height * (1 - r.maxY),
                             width: content.width * r.width, height: max(3, content.height * r.height))
        }
    }
}

private typealias PlaygroundKind = Playground.Kind
extension Playground {
    enum Kind { case notes, browser, terminal, finder, music }
}
