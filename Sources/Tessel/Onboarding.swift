import AppKit
import ServiceManagement
import TesselCore

/// First-run setup: welcome, Accessibility, the three space keys, a short
/// hands-on practice, and a few preferences. Also reachable from the menu.
final class Onboarding: NSObject, NSWindowDelegate {
    enum Step: Int, CaseIterable {
        case welcome, access, keys, practice, finish
    }

    var onSpaceKeys: (([Int64]) -> Void)?
    var onRequestAccess: (() -> Void)?
    var onCustomize: (() -> Void)?

    private let tap: HotkeyTap
    private let tiler: Tiler
    private var window: NSWindow?
    private let stage = NSView()
    private let dots = NSStackView()
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let next = NSButton(title: "Continue", target: nil, action: nil)
    private var step: Step = .welcome
    private var trustTimer: Timer?

    // Keys step
    private var keys: [Int64] = []
    private var slots: [KeySlot] = []
    private let keyHint = NSTextField(labelWithString: "")

    // Practice step
    private var practiceRows: [String: PracticeRow] = [:]
    private var practiced = Set<String>()
    private var playground: Playground?

    private static let normalSize = NSSize(width: 760, height: 560)
    private static let practiceSize = NSSize(width: 1300, height: 760)

    // Finish step
    private let previewStatus = NSTextField(labelWithString: "")

    init(tap: HotkeyTap, tiler: Tiler) {
        self.tap = tap
        self.tiler = tiler
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func close() { window?.close() }

    func show(at start: Step = .welcome) {
        let window = self.window ?? makeWindow()
        if !isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        go(to: start, animated: false)
    }

    /// Opens a step centered on one display without activating Tessel, so an
    /// agent can look at it on a display Tyler can't see while he keeps typing.
    func show(at start: Step, onDisplay id: CGDirectDisplayID) {
        let window = self.window ?? makeWindow()
        go(to: start, animated: false)
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) {
            let area = screen.visibleFrame, size = window.frame.size
            window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }
        window.orderFrontRegardless()
    }

    /// While the practice step is in front, window shortcuts drive the
    /// playground instead of real windows. Switch to another app and they work
    /// on the real desktop again, so onboarding never takes over the Mac.
    var capturesWindowActions: Bool {
        isVisible && step == .practice && (window?.isKeyWindow ?? false)
    }

    func playgroundPerform(_ action: KeyAction) { playground?.perform(action) }
    func playgroundType(_ text: String) { playground?.type(text) }
    func playgroundKey(_ name: String) { playground?.press(name) }

    /// Practice: tick off a shortcut the user just used.
    func noted(_ action: KeyAction) {
        guard isVisible, step == .practice else { return }
        let id: String
        switch action {
        case .focus: id = "focus"
        case .move: id = "move"
        case .grow, .shrink: id = "size"
        case .spotlight: id = "focusMode"
        case .normalize: id = "tidy"
        case .switchSpace, .sendToSpace: id = "space"
        case .launcher: id = "summon"
        case .help: id = "help"
        default: return
        }
        guard !practiced.contains(id), let row = practiceRows[id] else { return }
        practiced.insert(id)
        row.markDone()
        if practiced.count == practiceRows.count { next.title = "Continue" }
    }

    // MARK: Steps

    private func go(to target: Step, animated: Bool = true) {
        if step == .keys && target != .keys { tap.learnNextKey(nil) }
        trustTimer?.invalidate()
        step = target
        let view: NSView
        switch target {
        case .welcome: view = welcomeView()
        case .access: view = accessView()
        case .keys: view = keysView()
        case .practice: view = practiceView()
        case .finish: view = finishView()
        }
        swap(to: view, animated: animated)
        updateFooter()
        resizeWindow(to: target == .practice ? Self.practiceSize : Self.normalSize, animated: animated)
    }

