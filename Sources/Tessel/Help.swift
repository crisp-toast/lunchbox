import AppKit
import TesselCore

/// Every shortcut Tessel has, grouped, for the help panel.
struct ShortcutGuide {
    struct Entry {
        let keys: [String]
        let action: String
        let group: String

        func matches(_ words: [String]) -> Bool {
            let haystack = (keys.joined(separator: " ") + " " + action + " " + group).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func entries(spaceKeys: [Int64]) -> [Entry] {
        let k = (0..<3).map { i in spaceKeys.indices.contains(i) ? keyName(spaceKeys[i]) : "Space key \(i + 1)" }
        let all: [(String, [([String], String)])] = [
            ("Windows", [
                (["Left ⌘", "← → ↑ ↓"], "Focus the next window in that direction"),
                (["Left ⌘ ⇧", "← →"], "Move the window sideways: it stacks with its neighbor, then passes it"),
                (["Left ⌘ ⇧", "↑ ↓"], "Swap the window with the one above or below"),
                (["Left ⌘ ⇧", "+"], "Give the window more space"),
                (["Left ⌘ ⇧", "−"], "Give the window less space"),
                (["Left ⌘ ⇧", "F"], "Spotlight: this window centered, the rest on a shelf (again to undo)"),
                (["Esc"], "Leave spotlight (new Finder windows open in spotlight)"),
                (["Left ⌘ ⇧", "0"], "Normalize: even out every window in this space (a centered window goes back to its default size)"),
                (["Left ⌘ ⇧", "Delete"], "Close the window"),
            ]),
            ("Spaces", [
                (["⌘", k[0]], "Go to space 1"),
                (["⌘", k[1]], "Go to space 2"),
                (["⌘", k[2]], "Go to space 3"),
                (["⌘ ⇧", k[0]], "Move the window to space 1 and go with it"),
                (["⌘ ⇧", k[1]], "Move the window to space 2 and go with it"),
                (["⌘ ⇧", k[2]], "Move the window to space 3 and go with it"),
                (["Left ⌘ ⇧", "H"], "Hide the window in space 3 and stay here"),
            ]),
            ("Launcher", [
                (["⇧", "Space"], "Open the launcher: apps first, then files and folders"),
                (["↩"], "Open the app, or go to its window if it has one"),
                (["⌘", "↩"], "Open a new window of an app that's already open"),
                (["↑ ↓"], "Choose a result"),
                (["Esc"], "Close the launcher"),
            ]),
            ("Mouse", [
                (["Drag"], "Drop a window onto another to swap them"),
                (["Drag edge"], "Resize a window; its neighbors make room. A centered window keeps any shape and stays centered"),
                (["Click"], "Click a card on the spotlight shelf to bring everything back"),
            ]),
            ("Help", [
                (["Left ⌘ ⇧", "Space"], "Show or hide this list"),
            ]),
        ]
        return all.flatMap { group, rows in rows.map { Entry(keys: $0.0, action: $0.1, group: group) } }
    }

    static func keyName(_ code: Int64) -> String {
        let names: [Int64: String] = [
            116: "Page Up", 121: "Page Down", 119: "End", 115: "Home", 117: "Del", 114: "Help",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        ]
        return names[code] ?? "Key \(code)"
    }
}

/// Left ⌘⇧Space: every shortcut, grouped, with a search box.
final class HelpPanel: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private var panel: LauncherPanel?
    private let field = NSTextField()
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "No shortcut matches that.")
    private var entries: [ShortcutGuide.Entry] = []
    private let spaceKeys: () -> [Int64]

    private static let size = NSSize(width: 600, height: 640)

    init(spaceKeys: @escaping () -> [Int64]) {
        self.spaceKeys = spaceKeys
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show(query: String = "") {
        entries = ShortcutGuide.entries(spaceKeys: spaceKeys())
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
        ["visible": isVisible, "query": field.stringValue,
         "shown": list.arrangedSubviews.compactMap { ($0 as? HelpRow)?.summary }]
    }

    func controlTextDidChange(_ obj: Notification) { render() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; render() }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let words = field.stringValue.lowercased().split(separator: " ").map(String.init)
        let shown = entries.filter { $0.matches(words) }
        var group = ""
        for entry in shown {
            if entry.group != group {
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
            list.addArrangedSubview(HelpRow(entry: entry))
        }
        empty.isHidden = !shown.isEmpty
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

        let title = NSTextField(labelWithString: "Tessel Shortcuts")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = "Search shortcuts (try \"space\" or \"move\")"
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

        empty.font = .systemFont(ofSize: 14)
        empty.textColor = .secondaryLabelColor
        empty.isHidden = true

        let divider = NSBox()
        divider.boxType = .separator
        for v in [title, glass, field, divider, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
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
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
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
            empty.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            empty.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 40),
        ])
        panel.contentView = background
        self.panel = panel
        return panel
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class HelpRow: NSView {
    let summary: String

    init(entry: ShortcutGuide.Entry) {
        summary = entry.keys.joined(separator: " + ") + ": " + entry.action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let keys = NSStackView(views: entry.keys.map { Keycap(text: $0) })
        keys.orientation = .horizontal
        keys.spacing = 4
        let action = NSTextField(wrappingLabelWithString: entry.action)
        action.font = .systemFont(ofSize: 13)
        action.textColor = .labelColor
        for v in [keys, action] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 540),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor),
            keys.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            action.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 190),
            action.trailingAnchor.constraint(equalTo: trailingAnchor),
            action.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            bottomAnchor.constraint(greaterThanOrEqualTo: action.bottomAnchor, constant: 6),
            bottomAnchor.constraint(greaterThanOrEqualTo: keys.bottomAnchor, constant: 5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
