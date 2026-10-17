import AppKit
import TesselCore

/// Everything the Cheat Sheet lists: every command with its current keys, plus
/// the few things that aren't commands (Summon's own keys, the mouse).
enum CheatSheetContent {
    static let groupOrder = ["Windows", "Workspaces", "Summon", "Mouse", "Cheat Sheet"]

    /// Only the Workspaces there are: with three, ⌘4 isn't Tessel's.
    static func entries(keymap: Keymap, workspaceKeys: [Int64],
                        spaces: Int = Tiler.shared?.spaceCount ?? Command.defaultWorkspaces) -> [CheatEntry] {
        var all = Command.allCases.filter { $0.isActive(spaces: spaces) }.map { c in
            CheatEntry(id: c.rawValue, keys: Keymap.keycaps(for: keymap.binding(for: c), workspaceKeys: workspaceKeys),
                       title: c.title, group: c.group, keywords: c.keywords)
        }
        all += [
            CheatEntry(id: "summon.go", keys: ["↩"], title: "In Summon: open the app, or go to its window", group: "Summon",
                       keywords: ["return", "enter", "open", "go to", "existing window", "launch", "select"]),
            CheatEntry(id: "summon.new", keys: ["⇧", "↩"], title: "In Summon: open a new window of an app that's already open", group: "Summon",
                       keywords: ["new window", "another window", "second window", "shift return", "shift enter", "duplicate", "fresh window"]),
            CheatEntry(id: "summon.choose", keys: ["↑ ↓"], title: "In Summon: choose a result", group: "Summon",
                       keywords: ["arrow", "select", "pick", "next result", "previous result", "navigate"]),
            CheatEntry(id: "summon.close", keys: ["Esc"], title: "In Summon or the Cheat Sheet: close it", group: "Summon",
                       keywords: ["escape", "close", "dismiss", "cancel", "hide", "exit"]),
            CheatEntry(id: "mouse.swap", keys: ["Drag"], title: "Drop a window onto another to swap them", group: "Mouse",
                       keywords: ["mouse", "drag", "drop", "swap", "rearrange", "trackpad", "click"]),
            CheatEntry(id: "mouse.resize", keys: ["Drag edge"], title: "Resize a window; neighbors make room, a centered window keeps its shape",
                       group: "Mouse", keywords: ["mouse", "resize", "edge", "size", "stretch", "corner", "trackpad"]),
            CheatEntry(id: "mouse.shelf", keys: ["Click"], title: "Click a card on the Shelf to leave Focus with that window", group: "Mouse",
                       keywords: ["mouse", "click", "shelf", "card", "focus", "restore", "exit focus", "leave focus"]),
        ]
        // Stable: by group, then in the order listed.
        return all.enumerated().sorted {
            let a = groupOrder.firstIndex(of: $0.element.group) ?? 9, b = groupOrder.firstIndex(of: $1.element.group) ?? 9
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }
}

/// Left ⌘⇧Space: every shortcut, grouped, with a search box that forgives.
final class HelpPanel: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private var panel: LauncherPanel?
    private let field = NSTextField()
    private let list = NSStackView()
    private let note = NSTextField(labelWithString: "")
    private var entries: [CheatEntry] = []
    private let source: () -> (Keymap, [Int64])
    var onCustomize: (() -> Void)?

    private static let size = NSSize(width: 620, height: 660)

    init(source: @escaping () -> (Keymap, [Int64])) {
        self.source = source
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show(query: String = "") {
        let (keymap, keys) = source()
        entries = CheatSheetContent.entries(keymap: keymap, workspaceKeys: keys)
        let panel = self.panel ?? makePanel()
        field.stringValue = query
        render()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - Self.size.width / 2, y: area.midY - Self.size.height / 2,
                              width: Self.size.width, height: Self.size.height), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() { panel?.orderOut(nil) }

    var stateDescription: [String: Any] {
        ["visible": isVisible, "query": field.stringValue, "note": note.stringValue,
         "shown": list.arrangedSubviews.compactMap { ($0 as? HelpRow)?.summary }]
    }

    func controlTextDidChange(_ obj: Notification) { render() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; render() }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    @objc private func customize() {
        hide()
        onCustomize?()
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let result = CheatSheetSearch.search(field.stringValue, in: entries)
        note.stringValue = result.closest ? "No exact match. These are the closest:" : ""
        note.isHidden = !result.closest
        if result.entries.isEmpty {
            note.stringValue = "Nothing matches that. Try a word like \"move\", \"workspace\" or \"bigger\"."
            note.isHidden = false
        }
        // Search results keep their ranking; the full list is grouped.
        let grouped = field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        var group = ""
        for entry in result.entries {
            if grouped, entry.group != group {
                group = entry.group
                let header = NSTextField(labelWithString: group.uppercased())
                header.font = .systemFont(ofSize: 11, weight: .semibold)
                header.textColor = .secondaryLabelColor
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: list.arrangedSubviews.isEmpty ? 2 : 12).isActive = true
                list.addArrangedSubview(spacer)
                list.addArrangedSubview(header)
            }
            list.addArrangedSubview(HelpRow(entry: entry, showGroup: !grouped))
        }
    }

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor

        let title = NSTextField(labelWithString: "Tessel Cheat Sheet")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let customize = NSButton(title: "Customize…", target: self, action: #selector(customize))
        customize.bezelStyle = .inline
        customize.toolTip = "Change any shortcut, or restore the defaults"

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = "Search, like \"hide\", \"bigger\" or \"desktop 2\""
        field.delegate = self

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document

        note.font = .systemFont(ofSize: 12, weight: .medium)
        note.textColor = .secondaryLabelColor
        note.isHidden = true

        let divider = NSBox()
        divider.boxType = .separator
        for v in [title, customize, glass, field, divider, note, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            customize.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            customize.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            glass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 18),
            glass.heightAnchor.constraint(equalToConstant: 18),
            field.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            note.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])
        panel.contentView = background
        self.panel = panel
        return panel
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class HelpRow: NSView {
    let summary: String

    init(entry: CheatEntry, showGroup: Bool) {
        summary = entry.keys.joined(separator: " + ") + ": " + entry.title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let keys = NSStackView(views: entry.keys.map { k in
            k == "then" ? NSTextField(labelWithString: "then") as NSView : Keycap(text: k)
        })
        keys.orientation = .horizontal
        keys.spacing = 4
        let action = NSTextField(wrappingLabelWithString: entry.title)
        action.font = .systemFont(ofSize: 13)
        action.textColor = .labelColor
        var views: [NSView] = [keys, action]
        let group = NSTextField(labelWithString: entry.group)
        if showGroup {
            group.font = .systemFont(ofSize: 11)
            group.textColor = .tertiaryLabelColor
            views.append(group)
        }
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 560),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor),
            keys.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            action.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 200),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: showGroup ? -76 : 0),
            action.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            bottomAnchor.constraint(greaterThanOrEqualTo: action.bottomAnchor, constant: 6),
            bottomAnchor.constraint(greaterThanOrEqualTo: keys.bottomAnchor, constant: 5),
        ])
        if showGroup {
            NSLayoutConstraint.activate([
                group.trailingAnchor.constraint(equalTo: trailingAnchor),
                group.centerYAnchor.constraint(equalTo: action.centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