    /// The practice step opens up into a big window with the playground; the
    /// other steps stay compact. Grows around its center, kept on screen.
    private func resizeWindow(to size: NSSize, animated: Bool) {
        guard let window, window.frame.size != size else { return }
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        var frame = NSRect(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2,
                           width: min(size.width, area.width), height: min(size.height, area.height))
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func updateFooter() {
        for (i, dot) in dots.arrangedSubviews.enumerated() {
            dot.layer?.backgroundColor = (i == step.rawValue ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
        }
        back.isHidden = step == .welcome
        switch step {
        case .welcome: next.title = "Get Started"; next.isEnabled = true
        case .access: next.title = "Continue"; next.isEnabled = AXIsProcessTrusted()
        case .keys: next.title = "Continue"; next.isEnabled = keys.count == 3
        case .practice: next.title = practiced.count == practiceRows.count ? "Continue" : "Skip for Now"; next.isEnabled = true
        case .finish: next.title = "Start Using Tessel"; next.isEnabled = true
        }
    }

    @objc private func goNext() {
        if let following = Step(rawValue: step.rawValue + 1) {
            go(to: following)
        } else {
            UserDefaults.standard.set(true, forKey: "onboardingDone")
            window?.orderOut(nil)
        }
    }

    @objc private func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) { go(to: previous) }
    }

    func windowWillClose(_ notification: Notification) {
        tap.learnNextKey(nil)
        trustTimer?.invalidate()
    }

    // MARK: Welcome

