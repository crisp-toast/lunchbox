import AppKit
import QuartzCore
import UniformTypeIdentifiers
import LunchboxCore

/// Sort My Windows, start to finish: works the sort out, plays the show over it, then offers
/// Undo. Only ever runs when asked: setup's last step ("Organize your open windows?") or the menu.
final class WindowSorter {
    private let tiler: Tiler
    private var show: SortShow?
    private let summary = SortSummary()
    /// A command's keys as keycaps ("⌘1"), from the shortcuts in use.
    var keycaps: ((Command) -> String?)?
    /// Asked for in setup before Lunchbox was licensed: it sorts once tiling starts.
    var pending = false

    init(tiler: Tiler) {
        self.tiler = tiler
        summary.onUndo = { [weak tiler] in tiler?.undoSort() }
    }

    var isRunning: Bool { show != nil }

    /// Sorts every tiled window (or only those on the display with UUID `display`, for tests).
    func run(onDisplay display: String? = nil) {
        guard show == nil, tiler.enabled else { return }
        pending = false
        summary.dismiss()
        tiler.readWindowTitles { [weak self] in self?.start(onDisplay: display) }
    }

    private func start(onDisplay display: String?) {
        guard show == nil else { return }
        guard let sort = tiler.prepareSort(onDisplay: display), !sort.trips.isEmpty else {
            tiler.announce("There are no tiled windows to sort")
            return
        }
        guard !sort.changesNothing else {
            tiler.announce("Your windows are already sorted")
            return
        }
        var icons: [pid_t: NSImage] = [:]
        let cards = sort.trips.map { trip -> SortShow.Card in
            if icons[trip.pid] == nil {
                icons[trip.pid] = NSRunningApplication(processIdentifier: trip.pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
            }
            return SortShow.Card(id: trip.id, icon: icons[trip.pid]!, title: trip.title, from: trip.from,
                                 space: trip.space, to: trip.to, display: trip.display)
        }
        play(cards: cards, plan: sort.plan, undoable: true, quiet: sort.scope != nil) { [weak tiler] in tiler?.applySort(sort) }
    }

    /// - quiet: for tests on a display nobody watches: no sound, and Lunchbox doesn't come forward.
    private func play(cards: [SortShow.Card], plan: WindowSort.Plan, undoable: Bool, quiet: Bool, covered: @escaping () -> Void) {
        let spaces = plan.workspaces.enumerated().map { i, w in
            SortShow.Space(title: w.title, key: keycaps?(.goTo(i)), accent: SortShow.accent(for: w.groups.first ?? .work))
        }
        let show = SortShow(cards: cards, spaces: spaces, landing: plan.landing, quiet: quiet)
        self.show = show
        show.onCovered = covered
        show.onFinished = { [weak self] in
            guard let self else { return }
            self.show = nil
            self.tiler.focusSorted()
            let title = spaces.count == 1 ? "Sorted into Workspace 1" : "Sorted into \(spaces.count) Workspaces"
            var detail = spaces.map { ($0.key.map { $0 + " " } ?? "") + $0.title }.joined(separator: "  ·  ")
            if !plan.hidden.isEmpty {
                let summon = self.keycaps?(.summon).map { " (\($0))" } ?? ""
                detail += "  ·  \(plan.hidden.count) hidden: Summon\(summon) finds them"
            }
            let main = cards.first(where: { $0.display.isMain })?.display ?? cards.first?.display
            self.summary.show(title: title, detail: detail, on: main, undo: undoable)
        }
        show.prepare { [weak show] in show?.play() }
    }

    #if DEBUG || LUNCHBOX_DEV
    /// The show on one display with made-up windows of apps on this Mac, moving nothing: for
    /// looking at it (and listening) on a display nobody watches.
    func demo(on display: Display) {
        guard show == nil else { return }
        let apps: [(String, String)] = [
            ("com.apple.dt.Xcode", "Lunchbox — Tiler.swift"), ("com.apple.Safari", "LunchboxWM — Every window, right where it belongs"),
            ("com.apple.Notes", "Launch checklist"), ("com.apple.MobileSMS", "Messages"), ("com.apple.Terminal", "zsh — 120×40"),
            ("com.google.Chrome", "Stripe Dashboard"), ("com.apple.Music", "Music"), ("com.apple.TextEdit", "Release notes.txt"),
            ("com.apple.Safari", "Sparkle documentation"), ("com.apple.mail", "Inbox — 3 new"), ("com.apple.Preview", "Receipt.pdf"),
            ("com.apple.iCal", "October 2026"), ("com.apple.Safari", "Apple Developer"),
        ]
        var seed: UInt64 = 0x5EED
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(1 << 31)
        }
        let items = apps.enumerated().map { WindowSort.Item(id: WindowID($0.offset + 1), bundleID: $0.element.0, category: nil) }
        let v = display.visible
        let plan = WindowSort.plan(items, fit: WindowSort.fit(forWidth: v.width))
        var to: [WindowID: (Int, CGRect)] = [:]
        for (s, w) in plan.workspaces.enumerated() {
            let layout = WindowSort.layout(w.windows, maxColumns: Layout.maxColumns(forWidth: v.width))
            for (id, frame) in layout.frames(in: v, gap: Tiler.gap) { to[id] = (s, frame) }
        }
        let cards = items.map { item -> SortShow.Card in
            let (bundle, title) = apps[Int(item.id) - 1]
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .application)
            let width = v.width * (0.32 + 0.26 * random()), height = width / (1.3 + 0.4 * random())
            let from = CGRect(x: v.minX + (v.width - width) * random(), y: v.minY + (v.height - height) * random(), width: width, height: height)
            return SortShow.Card(id: CGWindowID(item.id), icon: icon, title: title, from: from, space: to[item.id]?.0,
                                 to: to[item.id]?.1, display: display)
        }
        play(cards: cards, plan: plan, undoable: false, quiet: true) {}
    }
    #endif
}

