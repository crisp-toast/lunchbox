import AppKit
import ServiceManagement
import LunchboxCore

/// First-run setup: welcome, Accessibility, a short hands-on practice, a few preferences, and,
/// when there's a mess worth it, whether to sort the windows already open. Also reachable from
/// the menu.
final class Onboarding: NSObject, NSWindowDelegate {
    enum Step: Int, CaseIterable {
        case welcome, access, practice, finish, sort
    }

    var onRequestAccess: (() -> Void)?
    var onCustomize: (() -> Void)?
    /// The shortcuts changed here (arrow keys or Vim keys, on the practice step).
    var onKeymapChange: ((Keymap) -> Void)?
    /// The welcome window went away: finished, or closed.
    var onClose: (() -> Void)?
    /// What sorting the open windows would do; nil when it wouldn't help (then setup doesn't ask).
    var sortPreview: (() -> (plan: WindowSort.Plan, icons: [WindowID: NSImage])?)?
    /// Whether Lunchbox can tile yet (it's licensed), for the sort step's note.
    var canTile: (() -> Bool)?
    /// Organize My Windows, on setup's last step.
    var onSort: (() -> Void)?
    /// Start Fresh, confirmed: close these windows.
    var onStartFresh: (([StartFresh.Window]) -> Void)?

    private let tap: HotkeyTap
    private let tiler: Tiler
    private var window: NSWindow?
    private let stage = NSView()
    private let dots = NSStackView()
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let next = NSButton(title: "Continue", target: nil, action: nil)
    private let notNow = NSButton(title: "Not Now", target: nil, action: nil)
    /// Setup ends by asking about sorting the open windows (there are enough to be worth it).
    private var offersSort = false
    private var step: Step = .welcome
    private var trustTimer: Timer?
    /// Set up before, and only Accessibility is missing again: just that step, which closes
    /// itself once access is back.
    private var accessOnly = false
    /// Dragged somewhere by the user: it stays there (growing around its own center) instead of
    /// going back to the middle of the screen.
    private var placedByUser = false
    private var placing = false

    // Practice step
    private var practiceRows: [String: PracticeRow] = [:]
    private var practiced = Set<String>()
    private var playground: Playground?

    private static let normalSize = NSSize(width: 760, height: 560)
    private static let practiceSize = NSSize(width: 1300, height: 760)
    private static let finishSize = NSSize(width: 600, height: 540)
    private static let sortSize = NSSize(width: 640, height: 640)

    // Finish step
    private let previewStatus = NSTextField(labelWithString: "")