    private func welcomeView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true
        return page(top: icon,
                    title: "Welcome to Tessel",
                    body: "Every window, right where it belongs. In about a minute Tessel will be tiling your windows, and you'll know the few keys that matter.")
    }

    // MARK: Accessibility

    private func accessView() -> NSView {
        let status = StatusPill()
        let open = NSButton(title: "Open System Settings", target: self, action: #selector(requestAccess))
        open.bezelStyle = .rounded
        open.controlSize = .large
        let row = NSStackView(views: [status, open])
        row.orientation = .vertical
        row.spacing = 16
        let refresh = { [weak self] in
            let granted = AXIsProcessTrusted()
            status.set(granted ? "Access granted" : "Waiting for access…", done: granted)
            open.isHidden = granted
            if self?.step == .access { self?.next.isEnabled = granted }
        }
        refresh()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in refresh() }
        return page(top: symbol("hand.raised.fingers.spread.fill"),
                    title: "Let Tessel move your windows",
                    body: "macOS asks you to allow Tessel under Privacy & Security › Accessibility. That's how it arranges windows and hears its shortcuts. It never records what you type.",
                    content: row)
    }

    @objc private func requestAccess() { onRequestAccess?() }

    // MARK: Space keys

    private func keysView() -> NSView {
        keys = []
        slots = (1...3).map { KeySlot(space: $0) }
        slots.first?.isCurrent = true
        let row = NSStackView(views: slots)
        row.spacing = 18
        keyHint.font = .systemFont(ofSize: 13)
        keyHint.textColor = .secondaryLabelColor
        keyHint.alignment = .center
        keyHint.stringValue = AXIsProcessTrusted() ? " " : "Allow Accessibility first, then come back to this step."
        let redo = NSButton(title: "Start Over", target: self, action: #selector(restartKeys))
        redo.bezelStyle = .inline
        let column = NSStackView(views: [row, keyHint, redo])
        column.orientation = .vertical
        column.spacing = 14
        listenForKey()
        return page(top: symbol("keyboard"),
                    title: "Choose your Workspace keys",
                    body: "Tessel gives you three Workspaces. Tap three keys you never use, ideally out of the way on the right side of your keyboard. Page Up, Page Down and End are perfect, or F13, F14 and F15. They become Workspaces 1, 2 and 3.",
                    content: column)
    }

    private func listenForKey() {
        guard AXIsProcessTrusted(), keys.count < 3 else { return }
        tap.learnNextKey { [weak self] code, _ in self?.learned(code) }
    }

    private func learned(_ code: Int64) {
        guard step == .keys, keys.count < 3 else { return }
        if !KeyNames.isGoodWorkspaceKey(code) {
            keyHint.stringValue = "That key is used for typing. Try one on the far right, like Page Up or End."
        } else if keys.contains(code) {
            keyHint.stringValue = "You already picked that one. Tap a different key."
        } else {
            slots[keys.count].fill(with: KeyNames.name(code))
            keys.append(code)
            keyHint.stringValue = keys.count == 3 ? "All set. ⌘ plus a Workspace key switches Workspaces." : " "
            if keys.count < 3 { slots[keys.count].isCurrent = true }
            if keys.count == 3 {
                onSpaceKeys?(keys)
                next.isEnabled = true
            }
        }
        listenForKey()
    }

    @objc private func restartKeys() {
        tap.learnNextKey(nil)
        keys = []
        for (i, slot) in slots.enumerated() { slot.clear(); slot.isCurrent = i == 0 }
        keyHint.stringValue = " "
        next.isEnabled = false
        listenForKey()
    }

    // MARK: Practice

    private func practiceView() -> NSView {
        practiceRows = [:]
        let keymap = tap.keymap
        let keys = tap.spaceKeys
        let caps = { (c: Command) in Keymap.keycaps(for: keymap.binding(for: c), workspaceKeys: keys) }
        let items: [(String, [String], String)] = [
            ("focus", caps(.focusRight), "Move focus to the next window"),
            ("move", caps(.moveLeft), "Move a window (press again to pass)"),
            ("size", caps(.grow), "Give a window more space"),
            ("focusMode", caps(.focusMode), "Focus on one window, then again to undo"),
            ("tidy", caps(.tidy), "Tidy everything back to even"),
            ("space", caps(.workspace2), "Go to Workspace 2, and back"),
            ("summon", caps(.summon), "Summon an app (Esc closes it)"),
            ("help", caps(.cheatSheet), "Open the Cheat Sheet (Esc closes it)"),
        ]
        let rows = items.map { id, keys, label -> PracticeRow in
            let row = PracticeRow(keys: keys, label: label)
            if practiced.contains(id) { row.markDone(animated: false) }
            practiceRows[id] = row
            return row
        }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12

        let playground = self.playground ?? Playground(frame: NSRect(x: 0, y: 0, width: 816, height: 510))
        self.playground = playground
        playground.cheatEntries = { [weak self] in
            guard let tap = self?.tap else { return [] }
            return CheatSheetContent.entries(keymap: tap.keymap, workspaceKeys: tap.spaceKeys)
        }
        playground.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playground.widthAnchor.constraint(equalToConstant: 816),
            playground.heightAnchor.constraint(equalToConstant: 510),
        ])
        let reset = NSButton(title: "Reset the Practice Space", target: self, action: #selector(resetPlayground))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        let left = NSStackView(views: [playground, reset])
        left.orientation = .vertical
        left.spacing = 10

        let heading = NSTextField(labelWithString: "Try it on a practice screen")
        heading.font = .systemFont(ofSize: 26, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString: "Your shortcuts move the pretend windows on the left, never your real ones. Each one lights up as you use it.")
        text.font = .systemFont(ofSize: 14)
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 380
        let right = NSStackView(views: [heading, text, list])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 14
        right.setCustomSpacing(22, after: text)
        right.translatesAutoresizingMaskIntoConstraints = false
        right.widthAnchor.constraint(equalToConstant: 380).isActive = true
        for row in rows { row.widthAnchor.constraint(equalToConstant: 380).isActive = true }

        let layout = NSStackView(views: [left, right])
        layout.orientation = .horizontal
        layout.alignment = .top
        layout.spacing = 32
        return layout
    }

    @objc private func resetPlayground() { playground?.reset() }

    // MARK: Finish

    private func finishView() -> NSView {
        let login = toggleRow("Open Tessel when you log in", on: SMAppService.mainApp.status == .enabled) { on in
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { log.error("login item: \(error.localizedDescription, privacy: .public)") }
        }
        let displays = toggleRow("Tile on every display", on: tiler.useAllDisplays) { [weak self] on in
            self?.tiler.setUseAllDisplays(on)
        }
        let allowed = CGPreflightScreenCaptureAccess()
        previewStatus.stringValue = allowed ? "Window previews are on" : "Show live previews on the Shelf in Focus"
        previewStatus.font = .systemFont(ofSize: 14)
        let previews = NSButton(title: allowed ? "Allowed" : "Allow…", target: self, action: #selector(allowPreviews))
        previews.bezelStyle = .rounded
        previews.isEnabled = !allowed
        let previewRow = NSStackView(views: [previewStatus, NSView(), previews])
        previewRow.translatesAutoresizingMaskIntoConstraints = false
        previewRow.widthAnchor.constraint(equalToConstant: 440).isActive = true
        let customize = NSButton(title: "Customize Shortcuts…", target: self, action: #selector(customizeShortcuts))
        customize.bezelStyle = .rounded
        let list = NSStackView(views: [login, displays, previewRow, customize])
        list.orientation = .vertical
        list.spacing = 14
        return page(top: symbol("slider.horizontal.3"),
                    title: "Make it yours",
                    body: "Change these any time from Tessel's menu bar icon. Every shortcut can be changed to keys you like, and Left ⌘⇧Space shows them all whenever you forget one.",
                    content: list)
    }

    @objc private func customizeShortcuts() { onCustomize?() }

    @objc private func allowPreviews() {
        DispatchQueue.global(qos: .utility).async { _ = CGRequestScreenCaptureAccess() }
        previewStatus.stringValue = "Turn on Tessel in System Settings, then reopen Tessel"
    }

    // MARK: Building blocks

    private func page(top: NSView, title: String, body: String, content: NSView? = nil) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 30, weight: .semibold)
        heading.alignment = .center
        let text = NSTextField(wrappingLabelWithString: body)
        text.font = .systemFont(ofSize: 15)
        text.textColor = .secondaryLabelColor
        text.alignment = .center
        text.preferredMaxLayoutWidth = 520
        var views: [NSView] = [top, heading, text]
        if let content { views.append(content) }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 14
        column.setCustomSpacing(22, after: top)
        column.setCustomSpacing(26, after: text)
        return column
    }

    private func symbol(_ name: String) -> NSView {
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage())
        view.contentTintColor = .controlAccentColor
        return view
    }

    private func toggleRow(_ title: String, on: Bool, change: @escaping (Bool) -> Void) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14)
        let toggle = ClosureSwitch(change: change)
        toggle.state = on ? .on : .off
        let row = NSStackView(views: [label, NSView(), toggle])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return row
    }

    private func swap(to view: NSView, animated: Bool) {
        let old = stage.subviews
        view.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            view.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor),
        ])
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            old.forEach { $0.removeFromSuperview() }
            return
        }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            view.animator().alphaValue = 1
            old.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { old.forEach { $0.removeFromSuperview() } })
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "Welcome to Tessel"

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active

        for _ in Step.allCases {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dots.addArrangedSubview(dot)
        }
        dots.spacing = 8
        back.target = self
        back.action = #selector(goBack)
        back.bezelStyle = .rounded
        back.controlSize = .large
        next.target = self
        next.action = #selector(goNext)
        next.bezelStyle = .rounded
        next.controlSize = .large
        next.keyEquivalent = "\r"

        for v in [stage, dots, back, next] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
            stage.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 40),
            stage.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -40),
            stage.bottomAnchor.constraint(equalTo: next.topAnchor, constant: -20),
            dots.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 32),
            dots.centerYAnchor.constraint(equalTo: next.centerYAnchor),
            next.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
            next.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -26),
            back.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -10),
            back.centerYAnchor.constraint(equalTo: next.centerYAnchor),
        ])
        window.contentView = background
        self.window = window
        return window
    }
}