// MARK: - The show

/// The color wash, the windows flying to their Workspaces, and the Workspace you're in opening
/// up onto the real windows. The real windows move once the wash covers them (`onCovered`); the
/// cards stand in for them, since macOS can't shrink another app's window. Click or Esc skips to
/// the end. With Reduce Motion, nothing flies: the Workspaces fade in with their windows in place.
final class SortShow {
    struct Card {
        let id: CGWindowID
        let icon: NSImage
        let title: String
        /// What the window looked like, when Screen Recording is allowed.
        var snapshot: CGImage?
        /// Where it was in view (top-left screen coordinates); nil when out of sight.
        let from: CGRect?
        /// Its Workspace and tile there; nil when hidden.
        let space: Int?
        let to: CGRect?
        let display: Display
    }

    struct Space {
        let title: String
        let key: String?
        let accent: NSColor
    }

    /// The wash covers the windows: move them now.
    var onCovered: (() -> Void)?
    var onFinished: (() -> Void)?

    private var cards: [Card]
    private let spaces: [Space]
    private let landing: Int
    private var timeline: Timeline
    private var stages: [Stage] = []
    private var sound: NSSound?
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private var playing = false
    private var covered = false
    private var landed = Set<Int>()
    private var soundFade: CFTimeInterval?
    private let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// No sound, and Lunchbox doesn't come forward (so there's no Esc either).
    private let quiet: Bool

    static func accent(for group: WindowSort.Group) -> NSColor {
        switch group {
        case .work: return NSColor(srgbRed: 0.24, green: 0.86, blue: 0.68, alpha: 1)  // mint
        case .web: return NSColor(srgbRed: 0.43, green: 0.61, blue: 1, alpha: 1)      // the brand's blue, light
        case .talk: return NSColor(srgbRed: 1, green: 0.48, blue: 0.40, alpha: 1)     // coral
        }
    }

