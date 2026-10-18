import AppKit
import TesselCore

/// Settings › Keyboard Shortcuts: every command with its keys. Click the keys to
/// record new ones; reset one, or restore every default; show the defaults
/// next to your own.
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    private let tap: HotkeyTap
    var onChange: ((Keymap) -> Void)?

    private var window: NSWindow?
    private let list = NSStackView()
    private let message = NSTextField(labelWithString: "")
    private let showDefaultsBox = NSButton(checkboxWithTitle: "Show defaults", target: nil, action: nil)
    private var recording: Command?

    init(tap: HotkeyTap) {
        self.tap = tap
    }

    func show() {
        let window = self.window ?? makeWindow()
        render()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { stopRecording() }

    // MARK: Recording

    @objc private func record(_ sender: NSButton) {
        guard let command = Command(rawValue: sender.identifier?.rawValue ?? "") else { return }
        stopRecording()
        recording = command
        say("Press the new shortcut for “\(command.title)”. Esc cancels.")
        render()
        tap.learnNextKey { [weak self] code, flags in self?.recorded(code, flags) }
    }

    private func stopRecording() {
        tap.learnNextKey(nil)
        recording = nil
    }

    private func recorded(_ code: Int64, _ flags: CGEventFlags) {
        guard let command = recording else { return }
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if code == 53, flags.intersection(modifiers).isEmpty {
            stopRecording()
            say("")
            render()
            return
        }
        let binding = KeyBinding(recording: code, flags: flags)
        if let problem = Self.typingProblem(binding, code: code) {
            say(problem)
            tap.learnNextKey { [weak self] code, flags in self?.recorded(code, flags) }
            return
        }
        var map = tap.keymap
        if let other = map.conflict(with: binding, excluding: command, workspaceKeys: tap.spaceKeys, spaces: tap.spaceCount) {
            say("That's already “\(other.title)”. Press a different shortcut, or change that one first.")
            tap.learnNextKey { [weak self] code, flags in self?.recorded(code, flags) }
            return
        }
        map.overrides[command] = binding == Keymap.defaults[command] ? nil : binding
        apply(map)
        stopRecording()
        say("Saved. \(Keymap.keycaps(for: binding, workspaceKeys: tap.spaceKeys).joined(separator: " ")) now \(command.title.lowercased()).")
        render()
    }

    /// Shortcuts that would get in the way of typing.
    static func typingProblem(_ b: KeyBinding, code: Int64) -> String? {
        let typingKey = code < 51 || code == 49 || (65...92).contains(code)
        if !b.command && !b.option && !b.control {
            if b.shift && code == 49 { return nil } // ⇧ then Space, like Summon
            if typingKey { return "Add ⌘, ⌥ or ⌃ so this doesn't get in the way of typing." }
        }
        return nil
    }

    // MARK: Changing

    @objc private func reset(_ sender: NSButton) {
        guard let command = Command(rawValue: sender.identifier?.rawValue ?? "") else { return }
        var map = tap.keymap
        map.overrides[command] = nil
        apply(map)
        say("“\(command.title)” is back to its default.")
        render()
    }

    @objc private func restoreAll() {
        apply(Keymap())
        say("Every shortcut is back to its default.")
        render()
    }

    @objc private func toggleDefaults() { render() }

    private func apply(_ map: Keymap) {
        tap.keymap = map
        onChange?(map)
    }

    private func say(_ text: String) { message.stringValue = text }

    // MARK: Drawing

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let map = tap.keymap
        let keys = tap.spaceKeys
        let showDefaults = showDefaultsBox.state == .on
        var group = ""
        for command in Command.allCases.filter({ $0.isActive(spaces: tap.spaceCount) }).sorted(by: { order($0) < order($1) }) {
            if command.group != group {
                group = command.group
                let header = NSTextField(labelWithString: group.uppercased())
                header.font = .systemFont(ofSize: 11, weight: .semibold)
                header.textColor = .secondaryLabelColor
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: list.arrangedSubviews.isEmpty ? 0 : 10).isActive = true
                list.addArrangedSubview(spacer)
                list.addArrangedSubview(header)
            }
            list.addArrangedSubview(row(for: command, map: map, keys: keys, showDefaults: showDefaults))
        }
    }

    private func order(_ c: Command) -> Int {
        (CheatSheetContent.groupOrder.firstIndex(of: c.group) ?? 9) * 100 + (Command.allCases.firstIndex(of: c) ?? 0)
    }

    private func row(for command: Command, map: Keymap, keys: [Int64], showDefaults: Bool) -> NSView {
        let title = NSTextField(wrappingLabelWithString: command.title)
        title.font = .systemFont(ofSize: 13)
        let isRecording = recording == command
        let caps = isRecording ? ["Press keys…"] : Keymap.keycaps(for: map.binding(for: command), workspaceKeys: keys)
        let button = NSButton(title: caps.joined(separator: "  "), target: self, action: #selector(record(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.toolTip = "Click, then press the new shortcut"
        if isRecording { button.contentTintColor = .controlAccentColor }
        var views: [NSView] = [title, NSView(), button]
        let custom = map.isCustom(command)
        if showDefaults || custom {
            let def = NSTextField(labelWithString: "Default: " + Keymap.keycaps(for: Keymap.defaults[command]!, workspaceKeys: keys).joined(separator: " "))
            def.font = .systemFont(ofSize: 11)
            def.textColor = custom ? .systemOrange : .tertiaryLabelColor
            views.insert(def, at: 2)
        }
        if custom {
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Reset to default")!,
                                 target: self, action: #selector(reset(_:)))
            reset.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            reset.bezelStyle = .inline
            reset.toolTip = "Back to the default"
            views.append(reset)
        }
        let row = NSStackView(views: views)
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 600).isActive = true
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        return row
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 660, height: 420)

        let intro = NSTextField(wrappingLabelWithString: "Click any shortcut and press new keys. Tessel won't let two commands share keys, or pick a combination that would get in the way of typing.")
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .controlAccentColor
        showDefaultsBox.target = self
        showDefaultsBox.action = #selector(toggleDefaults)
        let restore = NSButton(title: "Restore All Defaults", target: self, action: #selector(restoreAll))
        restore.bezelStyle = .rounded

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document

        let content = NSView()
        for v in [intro, message, scroll, showDefaultsBox, restore] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            message.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 8),
            message.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: restore.topAnchor, constant: -14),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            showDefaultsBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            showDefaultsBox.centerYAnchor.constraint(equalTo: restore.centerYAnchor),
            restore.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            restore.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        window.contentView = content
        self.window = window
        return window
    }
}