/// One of the three big key slots: empty and numbered until a key is tapped.
private final class KeySlot: NSView {
    private let keyLabel = NSTextField(labelWithString: "")
    private let caption: NSTextField
    var isCurrent = false { didSet { refresh() } }
    private var filled = false

    init(space: Int) {
        caption = NSTextField(labelWithString: "Workspace \(space)")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2
        translatesAutoresizingMaskIntoConstraints = false
        keyLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        keyLabel.alignment = .center
        keyLabel.stringValue = "\(space)"
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .secondaryLabelColor
        for v in [keyLabel, caption] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 150),
            heightAnchor.constraint(equalToConstant: 100),
            keyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            keyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func fill(with name: String) {
        filled = true
        isCurrent = false
        keyLabel.stringValue = name
        refresh()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.92, 1.06, 1]
        pop.keyTimes = [0, 0.55, 1]
        pop.duration = 0.32
        layer.add(pop, forKey: "pop")
    }

    func clear() {
        filled = false
        keyLabel.stringValue = caption.stringValue.replacingOccurrences(of: "Workspace ", with: "")
        refresh()
    }

    private func refresh() {
        let accent = NSColor.controlAccentColor
        layer?.borderColor = (filled || isCurrent ? accent : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (filled ? accent.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(0.04)).cgColor
        keyLabel.textColor = filled ? .labelColor : (isCurrent ? accent : .tertiaryLabelColor)
    }
}