    init(tap: HotkeyTap, tiler: Tiler) {
        self.tap = tap
        self.tiler = tiler
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func close() { window?.close() }

    /// Back in front, on the step it was on (after the license window, say).
    func bringToFront() {
        guard let window, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func show(at start: Step = .welcome, accessOnly: Bool = false) {
        self.accessOnly = accessOnly && start == .access
        let window = self.window ?? makeWindow()
        if !isVisible {
            placedByUser = false
            // The screen you're using: the one with the pointer.
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let area = screen?.visibleFrame { place(window, at: Self.centered(window.frame.size, in: area), animated: false) }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        offersSort = !self.accessOnly && sortPreview?() != nil
        go(to: start, animated: false)
    }

    func windowDidMove(_ notification: Notification) {
        // Only a drag (the mouse is down) counts, never one of Lunchbox's own moves.
        if !placing, NSEvent.pressedMouseButtons & 1 != 0 { placedByUser = true }
    }

    private static func centered(_ size: NSSize, in area: NSRect) -> NSRect {
        NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    private func place(_ window: NSWindow, at frame: NSRect, animated: Bool) {
        placing = true
        window.setFrame(frame, display: true, animate: animated)
        placing = false
    }

    /// Opens a step centered on one display without activating LunchboxWM, so an
    /// agent can look at it on a display Tyler can't see while he keeps typing.
    func show(at start: Step, onDisplay id: CGDirectDisplayID) {
        let window = self.window ?? makeWindow()
        offersSort = sortPreview?() != nil
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
        case .close: id = "close"
        // Resize mode counts once an arrow (or a focus key) has pushed an edge.
        case .resizeAlong: id = "resize"
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
        trustTimer?.invalidate()
        step = target
        let view: NSView
        switch target {
        case .welcome: view = welcomeView()
        case .access: view = accessView()
        case .practice: view = practiceView()
        case .finish: view = finishView()
        case .sort: view = sortView()
        }
        swap(to: view, animated: animated)
        updateFooter()
        let size = switch target {
        case .practice: Self.practiceSize
        case .finish: Self.finishSize
        case .sort: Self.sortSize
        default: Self.normalSize
        }
        resizeWindow(to: size, animated: animated)
    }

    /// The practice step opens up into a big window with the playground; the
    /// other steps stay compact. In the middle of its screen, until it's dragged somewhere: then it
    /// grows around its own center. Kept on screen either way.
    private func resizeWindow(to size: NSSize, animated: Bool) {
        guard let window, window.frame.size != size else { return }
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let fitted = NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
        var frame = placedByUser
            ? NSRect(x: window.frame.midX - fitted.width / 2, y: window.frame.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
            : Self.centered(fitted, in: area)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        place(window, at: frame, animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func updateFooter() {
        for (i, dot) in dots.arrangedSubviews.enumerated() {
            dot.layer?.backgroundColor = (i == step.rawValue ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
        }
        back.isHidden = step == .welcome || accessOnly
        dots.isHidden = accessOnly
        dots.arrangedSubviews[Step.sort.rawValue].isHidden = !offersSort
        notNow.isHidden = step != .sort
        switch step {
        case .welcome: next.title = "Get Started"; next.isEnabled = true
        case .access: next.title = accessOnly ? "Done" : "Continue"; next.isEnabled = AXIsProcessTrusted()
        case .practice: next.title = practiced.count == practiceRows.count ? "Continue" : "Skip for Now"; next.isEnabled = true
        case .finish: next.title = offersSort ? "Continue" : "Start Using Lunchbox"; next.isEnabled = true
        case .sort: next.title = "Organize My Windows"; next.isEnabled = true
        }
    }

    @objc private func goNext() {
        if step == .finish {
            // Asked only if it still helps: windows may have closed meanwhile.
            offersSort = sortPreview?() != nil
        }
        if accessOnly || (step == .finish && !offersSort) {
            finish()
        } else if step == .sort {
            onSort?()
            finish()
        } else if let following = Step(rawValue: step.rawValue + 1) {
            go(to: following)
        } else {
            finish()
        }
    }

    private func finish() {
        trustTimer?.invalidate()
        accessOnly = false
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        window?.orderOut(nil)
        onClose?()
    }

    @objc private func declineSort() { finish() }

    @objc private func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) { go(to: previous) }
    }

    func windowWillClose(_ notification: Notification) {
        // Closed once Accessibility is on: set up enough not to come back at every launch.
        // (The menu's Welcome… opens it again.)
        if AXIsProcessTrusted() { UserDefaults.standard.set(true, forKey: "onboardingDone") }
        tap.learnNextKey(nil)
        trustTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    // MARK: Welcome

    private func welcomeView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true
        return page(top: icon,
                    title: "Welcome to LunchboxWM",
                    body: "Every window, right where it belongs. In about a minute Lunchbox will be tiling your windows, and you'll know the few keys that matter. Every one can be changed, and Vim keys are one click away.")
    }

    // MARK: Accessibility

    private func accessView() -> NSView {
        let status = StatusPill()
        let open = NSButton(title: "Open System Settings", target: self, action: #selector(requestAccess))
        open.bezelStyle = .rounded
        open.controlSize = .large
        // macOS keeps a switch that's on for an older copy of the app (after an update from another
        // developer certificate, or a reinstall) but no longer works for this one: after a while,
        // say how to clear it.
        let stale = NSTextField(wrappingLabelWithString: "Already switched on? macOS can keep an old switch that no longer works after an update or a reinstall. In the list, select LunchboxWM, click −, then turn it on again.")
        stale.font = .systemFont(ofSize: 12)
        stale.textColor = .secondaryLabelColor
        stale.alignment = .center
        stale.preferredMaxLayoutWidth = 440
        stale.isHidden = true
        let row = NSStackView(views: [status, open, stale])
        row.orientation = .vertical
        row.spacing = 16
        let shown = Date()
        var finishing = false
        let refresh = { [weak self] in
            let granted = AXIsProcessTrusted()
            status.set(granted ? "Access granted" : "Waiting for access…", done: granted)
            open.isHidden = granted
            stale.isHidden = granted || Date().timeIntervalSince(shown) < 8
            if self?.step == .access { self?.next.isEnabled = granted }
            // Only access was missing: once it's back, there's nothing else to do here.
            if granted, self?.accessOnly == true, !finishing {
                finishing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self?.finish() }
            }
        }
        refresh()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in refresh() }
        return page(top: symbol("hand.raised.fingers.spread.fill"),
                    title: "Let Lunchbox move your windows",
                    body: "macOS asks you to allow LunchboxWM under Privacy & Security › Accessibility. That's how it arranges windows and hears its shortcuts. It never records what you type.",
                    content: row)
    }

    @objc private func requestAccess() { onRequestAccess?() }

    // MARK: Practice

    private func practiceView() -> NSView {
        practiceRows = [:]
        let keymap = tap.keymap
        let keys = tap.spaceKeys
        let caps = { (c: Command) in Keymap.keycaps(for: keymap.binding(for: c), workspaceKeys: keys) }
        // All four arrows, when the four directions share their modifiers: any direction works.
        let anyDirection = { (dirs: [Command]) -> [String] in
            let all = dirs.map(caps)
            let mods = all[0].dropLast()
            guard all.allSatisfy({ $0.dropLast() == mods }) else { return all[1] }
            let lasts = Set(all.compactMap(\.last))
            if lasts == ["←", "→", "↑", "↓"] { return Array(mods) + ["arrows"] }
            if lasts == ["H", "J", "K", "L"] { return Array(mods) + ["H", "J", "K", "L"] }
            return all[1]
        }
        // ⌘ and each Workspace's number: going between all of them.
        let betweenWorkspaces: [String] = {
            let all = (0..<tiler.spaceCount).map { caps(.goTo($0)) }
            let mods = all[0].dropLast()
            guard all.allSatisfy({ $0.dropLast() == mods }) else { return caps(.goTo(1)) }
            // "/" is the slash between keys to pick one of.
            return Array(mods) + all.compactMap(\.last).flatMap { [$0, "/"] }.dropLast()
        }()
        // More or less space: ⌘⇧ + / −, when grow and shrink share their modifiers.
        let growOrShrink: [String] = {
            let grow = caps(.grow), shrink = caps(.shrink)
            guard let g = grow.last, let s = shrink.last, grow.dropLast() == shrink.dropLast() else { return grow }
            return Array(grow.dropLast()) + [g, "/", s]
        }()
        let items: [(String, [String], String)] = [
            // Summon first: it's how every window gets opened in the first place.
            ("summon", caps(.summon), "Open an app with Summon (type, then ↩)"),
            ("focus", anyDirection([.focusLeft, .focusRight, .focusUp, .focusDown]), "Move focus in any direction"),
            ("move", anyDirection([.moveLeft, .moveRight, .moveUp, .moveDown]), "Move a window any way"),
            ("size", growOrShrink, "Give a window more or less space"),
            ("resize", caps(.resize), "Resize, then push an edge with \(keymap.preset == .vim ? "H J K L" : "the arrows")"),
            ("focusMode", caps(.focusMode), "Focus on one window, then again to undo"),
            ("tidy", caps(.tidy), "Tidy everything back to even"),
            ("close", caps(.close), "Close a window (Reset brings it back)"),
            ("space", betweenWorkspaces, "Go between Workspaces"),
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
        text.preferredMaxLayoutWidth = 400
        // Arrow keys or Vim keys, right here; and every shortcut can be changed later.
        let presets = NSSegmentedControl(labels: Keymap.Preset.allCases.map(\.title), trackingMode: .selectOne,
                                         target: self, action: #selector(pickPreset(_:)))
        presets.selectedSegment = keymap.preset.flatMap { Keymap.Preset.allCases.firstIndex(of: $0) } ?? -1
        let presetLabel = NSTextField(labelWithString: "Move around with")
        presetLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let presetRow = NSStackView(views: [presetLabel, presets])
        presetRow.spacing = 10
        let changeLater = NSTextField(wrappingLabelWithString: "Every shortcut can be changed to keys you like: menu bar icon › Settings › Keyboard Shortcuts.")
        changeLater.font = .systemFont(ofSize: 12)
        changeLater.textColor = .secondaryLabelColor
        changeLater.preferredMaxLayoutWidth = 400
        let right = NSStackView(views: [heading, text, presetRow, changeLater, list])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 14
        right.setCustomSpacing(16, after: text)
        right.setCustomSpacing(6, after: presetRow)
        right.setCustomSpacing(22, after: changeLater)
        right.translatesAutoresizingMaskIntoConstraints = false
        right.widthAnchor.constraint(equalToConstant: 420).isActive = true
        for row in rows { row.widthAnchor.constraint(equalToConstant: 420).isActive = true }

        let layout = NSStackView(views: [left, right])
        layout.orientation = .horizontal
        layout.alignment = .top
        layout.spacing = 32
        return layout
    }

    @objc private func resetPlayground() { playground?.reset() }

    @objc private func pickPreset(_ sender: NSSegmentedControl) {
        guard Keymap.Preset.allCases.indices.contains(sender.selectedSegment) else { return }
        onKeymapChange?(tap.keymap.applying(Keymap.Preset.allCases[sender.selectedSegment]))
        // The list shows the new keys.
        go(to: .practice, animated: false)
    }

    // MARK: Finish

    private func finishView() -> NSView {
        let login = toggleRow("Open Lunchbox when you log in", on: LoginItem.isEnabled) { on in LoginItem.set(on) }
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
                    body: "Change these any time from Lunchbox's menu bar icon. Every shortcut can be changed to keys you like, and Left ⌘⇧Space shows them all whenever you forget one.",
                    content: list)
    }

    @objc private func customizeShortcuts() { onCustomize?() }

    @objc private func allowPreviews() {
        DispatchQueue.global(qos: .utility).async { _ = CGRequestScreenCaptureAccess() }
        previewStatus.stringValue = "Turn on LunchboxWM in System Settings, then reopen Lunchbox"
    }

    // MARK: Sorting the open windows

    private func sortView() -> NSView {
        guard let (plan, icons) = sortPreview?() else {
            return page(top: symbol("checkmark.circle"), title: "Your windows are in order",
                        body: "There's nothing worth sorting right now. Whenever things pile up, Sort My Windows in Lunchbox's menu sorts them into Workspaces by kind.")
        }
        let total = plan.workspaces.reduce(plan.hidden.count) { $0 + $1.windows.count }
        let n = plan.workspaces.count
        let into = n == 1 ? "one Workspace" : "\(n) Workspaces"
        let cards = plan.workspaces.enumerated().map { i, w in
            WorkspacePreview(number: i + 1, title: w.title, accent: SortShow.accent(for: w.groups.first ?? .work),
                             icons: w.windows.compactMap { icons[$0] }, windows: w.windows.count)
        }
        let row = NSStackView(views: cards)
        row.spacing = 12
        row.alignment = .top
        var views: [NSView] = [row]
        if canTile?() == false {
            let note = NSTextField(wrappingLabelWithString: "It happens as soon as Lunchbox is activated.")
            note.font = .systemFont(ofSize: 12)
            note.textColor = .secondaryLabelColor
            note.alignment = .center
            views.append(note)
        }
        // Or a clean desk: every window closed, as if by its red button.
        let freshNote = NSTextField(labelWithString: "Rather begin with a clean desk?")
        freshNote.font = .systemFont(ofSize: 13)
        freshNote.textColor = .secondaryLabelColor
        let fresh = NSButton(title: "Start Fresh…", target: self, action: #selector(startFresh))
        fresh.bezelStyle = .rounded
        let freshRow = NSStackView(views: [freshNote, fresh])
        freshRow.spacing = 10
        views.append(freshRow)
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.spacing = 14
        content.setCustomSpacing(22, after: views[views.count - 2])
        let summon = Keymap.keycaps(for: tap.keymap.binding(for: .summon), workspaceKeys: tap.spaceKeys).joined(separator: " ")
        let shown = total - plan.hidden.count
        let body = plan.hidden.isEmpty
            ? "You have \(total) windows open. Lunchbox can sort them by kind into \(into), so each one starts out calm, and show you where everything went. Nothing closes, and Undo puts it all back."
            : "You have \(total) windows open. Lunchbox can sort the \(shown) you've used most recently by kind into \(into), and show you where everything went. The other \(plan.hidden.count) stay open, out of the way: Summon (\(summon)) finds any of them. Nothing closes, and Undo puts it all back."
        return page(top: symbol("rectangle.3.group"), title: "Organize your open windows?", body: body, content: content)
    }

    /// Start Fresh…: how many windows it would close, and a last word before it does.
    @objc private func startFresh() {
        StartFresh.windows { [weak self] found in
            guard let self, let window = self.window, self.step == .sort, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.icon = NSApp.applicationIconImage
            guard !found.isEmpty else {
                alert.messageText = "There are no windows to close"
                alert.informativeText = "Your desk is already clear."
                alert.beginSheetModal(for: window)
                return
            }
            alert.messageText = found.count == 1 ? "Close the open window?" : "Close all \(found.count) open windows?"
            alert.informativeText = "Each one closes as if you clicked its red button, so apps still ask before closing anything unsaved. Browser windows close with all their tabs. This can't be undone."
            let close = alert.addButton(withTitle: found.count == 1 ? "Close Window" : "Close All Windows")
            close.hasDestructiveAction = true
            let cancel = alert.addButton(withTitle: "Cancel")
            // Return cancels: closing everything takes a click.
            close.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                self.finish()
                self.onStartFresh?(found)
            }
        }
    }

    #if DEBUG || LUNCHBOX_DEV
    /// For screenshots on a display nobody watches: Start Fresh's question, then Cancel.
    func showStartFreshQuestion() { startFresh() }
    func cancelSheet() {
        guard let window, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }
    #endif

    // MARK: Building blocks

    private func page(top: NSView, title: String, body: String, content: NSView? = nil) -> NSView {
        let heading = NSTextField(labelWithAttributedString: Brand.wordmark(title, font: .systemFont(ofSize: 30, weight: .semibold)))
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
        // The page on its way out stops holding the window to its size: it fades where it is, so the
        // window can take the new page's size (and stay centered) straight away. Otherwise the wide
        // practice page kept the next page's window wide and off center.
        for page in old {
            let frame = page.frame
            stage.removeConstraints(stage.constraints.filter { $0.firstItem === page || $0.secondItem === page })
            page.translatesAutoresizingMaskIntoConstraints = true
            page.frame = frame
        }
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
        window.title = "Welcome to LunchboxWM"

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
        notNow.target = self
        notNow.action = #selector(declineSort)
        notNow.bezelStyle = .rounded
        notNow.controlSize = .large
        notNow.isHidden = true
        // Hidden buttons drop out of the row.
        let buttons = NSStackView(views: [back, notNow, next])
        buttons.spacing = 10

        for v in [stage, dots, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
            stage.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 40),
            stage.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -40),
            stage.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -20),
            dots.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 32),
            dots.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
            buttons.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -26),
        ])
        window.contentView = background
        self.window = window
        return window
    }
}