    init(cards: [Card], spaces: [Space], landing: Int, quiet: Bool) {
        self.cards = cards
        self.spaces = spaces
        self.landing = landing
        self.quiet = quiet
        timeline = Timeline(cards: cards.count, still: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Takes pictures of the windows (only if Screen Recording is already allowed: it never asks)
    /// and makes the sound, then calls `ready`; after 0.6 s it goes ahead without what's missing.
    func prepare(then ready: @escaping () -> Void) {
        let group = DispatchGroup()
        if CGPreflightScreenCaptureAccess() {
            group.enter()
            Snapshotter.capture(cards.filter { $0.from != nil }.map(\.id), ask: false) { [weak self] images in
                if let self, !self.playing {
                    for i in self.cards.indices { self.cards[i].snapshot = images[self.cards[i].id] }
                }
                group.leave()
            }
        }
        if SortSound.allowed, !quiet {
            group.enter()
            let timeline = self.timeline
            let plinks = still ? [] : cards.indices.map { i -> (Double, Double) in
                let pan = cards[i].space.map { (Double($0) - Double(spaces.count - 1) / 2) * 0.45 } ?? 0
                return (timeline.arrival(i), pan)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let data = SortSound.render(timeline, plinks: plinks)
                DispatchQueue.main.async {
                    if let self, !self.playing { self.sound = NSSound(data: data) }
                    group.leave()
                }
            }
        }
        var went = false
        let go = { if !went { went = true; ready() } }
        group.notify(queue: .main, execute: go)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: go)
    }

    func play() {
        guard !playing else { return }
        playing = true
        let displays = Dictionary(cards.map { ($0.display.uuid, $0.display) }, uniquingKeysWith: { a, _ in a })
        let main = displays.values.first(where: \.isMain)?.uuid ?? displays.keys.sorted().first
        stages = displays.values.compactMap { d in
            Stage(display: d, cards: cards.indices.filter { cards[$0].display.uuid == d.uuid }, all: cards, spaces: spaces,
                  landing: landing, headline: d.uuid == main, still: still) { [weak self] in self?.skip() }
        }
        guard !stages.isEmpty else { finish(); return }
        if quiet {
            for stage in stages { stage.panel.orderFrontRegardless() }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            for stage in stages { stage.panel.makeKeyAndOrderFront(nil) }
        }
        if let sound {
            sound.volume = 0.55
            sound.play()
        }
        started = CACurrentMediaTime()
        render()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.render() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Straight to the end: the Workspace you're in opens up now.
    func skip() {
        let t = CACurrentMediaTime() - started
        guard playing, t < timeline.finale else { return }
        timeline.skip(at: t)
        soundFade = CACurrentMediaTime()
    }

    private func render() {
        let t = CACurrentMediaTime() - started
        if !covered, t >= timeline.cover || timeline.skipped {
            covered = true
            onCovered?()
        }
        // Each window's landing: its Workspace takes it with a little pulse, and counts it.
        if !still {
            for i in cards.indices where !landed.contains(i) && t >= timeline.arrival(i) && t < timeline.finale {
                landed.insert(i)
                for stage in stages { stage.landed(i) }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for stage in stages { stage.render(t, timeline: timeline) }
        CATransaction.commit()
        if let fade = soundFade, let sound {
            let left = 1 - (CACurrentMediaTime() - fade) / 0.45
            if left <= 0 { sound.stop(); soundFade = nil } else { sound.volume = Float(0.55 * left) }
        }
        if t >= timeline.end { finish() }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        if !covered { covered = true; onCovered?() }
        for stage in stages { stage.panel.orderOut(nil) }
        stages = []
        onFinished?()
        onFinished = nil
    }
}

/// When each part of the show happens, in seconds from the start.
struct Timeline {
    /// The wash is all the way up: the real windows move now, out of sight.
    let cover: Double
    let flyStart: Double
    let stagger: Double
    let flight: Double
    /// The Workspace you're in starts opening up onto the real windows.
    private(set) var finale: Double
    let still: Bool
    private(set) var skipped = false

    init(cards: Int, still: Bool) {
        self.still = still
        if still {
            cover = 0.35
            flyStart = 0.35
            stagger = 0
            flight = 0.4
            finale = 2.8
        } else {
            cover = 0.55
            flyStart = 0.7
            stagger = cards <= 1 ? 0 : min(0.085, 1.5 / Double(cards - 1))
            flight = 0.95
            finale = max(2.9, flyStart + Double(max(0, cards - 1)) * stagger + flight * 0.5 + 1.15)
        }
    }

    func start(_ i: Int) -> Double { flyStart + Double(i) * stagger }
    /// When card `i` reaches its Workspace, near enough to count (its glide eases out after).
    func arrival(_ i: Int) -> Double { start(i) + flight * 0.5 }
    /// How long the Workspace you're in takes to open to the whole screen.
    var opening: Double { still ? 0 : skipped ? 0.5 : 0.75 }
    /// The wash going away, showing the real windows.
    var washOut: (Double, Double) { still ? (finale, finale + 0.5) : skipped ? (finale + 0.3, finale + 0.6) : (finale + 0.5, finale + 1.0) }
    /// The cards in the Workspace you're in dissolving onto the real windows.
    var cardsOut: (Double, Double) { still ? washOut : skipped ? (finale + 0.45, finale + 0.68) : (finale + 0.72, finale + 1.08) }
    var end: Double { still ? finale + 0.5 : skipped ? finale + 0.7 : finale + 1.15 }

    mutating func skip(at t: Double) {
        skipped = true
        finale = t
    }
}

// MARK: - One display's part

private final class Stage {
    let panel: ShowPanel
    private let display: Display
    private let root = CALayer()
    private let blur = NSVisualEffectView()
    private let wash = CALayer()
    private var blobs: [(layer: CAGradientLayer, phase: Double, speed: Double, home: CGPoint)] = []
    private var boxes: [Int: Box] = [:]
    private var cards: [(index: Int, layer: CardLayer, from: CGRect?, to: CGRect, space: Int?)] = []
    private var counts: [Int: Int] = [:]
    private var header: Label?
    private var hint: Label?
    private var tray: Label?
    private var trayHidden = 0
    private let spaces: [SortShow.Space]
    private let landing: Int
    private let headline: Bool
    private let visible: CGRect
    private let scale: CGFloat
    private var allLanded = false

    /// A Workspace in miniature: the box, the empty spots its windows go to, and its name.
    private struct Box {
        let rect: CGRect
        let frame: CALayer
        let slots: CALayer
        let label: Label
        let detail: Label
    }

    init?(display: Display, cards indices: [Int], all: [SortShow.Card], spaces: [SortShow.Space], landing: Int,
          headline: Bool, still: Bool, skip: @escaping () -> Void) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }) else { return nil }
        self.display = display
        self.spaces = spaces
        self.landing = landing
        self.headline = headline
        scale = screen.backingScaleFactor
        let size = display.frame.size
        visible = display.visible.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)

        panel = ShowPanel(frame: screen.frame, skip: skip)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        blur.frame = content.bounds
        blur.autoresizingMask = [.width, .height]
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0
        content.addSubview(blur)
        let host = NSView(frame: content.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        content.addSubview(host)
        panel.contentView = content
        root.frame = CGRect(origin: .zero, size: size)
        root.isGeometryFlipped = true // top-left, like window frames, for everything in it
        host.layer?.addSublayer(root)

        buildWash(size: size)
        let here = Set(indices.compactMap { all[$0].space })
        buildBoxes(for: spaces.indices.filter { here.contains($0) }, size: size)
        let trayIcon = trayRect(size: size)
        for i in indices {
            let card = all[i]
            let from = card.from.map { $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
            var target = trayIcon
            if let space = card.space, let to = card.to, let box = boxes[space] { target = mini(to, in: box.rect) }
            let layer = CardLayer(card: card, scale: scale, accent: card.space.map { spaces[$0].accent })
            layer.opacity = 0
            cards.append((i, layer, from, target, card.space))
        }
        // Stacked like the windows were: the one used last on top (and first to go).
        for card in cards.reversed() { root.addSublayer(card.layer) }
        addSlots()
        // Nothing flies with Reduce Motion: every Workspace shows its windows from the start.
        if still {
            for card in cards {
                if let space = card.space { counts[space, default: 0] += 1 } else { trayHidden += 1 }
            }
            for space in boxes.keys { updateDetail(space) }
        }
        if headline {
            let n = spaces.count
            let header = label(still ? Self.sorted(n) : "Sorting \(all.count) windows", size: 26, weight: .semibold, alpha: 0.96)
            let hint = label("Click anywhere or press Esc to skip", size: 13, weight: .regular, alpha: 0.6)
            let top = (boxes.values.map(\.rect.minY).min() ?? size.height * 0.3) - 96
            header.frame = CGRect(x: 0, y: top, width: size.width, height: 34)
            hint.frame = CGRect(x: 0, y: top + 40, width: size.width, height: 18)
            root.addSublayer(header)
            root.addSublayer(hint)
            self.header = header
            self.hint = hint
        }
        if indices.contains(where: { all[$0].space == nil }) {
            let line = label("", size: 13, weight: .medium, alpha: 0.82)
            line.alignmentMode = .left
            line.frame = CGRect(x: trayIcon.maxX + 10, y: trayIcon.minY + 2, width: 360, height: 18)
            root.addSublayer(line)
            tray = line
            updateTray()
        }
    }

    static func sorted(_ n: Int) -> String { n == 1 ? "Sorted into 1 Workspace" : "Sorted into \(n) Workspaces" }

    // MARK: Building

    private func buildWash(size: CGSize) {
        wash.frame = root.bounds
        wash.opacity = 0
        root.addSublayer(wash)
        let base = CAGradientLayer()
        base.frame = wash.bounds
        base.colors = [rgb(0x0b1033), rgb(0x18267a), rgb(0x2a55e6)]
        base.locations = [0, 0.55, 1]
        base.startPoint = CGPoint(x: 0, y: 0)
        base.endPoint = CGPoint(x: 1, y: 1)
        wash.addSublayer(base)
        // Soft lights drifting over it: the brand's blue, coral, amber, mint and a violet.
        let lights: [(UInt32, CGPoint)] = [(0x2f6bff, CGPoint(x: 0.25, y: 0.3)), (0xff6f61, CGPoint(x: 0.8, y: 0.25)),
                                           (0xffb347, CGPoint(x: 0.7, y: 0.85)), (0x2fd3a6, CGPoint(x: 0.15, y: 0.8)),
                                           (0x8a5cff, CGPoint(x: 0.5, y: 0.5))]
        let side = max(size.width, size.height) * 0.95
        for (i, (hex, home)) in lights.enumerated() {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.colors = [rgb(hex, alpha: 0.62), rgb(hex, alpha: 0.18), rgb(hex, alpha: 0)]
            blob.locations = [0, 0.45, 1]
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            blob.compositingFilter = "screenBlendMode"
            wash.addSublayer(blob)
            blobs.append((blob, Double(i) * 1.3, 0.35 + 0.08 * Double(i), CGPoint(x: home.x * size.width, y: home.y * size.height)))
        }
    }

    private func buildBoxes(for here: [Int], size: CGSize) {
        guard !here.isEmpty else { return }
        let n = CGFloat(here.count)
        let aspect = visible.width / max(1, visible.height)
        var width = size.width * (here.count == 1 ? 0.4 : here.count == 2 ? 0.33 : 0.27)
        width = min(width, size.height * 0.42 * aspect)
        let height = width / aspect
        let gap = size.width * 0.035
        let x0 = (size.width - n * width - (n - 1) * gap) / 2
        let y0 = (size.height - height) / 2 - size.height * 0.04
        for (k, s) in here.enumerated() {
            let rect = CGRect(x: x0 + CGFloat(k) * (width + gap), y: y0, width: width, height: height).integral
            let frame = CALayer()
            frame.frame = rect
            frame.cornerRadius = 14
            frame.cornerCurve = .continuous
            frame.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            frame.borderWidth = 1.5
            frame.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
            frame.opacity = 0
            root.addSublayer(frame)
            let slots = CALayer()
            slots.frame = root.bounds
            slots.opacity = 0
            root.addSublayer(slots)
            let title = label(spaces[s].title, size: 19, weight: .semibold, alpha: 0.96)
            title.frame = CGRect(x: rect.minX - 40, y: rect.maxY + 16, width: rect.width + 80, height: 26)
            title.opacity = 0
            root.addSublayer(title)
            let detail = label("", size: 13, weight: .medium, alpha: 0.66)
            detail.frame = CGRect(x: rect.minX - 40, y: rect.maxY + 44, width: rect.width + 80, height: 18)
            detail.opacity = 0
            root.addSublayer(detail)
            boxes[s] = Box(rect: rect, frame: frame, slots: slots, label: title, detail: detail)
            counts[s] = 0
            updateDetail(s)
        }
    }

    /// The empty spots in each miniature: where each window is going.
    private func addSlots() {
        for card in cards {
            guard let space = card.space, let box = boxes[space] else { continue }
            let slot = CAShapeLayer()
            slot.path = CGPath(roundedRect: card.to.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
            slot.fillColor = NSColor.white.withAlphaComponent(0.05).cgColor
            slot.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
            slot.lineWidth = 1
            slot.lineDashPattern = [4, 3]
            box.slots.addSublayer(slot)
        }
    }

    private func mini(_ tile: CGRect, in box: CGRect) -> CGRect {
        let k = box.width / max(1, visible.width)
        return CGRect(x: box.minX + (tile.minX - display.visible.minX) * k, y: box.minY + (tile.minY - display.visible.minY) * k,
                      width: tile.width * k, height: tile.height * k)
    }

    /// Where hidden windows go: a little line under the Workspaces.
    private func trayRect(size: CGSize) -> CGRect {
        let bottom = (boxes.values.map(\.rect.maxY).max() ?? size.height * 0.6) + 92
        return CGRect(x: size.width / 2 - 170, y: bottom, width: 22, height: 22)
    }

    private func label(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> Label {
        let layer = Label()
        layer.contentsScale = scale
        layer.alignmentMode = .center
        layer.truncationMode = .end
        layer.attributes = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
        layer.text = string
        return layer
    }

    private func updateDetail(_ space: Int) {
        guard let box = boxes[space] else { return }
        let count = counts[space] ?? 0
        box.detail.text = (spaces[space].key.map { "\($0)  ·  " } ?? "") + (count == 1 ? "1 window" : "\(count) windows")
    }

    private func updateTray() {
        tray?.text = trayHidden == 0 ? "Past what fits: hidden, still open" : "\(trayHidden) hidden, still open  ·  Summon finds them"
    }

    // MARK: Playing

    func landed(_ index: Int) {
        guard let card = cards.first(where: { $0.index == index }) else { return }
        guard let space = card.space, let box = boxes[space] else {
            trayHidden += 1
            updateTray()
            return
        }
        counts[space, default: 0] += 1
        updateDetail(space)
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1, 1.018, 1]
        pulse.keyTimes = [0, 0.35, 1]
        pulse.duration = 0.32
        box.frame.add(pulse, forKey: "pulse")
        let glow = CABasicAnimation(keyPath: "borderColor")
        glow.fromValue = spaces[space].accent.cgColor
        glow.toValue = NSColor.white.withAlphaComponent(0.3).cgColor
        glow.duration = 0.5
        box.frame.add(glow, forKey: "glow")
    }

    func render(_ t: Double, timeline: Timeline) {
        let finale = timeline.finale
        let still = timeline.still
        let washGone = smooth(timeline.washOut.0, timeline.washOut.1, t)
        let washUp = min(smooth(0, timeline.cover, t), 1 - washGone)
        wash.opacity = Float(washUp * 0.94)
        blur.alphaValue = CGFloat(washUp)
        let drift = min(root.bounds.width, root.bounds.height) * 0.12
        for blob in blobs {
            let a = blob.phase + t * blob.speed
            blob.layer.position = CGPoint(x: blob.home.x + CGFloat(cos(a)) * drift, y: blob.home.y + CGFloat(sin(a * 1.3)) * drift)
            let breathe = CGFloat(1 + 0.08 * sin(a * 0.7))
            blob.layer.transform = CATransform3DMakeScale(breathe, breathe, 1)
        }

        // Everything but the Workspace you're in goes, dropping a little.
        let away = still ? washGone : smooth(finale, finale + 0.35, t)
        let drop = CGFloat(still ? 0 : 24 * away)
        let open = still ? 0 : ease(clamp((t - finale) / timeline.opening))
        let inTime = smooth(0.3, still ? 0.7 : 0.75, t)
        header?.opacity = Float(inTime * (1 - away))
        hint?.opacity = Float(inTime * (1 - away) * (timeline.skipped ? 0 : 1))
        tray?.opacity = Float(smooth(timeline.flyStart, timeline.flyStart + 0.3, t) * (1 - away))
        if let header, !allLanded, !still, t >= timeline.arrival(max(0, cards.count - 1)) || timeline.skipped {
            allLanded = true
            header.text = Self.sorted(spaces.count)
        }

        // The Workspace you're in grows from its miniature to the whole screen.
        var landingRect: CGRect?
        for (s, box) in boxes {
            let opening = s == landing && !still
            let rect = opening ? lerp(box.rect, visible, open) : box.rect.offsetBy(dx: 0, dy: drop)
            if opening { landingRect = rect }
            box.frame.frame = rect
            box.frame.cornerRadius = opening ? 14 * CGFloat(1 - open) : 14
            box.frame.opacity = Float(inTime * (opening ? 1 - smooth(finale, finale + 0.5, t) : 1 - away))
            box.slots.opacity = Float(inTime * (1 - (still ? washGone : smooth(finale, finale + 0.25, t))))
            box.label.opacity = Float(inTime * (1 - away))
            box.detail.opacity = Float(inTime * (1 - away))
            let down = CATransform3DMakeTranslation(0, drop, 0)
            box.label.transform = down
            box.detail.transform = down
        }

        for card in cards {
            var target = card.to
            if let space = card.space, space == landing, let landingRect, let box = boxes[space] {
                // In the Workspace that opens, it rides along to its real tile.
                target = remap(card.to, from: box.rect, to: landingRect)
            } else if !still {
                target = target.offsetBy(dx: 0, dy: drop)
            }
            let rect: CGRect, shrink: Double
            var opacity: Double
            let p = still || t >= finale ? 1 : clamp((t - timeline.start(card.index)) / timeline.flight)
            if still {
                rect = target
                shrink = 1
                opacity = smooth(0.35, 0.7, t)
            } else if let from = card.from {
                // Lifted off the desktop as the wash comes up, then a gentle arc to its spot.
                let lift = CGFloat(0.035 * smooth(0.1, 0.6, t))
                let start = from.insetBy(dx: from.width * lift / 2, dy: from.height * lift / 2)
                rect = arc(from: start, to: target, e: glide(p), sizeE: glide(min(1, p * 1.15)))
                shrink = glide(p)
                // A picture of the window takes its place at once; an icon card rises out of the
                // color once the color has covered the window, rather than flashing over it.
                opacity = card.layer.picture ? smooth(0.02, 0.3, t) : smooth(0.3, 0.6, t)
            } else {
                // Out of sight before: it appears at its spot.
                let grow = CGFloat(0.6 + 0.4 * glide(p))
                rect = target.insetBy(dx: target.width * (1 - grow) / 2, dy: target.height * (1 - grow) / 2)
                shrink = 1
                opacity = smooth(timeline.start(card.index), timeline.start(card.index) + 0.3, t)
            }
            if card.space == nil {
                opacity *= (1 - smooth(0.7, 1, p)) * (1 - away)
            } else if card.space == landing, !still {
                opacity *= 1 - smooth(timeline.cardsOut.0, timeline.cardsOut.1, t)
            } else {
                opacity *= 1 - away
            }
            card.layer.opacity = Float(opacity)
            // In flight over everything; landed over the ones still waiting.
            card.layer.zPosition = still || p >= 1 ? 1 : p > 0 ? 2 : 0
            if opacity > 0.001 { card.layer.place(in: rect, shrink: shrink, landed: card.space != nil ? smooth(0.55, 1, shrink) : 0) }
        }
    }

    private func arc(from a: CGRect, to b: CGRect, e: Double, sizeE: Double) -> CGRect {
        let c0 = a.center, c2 = b.center
        let distance = hypot(c2.x - c0.x, c2.y - c0.y)
        let c1 = CGPoint(x: (c0.x + c2.x) / 2, y: (c0.y + c2.y) / 2 - min(180, distance * 0.3))
        let u = CGFloat(e), v = 1 - u
        let center = CGPoint(x: v * v * c0.x + 2 * v * u * c1.x + u * u * c2.x, y: v * v * c0.y + 2 * v * u * c1.y + u * u * c2.y)
        let s = CGFloat(sizeE)
        let size = CGSize(width: a.width + (b.width - a.width) * s, height: a.height + (b.height - a.height) * s)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func remap(_ r: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let k = to.width / max(1, from.width)
        return CGRect(x: to.minX + (r.minX - from.minX) * k, y: to.minY + (r.minY - from.minY) * k, width: r.width * k, height: r.height * k)
    }
}

/// Text that keeps its font and color when its words change.
private final class Label: CATextLayer {
    var attributes: [NSAttributedString.Key: Any] = [:]
    var text = "" {
        didSet { if text != oldValue || string == nil { string = NSAttributedString(string: text, attributes: attributes) } }
    }

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - A window's stand-in

private final class CardLayer: CALayer {
    private let face = CALayer()
    private let bar = CALayer()
    private let lights = [CALayer(), CALayer(), CALayer()]
    private let icon = CALayer()
    private let title = CATextLayer()
    /// It shows a picture of the window (Screen Recording is allowed), not its app's icon.
    let picture: Bool
    private let accent: NSColor?

    init(card: SortShow.Card, scale: CGFloat, accent: NSColor?) {
        picture = card.snapshot != nil
        self.accent = accent
        super.init()
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.35
        shadowRadius = 18
        shadowOffset = CGSize(width: 0, height: 10)
        face.masksToBounds = true
        face.cornerCurve = .continuous
        face.backgroundColor = NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1).cgColor
        addSublayer(face)
        if let snapshot = card.snapshot {
            face.contents = snapshot
            face.contentsGravity = .resizeAspectFill
        } else {
            bar.backgroundColor = NSColor(srgbRed: 0.92, green: 0.925, blue: 0.94, alpha: 1).cgColor
            face.addSublayer(bar)
            for (light, hex) in zip(lights, [0xff5f57, 0xfebc2e, 0x28c840] as [UInt32]) {
                light.backgroundColor = rgb(hex)
                bar.addSublayer(light)
            }
            title.contentsScale = scale
            title.truncationMode = .end
            title.string = NSAttributedString(string: card.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1),
            ])
            bar.addSublayer(title)
        }
        var box = NSRect(x: 0, y: 0, width: 256, height: 256)
        icon.contents = card.icon.cgImage(forProposedRect: &box, context: nil, hints: nil)
        icon.contentsGravity = .resizeAspect
        icon.shadowOpacity = 0.25
        icon.shadowRadius = 6
        icon.shadowOffset = CGSize(width: 0, height: 3)
        face.addSublayer(icon)
    }

    override init(layer: Any) {
        picture = false
        accent = nil
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lays the card out at `rect`; `shrink` is how far it has gone toward its spot (0 to 1),
    /// `landed` how much it shows its Workspace's color.
    func place(in rect: CGRect, shrink: Double, landed: Double) {
        frame = rect
        let w = rect.width, h = rect.height
        let radius = max(4, min(12, min(w, h) * 0.08))
        face.frame = bounds
        face.cornerRadius = radius
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        shadowRadius = 6 + 12 * (1 - CGFloat(shrink))
        face.borderWidth = 2 * CGFloat(landed)
        face.borderColor = (accent ?? .white).cgColor
        let barHeight = picture ? 0 : max(5, min(26, h * 0.09))
        if !picture {
            bar.frame = CGRect(x: 0, y: 0, width: w, height: barHeight) // inside the show, y runs down
            let d = barHeight * 0.44
            for (k, light) in lights.enumerated() {
                light.frame = CGRect(x: barHeight * 0.5 + CGFloat(k) * d * 1.6, y: (barHeight - d) / 2, width: d, height: d)
                light.cornerRadius = d / 2
            }
            let showTitle = w > 220 && shrink < 0.35
            title.isHidden = !showTitle
            if showTitle {
                title.frame = CGRect(x: barHeight * 0.5 + 3 * d * 1.6 + 8, y: (barHeight - 15) / 2, width: max(0, w - barHeight * 3.4 - 16), height: 15)
                title.opacity = Float(1 - smooth(0, 0.35, shrink))
            }
        }
        let side = max(12, min(96, min(w, h - barHeight) * 0.36))
        icon.frame = CGRect(x: (w - side) / 2, y: barHeight + (h - barHeight - side) / 2, width: side, height: side)
        icon.opacity = picture ? Float(smooth(0.35, 0.85, shrink)) : 1
    }
}

/// The show's window on one display: covers it all, above everything, and skips to the end
/// when clicked or on Esc.
private final class ShowPanel: NSPanel {
    private let skip: () -> Void

    init(frame: NSRect, skip: @escaping () -> Void) {
        self.skip = skip
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) { skip() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { skip() } // Esc
    }

    override func cancelOperation(_ sender: Any?) { skip() }
}

// MARK: - Afterwards

/// "Sorted into 3 Workspaces", which key goes where, and Undo, for ten seconds at the bottom of
/// the screen.
final class SortSummary {
    var onUndo: (() -> Void)?
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(title: String, detail: String, on display: Display?, undo: Bool) {
        dismiss()
        let screen = display.flatMap { d in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.id }
        } ?? NSScreen.main
        guard let screen else { return }
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        check.contentTintColor = SortShow.accent(for: .work)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let line = NSTextField(labelWithString: detail)
        line.font = .systemFont(ofSize: 12)
        line.textColor = .secondaryLabelColor
        line.lineBreakMode = .byTruncatingTail
        let words = NSStackView(views: [heading, line])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        var views: [NSView] = [check, words]
        if undo {
            let button = FirstClickButton(title: "Undo", target: self, action: #selector(undoPressed))
            button.bezelStyle = .rounded
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        let size = NSSize(width: min(screen.visibleFrame.width - 40, row.fittingSize.width), height: max(52, row.fittingSize.height))
        let area = screen.visibleFrame
        let panel = NSPanel(contentRect: NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.minY + area.height * 0.06).rounded(),
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // A dark HUD whatever the Mac's appearance, tinted so it reads even where there's no blur.
        panel.appearance = NSAppearance(named: .darkAqua)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.72).cgColor
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        row.frame = background.bounds
        row.autoresizingMask = [.width, .height]
        background.addSubview(row)
        panel.contentView = background
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func dismiss(animated: Bool = false) {
        hide?.cancel()
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    @objc private func undoPressed() {
        dismiss(animated: true)
        onUndo?()
    }
}

/// Works on the first click, without Lunchbox coming forward first.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Easing

private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = clamp((x - a) / max(0.0001, b - a))
    return t * t * (3 - 2 * t)
}

private func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

/// Off quickly, then a long soft settle (a critically damped spring), reaching 1 exactly at 1.
private func glide(_ p: Double) -> Double {
    let k = 6.5
    return (1 - (1 + k * p) * exp(-k * p)) / (1 - (1 + k) * exp(-k))
}

private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    let u = CGFloat(t)
    return CGRect(x: a.minX + (b.minX - a.minX) * u, y: a.minY + (b.minY - a.minY) * u,
                  width: a.width + (b.width - a.width) * u, height: a.height + (b.height - a.height) * u)
}

private func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