/// A practice item: a circle that turns into a check, the keycaps, and what they do.
private final class PracticeRow: NSStackView {
    private let check = NSImageView()

    init(keys: [String], label text: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false
        check.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Not yet")
        check.contentTintColor = .tertiaryLabelColor
        check.translatesAutoresizingMaskIntoConstraints = false
        check.widthAnchor.constraint(equalToConstant: 18).isActive = true
        check.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let caps = NSStackView(views: keys.map { k in
            k == "then" ? NSTextField(labelWithString: "then") as NSView : Keycap(text: k)
        })
        caps.spacing = 4
        // Every row's keys sit in the same width, so the descriptions line up.
        caps.translatesAutoresizingMaskIntoConstraints = false
        let capsBox = NSView()
        capsBox.translatesAutoresizingMaskIntoConstraints = false
        capsBox.addSubview(caps)
        NSLayoutConstraint.activate([
            capsBox.widthAnchor.constraint(equalToConstant: 150),
            capsBox.heightAnchor.constraint(equalTo: caps.heightAnchor),
            caps.leadingAnchor.constraint(equalTo: capsBox.leadingAnchor),
            caps.centerYAnchor.constraint(equalTo: capsBox.centerYAnchor),
        ])
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .left
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setViews([check, capsBox, label], in: .leading)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func markDone(animated: Bool = true) {
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
        check.contentTintColor = .systemGreen
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        check.wantsLayer = true
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.25, 1]
        pop.duration = 0.3
        check.layer?.add(pop, forKey: "pop")
    }
}

/// The Accessibility step's status: a spinner while waiting, a check when done.
private final class StatusPill: NSStackView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: 14, weight: .medium)
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemGreen
        setViews([spinner, icon, label], in: .leading)
        spacing = 8
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ text: String, done: Bool) {
        label.stringValue = text
        icon.isHidden = !done
        spinner.isHidden = done
        if done { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }
}

private final class ClosureSwitch: NSSwitch {
    private let change: (Bool) -> Void

    init(change: @escaping (Bool) -> Void) {
        self.change = change
        super.init(frame: .zero)
        target = self
        action = #selector(toggled)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggled() { change(state == .on) }
}
