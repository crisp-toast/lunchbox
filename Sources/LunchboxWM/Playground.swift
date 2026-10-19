import AppKit
import QuartzCore
import LunchboxCore

/// A pretend Mac screen for practicing LunchboxWM's shortcuts during onboarding.
/// It runs the same layout engine as the real thing on fake windows, so
/// focusing, moving, resizing, Focus, Tidy and Workspaces behave exactly as
/// they will on the desktop, without touching a single real window. Summon and
/// the Cheat Sheet open as pretend versions inside it too.
final class Playground: NSView {
    private struct FakeApp {
        let name: String
        let tint: NSColor
        let kind: Kind
        let icon: NSColor
    }

    /// Apps the pretend Mac has. The first five start with a window open.
    private static let catalog: [FakeApp] = [
        FakeApp(name: "Notes", tint: NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.9, alpha: 1), kind: .notes,
                icon: NSColor(calibratedRed: 0.98, green: 0.8, blue: 0.3, alpha: 1)),
        FakeApp(name: "Browser", tint: NSColor(calibratedRed: 0.95, green: 0.96, blue: 1.0, alpha: 1), kind: .browser,
                icon: NSColor(calibratedRed: 0.35, green: 0.55, blue: 1.0, alpha: 1)),
        FakeApp(name: "Terminal", tint: NSColor(calibratedWhite: 0.11, alpha: 1), kind: .terminal,
                icon: NSColor(calibratedWhite: 0.2, alpha: 1)),
        FakeApp(name: "Finder", tint: NSColor(calibratedWhite: 0.97, alpha: 1), kind: .finder,
                icon: NSColor(calibratedRed: 0.4, green: 0.68, blue: 0.98, alpha: 1)),
        FakeApp(name: "Music", tint: NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.96, alpha: 1), kind: .music,
                icon: NSColor(calibratedRed: 0.98, green: 0.33, blue: 0.45, alpha: 1)),
        FakeApp(name: "Calendar", tint: NSColor(calibratedWhite: 0.99, alpha: 1), kind: .notes,
                icon: NSColor(calibratedRed: 0.95, green: 0.3, blue: 0.25, alpha: 1)),
        FakeApp(name: "Mail", tint: NSColor(calibratedRed: 0.96, green: 0.98, blue: 1.0, alpha: 1), kind: .browser,
                icon: NSColor(calibratedRed: 0.25, green: 0.6, blue: 0.98, alpha: 1)),
        FakeApp(name: "Photos", tint: NSColor(calibratedWhite: 0.98, alpha: 1), kind: .music,
                icon: NSColor(calibratedRed: 0.95, green: 0.6, blue: 0.2, alpha: 1)),
        FakeApp(name: "Maps", tint: NSColor(calibratedRed: 0.93, green: 0.98, blue: 0.93, alpha: 1), kind: .finder,
                icon: NSColor(calibratedRed: 0.3, green: 0.75, blue: 0.45, alpha: 1)),
    ]

    private let world = CALayer()
    private let menuBar = CALayer()
    private let menuTitle = CATextLayer()
    private var workspaceDots: [CATextLayer] = []
    private let halo = CALayer()
    private var windows: [WindowID: FakeWindow] = [:]
    private var windowApp: [WindowID: String] = [:]
    private var workspaces: [Layout] = []
    private var current = 0
    private var focused: WindowID?
    private var nextID: WindowID = 10
    private static let menuHeight: CGFloat = 22
    private static let gap: CGFloat = 6
    private static let corner: CGFloat = 8

    private let summon = FakeSummon()
    private let cheatSheet = FakeCheatSheet()
    /// The Cheat Sheet's lines: the real shortcuts, as the user has them set.
    var cheatEntries: () -> [CheatEntry] = { [] }

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

        // No perspective on the whole scene: depth would scale every window by its
        // stacking order and throw the focus outline off. Shelf cards tilt on their own.
        layer?.addSublayer(world)

        halo.borderWidth = 2.5
        halo.borderColor = NSColor.controlAccentColor.cgColor
        halo.cornerRadius = Self.corner + 3
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

        for overlay in [summon, cheatSheet] as [NSView] {
            overlay.isHidden = true
            addSubview(overlay)
        }
        reset()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Back to the starting arrangement: four windows here, Music in Workspace 2.
    func reset() {
        closeOverlays()
        windows.values.forEach { $0.removeFromSuperlayer() }
        windows = [:]
        windowApp = [:]
        nextID = 10
        for (i, app) in Self.catalog.prefix(5).enumerated() { makeWindow(WindowID(i + 1), app: app) }
        workspaces = [Layout(columns: [Column(windows: [1]), Column(windows: [2]), Column(windows: [3, 4])]),
                      Layout(columns: [Column(windows: [5])]),
                      Layout()]
        current = 0
        focused = 2
        apply(animated: false)
    }

    @discardableResult
    private func makeWindow(_ id: WindowID, app: FakeApp, title: String? = nil) -> FakeWindow {
        let w = FakeWindow(name: title ?? app.name, tint: app.tint, kind: app.kind)
        windows[id] = w
        windowApp[id] = app.name
        world.addSublayer(w)
        return w
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
        layoutOverlays()
        apply(animated: false)
    }

    private func layoutOverlays() {
        let w = min(460, bounds.width * 0.62)
        summon.frame = flip(CGRect(x: (bounds.width - w) / 2, y: Self.menuHeight + 44, width: w, height: summon.preferredHeight))
        let cw = min(520, bounds.width * 0.68), ch = min(bounds.height - Self.menuHeight - 48, 400)
        cheatSheet.frame = flip(CGRect(x: (bounds.width - cw) / 2, y: Self.menuHeight + 24, width: cw, height: ch))
    }

    // MARK: Shortcuts

    /// Runs a shortcut on the fake windows (Summon and the Cheat Sheet open their pretend versions).
    func perform(_ action: KeyAction) {
        switch action {
        case .launcher:
            if summon.isHidden { open(summon) } else { closeOverlays() }
            return
        case .help:
            if cheatSheet.isHidden { open(cheatSheet) } else { closeOverlays() }
            return
        default:
            closeOverlays()
        }
        var layout = workspaces[current]
        // As on the real desktop: in Focus, ⌘ or ⇧⌘ with any arrow ends it.
        switch action {
        case .focus, .move:
            if layout.spotlight != nil {
                layout.spotlight = nil
                workspaces[current] = layout
                apply(animated: true)
                return
            }
        default: break
        }
        switch action {
        case .focus(let direction):
            let frames = visibleFrames()
            guard let id = focused, let from = frames[id] else { focused = frames.keys.first; break }
            var others = frames
            others[id] = nil
            if let next = nearest(from: from, direction: direction, in: others) {
                focused = next
            }
        case .move(let direction):
            if let id = focused { _ = layout.move(id, direction) }
        case .grow:
            if let id = focused { layout.resize(id, by: 0.08) }
        case .shrink:
            if let id = focused { layout.resize(id, by: -0.08) }
        case .resizeAlong(let direction):
            if let id = focused {
                layout.resize(id, toward: direction, by: 0.05, in: usable, gap: Self.gap)
            }
        case .resizeMode:
            break // the pretend screen has no line to show; the arrows just work
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
            // Minimized to the Dock: out of view, still open.
            if let id = focused {
                layout.remove(id)
                windows[id]?.opacity = 0
                focused = layout.windows.last
            }
        case .sendToSpace(let i):
            send(to: i, follow: true, layout: &layout)
            return
        case .switchSpace(let i):
            switchTo(i)
            return
        case .launcher, .help:
            return
        }
        workspaces[current] = layout
        apply(animated: true)
    }

    private func switchTo(_ i: Int, focusing id: WindowID? = nil) {
        guard workspaces.indices.contains(i) else { return }
        current = i
        let frames = frames(for: workspaces[i])
        focused = id ?? workspaces[i].windows.max { (frames[$0]?.maxX ?? 0) < (frames[$1]?.maxX ?? 0) }
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

    /// A new window of an app, tiled into this Workspace and focused, like a real one.
    private func openWindow(of app: FakeApp, title: String? = nil) {
        let id = nextID
        nextID += 1
        let window = makeWindow(id, app: app, title: title)
        window.opacity = 0
        var layout = workspaces[current]
        layout.spotlight = nil
        layout.insert(id, near: focused, maxColumns: 3)
        workspaces[current] = layout
        // Appear where it's going, then fade in as the others make room.
        if let frame = frames(for: layout)[id] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.place(in: flip(frame))
            CATransaction.commit()
        }
        focused = id
        apply(animated: true)
    }

    // MARK: Summon and the Cheat Sheet

    override var acceptsFirstResponder: Bool { !summon.isHidden || !cheatSheet.isHidden }

    private func open(_ overlay: NSView) {
        closeOverlays()
        if overlay === summon {
            summon.query = ""
            refreshSummon()
        } else {
            cheatSheet.query = ""
            refreshCheatSheet()
        }
        layoutOverlays()
        overlay.isHidden = false
        window?.makeFirstResponder(self)
    }

    private func closeOverlays() {
        let wasOpen = !summon.isHidden || !cheatSheet.isHidden
        summon.isHidden = true
        cheatSheet.isHidden = true
        if wasOpen, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: press("escape")
        case 36, 76: press(shift ? "shift-return" : "return")
        case 125: press("down")
        case 126: press("up")
        case 51: press("delete")
        default:
            guard !event.modifierFlags.contains(.command), let chars = event.characters, !chars.isEmpty else {
                super.keyDown(with: event)
                return
            }
            type(chars)
        }
    }

    /// Typing into whichever pretend panel is open.
    func type(_ text: String) {
        let clean = text.filter { !$0.isNewline && $0 != "\t" }
        guard !clean.isEmpty else { return }
        if !summon.isHidden {
            summon.query += clean
            summon.selection = 0
            refreshSummon()
        } else if !cheatSheet.isHidden {
            cheatSheet.query += clean
            refreshCheatSheet()
        }
    }

    /// A non-text key in a pretend panel: return, shift-return, escape, up, down, delete.
    func press(_ name: String) {
        if name == "escape" { closeOverlays(); return }
        if !summon.isHidden {
            switch name {
            case "down": summon.selection = min(summon.selection + 1, max(0, summon.rows.count - 1)); refreshSummon()
            case "up": summon.selection = max(0, summon.selection - 1); refreshSummon()
            case "delete": summon.query = String(summon.query.dropLast()); summon.selection = 0; refreshSummon()
            case "return", "shift-return": runSummon(newWindow: name == "shift-return")
            default: break
            }
        } else if !cheatSheet.isHidden, name == "delete" {
            cheatSheet.query = String(cheatSheet.query.dropLast())
            refreshCheatSheet()
        }
    }

    private func refreshSummon() {
        let q = summon.query.trimmingCharacters(in: .whitespaces)
        var rows: [FakeSummon.Row] = []
        if !q.isEmpty {
            let matches = Self.catalog
                .compactMap { app in Fuzzy.score(q, app.name).map { (app, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(4)
            for (app, _) in matches {
                let open = windowApp.values.contains(app.name)
                rows.append(.init(title: app.name, subtitle: open ? "Go to its window" : "Open",
                                  icon: app.icon, newWindow: open ? "New \(app.name) window" : nil))
            }
            if rows.isEmpty {
                rows.append(.init(title: "Search the web for “\(q)”", subtitle: "Opens a tab in your browser",
                                  icon: NSColor(calibratedRed: 0.2, green: 0.78, blue: 0.86, alpha: 1), newWindow: nil, web: true))
            }
        }
        summon.rows = rows
        summon.selection = min(summon.selection, max(0, rows.count - 1))
        // Light, like the pretend desktop, whatever the Mac's own appearance.
        lightAppearance.performAsCurrentDrawingAppearance { summon.render() }
        layoutOverlays()
    }

    private func runSummon(newWindow: Bool) {
        guard summon.rows.indices.contains(summon.selection) else { return }
        let row = summon.rows[summon.selection]
        let query = summon.query
        closeOverlays()
        if row.web {
            openWindow(of: Self.catalog[1], title: query)
            return
        }
        guard let app = Self.catalog.first(where: { $0.name == row.title }) else { return }
        let existing = windowApp.filter { $0.value == app.name }.map(\.key).sorted()
        if newWindow || existing.isEmpty {
            openWindow(of: app)
        } else if let id = existing.first(where: { workspaces[current].contains($0) }) ?? existing.first,
                  let space = workspaces.firstIndex(where: { $0.contains(id) }) {
            // Like the real Summon: ↩ goes to the window, switching Workspaces if needed.
            if space == current { focused = id; apply(animated: true) } else { switchTo(space, focusing: id) }
        }
    }

    private func refreshCheatSheet() {
        let result = CheatSheetSearch.search(cheatSheet.query, in: cheatEntries())
        lightAppearance.performAsCurrentDrawingAppearance {
            cheatSheet.render(entries: result.entries, closest: result.closest)
        }
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
                window.transform = shelved.contains(id) ? Self.shelfTilt : CATransform3DIdentity
            } else if workspaces.contains(where: { $0.contains(id) }) {
                // In another Workspace: slide out of view.
                window.opacity = 0
                window.transform = CATransform3DMakeTranslation(-40, 0, 0)
            } else {
                window.opacity = 0 // closed
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

    /// A Shelf card: small and turned away from the screen around its left edge,
    /// clearly out of the way of the window in Focus.
    private static let shelfTilt: CATransform3D = {
        var t = CATransform3DIdentity
        t.m34 = -1 / 500
        t = CATransform3DRotate(t, 0.55, 0, 1, 0)
        return CATransform3DScale(t, 0.7, 0.7, 1)
    }()
}

/// One fake window, drawn with layers so it can tilt onto the Shelf. It turns
/// around its left edge, so its position is the middle of that edge.
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
        anchorPoint = CGPoint(x: 0, y: 0.5)
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
        title.truncationMode = .end
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
        position = CGPoint(x: frame.minX, y: frame.midY)
        face.frame = bounds
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        let barHeight: CGFloat = 18
        bar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        for (i, d) in dots.enumerated() { d.frame = CGRect(x: 8 + CGFloat(i) * 11, y: 5.5, width: 7, height: 7) }
        title.frame = CGRect(x: 46, y: 3, width: max(0, bounds.width - 54), height: 13)
        // The content keeps its shape: a short window shows less instead of squashing it.
        let content = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
        let reference = max(content.height, content.width * 0.75)
        for (b, r) in blocks {
            let y = reference * r.minY, h = max(3, reference * r.height)
            b.frame = CGRect(x: content.width * r.minX, y: content.height - y - h, width: content.width * r.width, height: h)
            b.isHidden = y + h > content.height - 6
        }
    }
}

private typealias PlaygroundKind = Playground.Kind
extension Playground {
    enum Kind { case notes, browser, terminal, finder, music }
}

// MARK: - Pretend panels

/// A pretend Summon: type an app's name, ↩ to go to it or open it, ⇧↩ for a new window.
private final class FakeSummon: NSView {
    struct Row {
        let title: String
        let subtitle: String
        let icon: NSColor
        let newWindow: String?
        var web = false
    }

    var query = ""
    var rows: [Row] = []
    var selection = 0
    private let field = NSTextField(labelWithString: "")
    private let list = NSStackView()

    var preferredHeight: CGFloat {
        let rowsHeight = rows.enumerated().reduce(CGFloat(0)) { sum, item in
            sum + (item.element.newWindow != nil && item.offset == selection ? 58 : 40) + 2
        }
        return 58 + (rows.isEmpty ? 30 : rowsHeight + 8)
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        styleAsPanel(self)
        field.font = .systemFont(ofSize: 18)
        field.lineBreakMode = .byTruncatingHead
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        let line = NSBox()
        line.boxType = .separator
        for v in [field, line, list] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 50),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            list.topAnchor.constraint(equalTo: topAnchor, constant: 58),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func render() {
        if query.isEmpty {
            field.attributedStringValue = NSAttributedString(string: "Summon an app, window or website",
                                                             attributes: [.foregroundColor: panelPlaceholder, .font: NSFont.systemFont(ofSize: 18)])
        } else {
            field.attributedStringValue = NSAttributedString(string: query + "▏",
                                                             attributes: [.foregroundColor: panelText, .font: NSFont.systemFont(ofSize: 18)])
        }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if rows.isEmpty {
            let hint = NSTextField(labelWithString: "Type an app’s name, like “notes” or “maps”.")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = panelSecondary
            list.addArrangedSubview(hint)
            return
        }
        for (i, row) in rows.enumerated() {
            let view = SummonRow(row: row, selected: i == selection)
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
}

private final class SummonRow: NSView {
    init(row: FakeSummon.Row, selected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : nil
        let text: NSColor = selected ? .white : panelText
        let sub: NSColor = selected ? NSColor.white.withAlphaComponent(0.8) : panelSecondary

        let icon = NSView()
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 6
        icon.layer?.backgroundColor = row.icon.cgColor
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = text
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: row.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = sub
        let ret = Keycap(text: "↩")
        ret.onAccent = selected
        ret.isHidden = !selected
        for v in [icon, title, subtitle, ret] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let showNew = selected && row.newWindow != nil
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: showNew ? 58 : 40),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: ret.leadingAnchor, constant: -8),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            ret.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ret.topAnchor.constraint(equalTo: topAnchor, constant: 9),
        ])
        if showNew, let newWindow = row.newWindow {
            let label = NSTextField(labelWithString: "＋ " + newWindow)
            label.font = .systemFont(ofSize: 12)
            label.textColor = text
            let cap = Keycap(text: "⇧↩")
            cap.onAccent = true
            for v in [label, cap] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
                cap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                cap.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A pretend Cheat Sheet: the real shortcuts, filtered by the real forgiving search.
private final class FakeCheatSheet: NSView {
    var query = ""
    private let field = NSTextField(labelWithString: "")
    private let list = NSStackView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        styleAsPanel(self)
        field.font = .systemFont(ofSize: 16)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3
        let clip = FlippedView()
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        let line = NSBox()
        line.boxType = .separator
        for v in [field, line, clip] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        list.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(list)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            clip.topAnchor.constraint(equalTo: topAnchor, constant: 52),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func render(entries: [CheatEntry], closest: Bool) {
        field.attributedStringValue = query.isEmpty
            ? NSAttributedString(string: "Search shortcuts, in your own words", attributes: [.foregroundColor: panelPlaceholder, .font: NSFont.systemFont(ofSize: 16)])
            : NSAttributedString(string: query + "▏", attributes: [.foregroundColor: panelText, .font: NSFont.systemFont(ofSize: 16)])
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if closest {
            let note = NSTextField(labelWithString: "No exact match. These are the closest:")
            note.font = .systemFont(ofSize: 11)
            note.textColor = panelSecondary
            list.addArrangedSubview(note)
        }
        var lastGroup = ""
        for entry in entries {
            if entry.group != lastGroup {
                lastGroup = entry.group
                let header = NSTextField(labelWithString: entry.group.uppercased())
                header.font = .systemFont(ofSize: 10, weight: .semibold)
                header.textColor = panelSecondary
                list.addArrangedSubview(header)
                if let previous = list.arrangedSubviews.dropLast().last { list.setCustomSpacing(10, after: previous) }
            }
            let caps = NSStackView(views: entry.keys.map { k in
                if k == "then" {
                    let t = NSTextField(labelWithString: "then")
                    t.font = .systemFont(ofSize: 11)
                    t.textColor = panelSecondary
                    return t as NSView
                }
                return Keycap(text: k)
            })
            caps.spacing = 3
            caps.translatesAutoresizingMaskIntoConstraints = false
            let capsBox = NSView()
            capsBox.translatesAutoresizingMaskIntoConstraints = false
            capsBox.addSubview(caps)
            NSLayoutConstraint.activate([
                capsBox.widthAnchor.constraint(equalToConstant: 176),
                capsBox.heightAnchor.constraint(equalToConstant: 22),
                caps.leadingAnchor.constraint(equalTo: capsBox.leadingAnchor),
                caps.centerYAnchor.constraint(equalTo: capsBox.centerYAnchor),
            ])
            let title = NSTextField(labelWithString: entry.title)
            title.font = .systemFont(ofSize: 12)
            title.textColor = panelText
            title.lineBreakMode = .byTruncatingTail
            let row = NSStackView(views: [capsBox, title])
            row.orientation = .horizontal
            row.spacing = 12
            list.addArrangedSubview(row)
        }
    }
}

// The pretend desktop is always light, so its panels are too, whatever the Mac's appearance.
private let panelText = NSColor(calibratedWhite: 0.12, alpha: 1)
private let panelSecondary = NSColor(calibratedWhite: 0.45, alpha: 1)
private let panelPlaceholder = NSColor(calibratedWhite: 0.55, alpha: 1)
private let lightAppearance = NSAppearance(named: .aqua)!

private func styleAsPanel(_ view: NSView) {
    view.appearance = lightAppearance
    view.wantsLayer = true
    view.layer?.cornerRadius = 12
    view.layer?.cornerCurve = .continuous
    view.layer?.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1).cgColor
    view.layer?.borderWidth = 0.5
    view.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
    view.layer?.shadowColor = NSColor.black.cgColor
    view.layer?.shadowOpacity = 0.28
    view.layer?.shadowRadius = 18
    view.layer?.shadowOffset = CGSize(width: 0, height: -8)
    view.layer?.masksToBounds = false
}