/// One Workspace in the sort step's preview: its number and kind, the apps going there, and how
/// many windows.
private final class WorkspacePreview: NSView {
    private let accent: NSColor

    init(number: Int, title: String, accent: NSColor, icons: [NSImage], windows: Int) {
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 160).isActive = true

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = accent.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let caption = NSTextField(labelWithString: "Workspace \(number)")
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        let top = NSStackView(views: [dot, caption])
        top.spacing = 6
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Each app once, in the order its windows were used.
        var seen = Set<ObjectIdentifier>()
        let apps = icons.filter { seen.insert(ObjectIdentifier($0)).inserted }
        var badges: [NSView] = apps.prefix(5).map { icon in
            let view = NSImageView(image: icon)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 24).isActive = true
            view.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return view
        }
        if apps.count > 5 {
            let more = NSTextField(labelWithString: "+\(apps.count - 5)")
            more.font = .systemFont(ofSize: 11, weight: .medium)
            more.textColor = .secondaryLabelColor
            badges.append(more)
        }
        let iconRow = NSStackView(views: badges)
        iconRow.spacing = 3
        let count = NSTextField(labelWithString: windows == 1 ? "1 window" : "\(windows) windows")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        let column = NSStackView(views: [top, name, iconRow, count])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
            layer?.borderColor = accent.withAlphaComponent(0.45).cgColor
        }
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
            switch k {
            case "then": return NSTextField(labelWithString: "then") as NSView
            case "arrows": return ArrowCluster()
            case "/":
                let slash = NSTextField(labelWithString: "/")
                slash.textColor = .secondaryLabelColor
                slash.font = .systemFont(ofSize: 13, weight: .semibold)
                return slash
            default: return Keycap(text: k)
            }
        })
        caps.spacing = 4
        // Every row's keys sit in the same width, so the descriptions line up.
        caps.translatesAutoresizingMaskIntoConstraints = false
        let capsBox = NSView()
        capsBox.translatesAutoresizingMaskIntoConstraints = false
        capsBox.addSubview(caps)
        NSLayoutConstraint.activate([
            capsBox.widthAnchor.constraint(equalToConstant: 212),
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

/// The four arrow keys in their keyboard shape (↑ over ← ↓ →), small enough to
/// sit beside other keycaps: "any direction works".
private final class ArrowCluster: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let w: CGFloat = 19, h: CGFloat = 14, gap: CGFloat = 2
        let spots: [(String, CGFloat, CGFloat)] = [("↑", w + gap, 0), ("←", 0, h + gap), ("↓", w + gap, h + gap), ("→", 2 * (w + gap), h + gap)]
        for (arrow, x, y) in spots {
            let key = MiniKey(arrow)
            key.frame = NSRect(x: x, y: y, width: w, height: h)
            addSubview(key)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 3 * w + 2 * gap),
            heightAnchor.constraint(equalToConstant: 2 * h + gap),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private final class MiniKey: NSView {
        private let label: NSTextField

        init(_ text: String) {
            label = NSTextField(labelWithString: text)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 3
            layer?.borderWidth = 1
            label.font = .systemFont(ofSize: 9, weight: .bold)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            updateColors()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }

        private func updateColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                label.textColor = .secondaryLabelColor
                layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            }
        }
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
