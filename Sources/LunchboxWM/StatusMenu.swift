import AppKit
import ServiceManagement
import LunchboxCore

/// The menu bar item: the current space number, plus a menu.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tiler: Tiler
    var trusted = false
    var onToggle: (() -> Void)?
    var onGrantAccess: (() -> Void)?
    var onShowHelp: (() -> Void)?
    var onShowWelcome: (() -> Void)?
    var onShowShortcuts: (() -> Void)?
    var onEnterLicense: (() -> Void)?
    var onBuy: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var updater: Updater? { didSet { refresh() } }
    /// The orange dot on the icon while an update is out (`Updater.available`).
    private let updateDot: NSView = {
        let dot = NSView(frame: MenuBarGlyph.badge)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.layer?.cornerRadius = MenuBarGlyph.badge.width / 2
        dot.isHidden = true
        return dot
    }()
    var onCopyDiagnostics: (() -> Void)?
    var onSort: (() -> Void)?
    var onUndoSort: (() -> Void)?
    /// The sort show is playing.
    var sorting: (() -> Bool)?
    var licensing: Licensing?

    init(tiler: Tiler) {
        self.tiler = tiler
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        guard let button = item.button else { return }
        let update = updater?.available
        button.image = MenuBarGlyph.image(paused: !tiler.enabled, badge: update != nil)
        button.imagePosition = .imageLeading
        button.title = tiler.enabled ? " \(tiler.currentSpace + 1)" : ""
        button.toolTip = update.map { "Lunchbox \($0) is available. Choose Update in the menu to download it." }
        if updateDot.superview !== button { button.addSubview(updateDot) }
        updateDot.isHidden = update == nil
        guard update != nil, let cell = button.cell else { return }
        // Over the gap cut in the glyph, wherever the button draws it.
        button.layoutSubtreeIfNeeded()
        let glyph = cell.imageRect(forBounds: button.bounds)
        let dot = MenuBarGlyph.badge
        let y = button.isFlipped ? glyph.minY + dot.minY : glyph.maxY - dot.maxY
        updateDot.frame = NSRect(x: glyph.minX + dot.minX, y: y, width: dot.width, height: dot.height)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Which version this is, first thing, in full strength (a click copies it, for support).
        menu.addItem(versionLine())
        menu.addItem(.separator())
        // Without a license nothing tiles, so the tiling and window items would do nothing: the
        // menu offers the license instead, plus help, settings and Quit.
        let unlicensed = licensing.map { $0.license == nil } ?? false
        if !trusted {
            menu.addItem(disabled: "Lunchbox needs Accessibility access to move windows.")
            menu.addItem(action("Allow Accessibility Access…") { [weak self] in self?.onGrantAccess?() })
            menu.addItem(.separator())
        }
        if unlicensed {
            menu.addItem(disabled: "Not licensed: tiling is off")
            menu.addItem(action("Buy Lunchbox – $4.99…") { [weak self] in self?.onBuy?() })
            menu.addItem(action("Enter License…") { [weak self] in self?.onEnterLicense?() })
            menu.addItem(.separator())
        } else if trusted {
            menu.addItem(action("Tiling", checked: tiler.enabled) { [weak self] in self?.onToggle?() })
            menu.addItem(.separator())
            for i in 0..<tiler.spaceCount {
                let entry = action("Workspace \(i + 1)", checked: tiler.enabled && tiler.currentSpace == i) { [weak self] in
                    self?.tiler.switchSpace(to: i, focusing: nil)
                }
                entry.isEnabled = tiler.enabled
                menu.addItem(entry)
            }
            let count = tiler.spaceCount
            if count < Command.maxWorkspaces {
                let add = action("Add a Workspace") { [weak self] in self?.tiler.setSpaceCount(count + 1) }
                add.toolTip = "Workspace \(count + 1) gets ⌘\(count + 1)."
                add.isEnabled = tiler.enabled
                menu.addItem(add)
            }
            if count > Command.defaultWorkspaces {
                let remove = action("Remove Workspace \(count)") { [weak self] in self?.tiler.setSpaceCount(count - 1) }
                remove.toolTip = "Its windows move to Workspace \(count - 1)."
                remove.isEnabled = tiler.enabled
                menu.addItem(remove)
            }
            menu.addItem(.separator())
            let inFocus = tiler.focusModeIsOn
            let focus = action(inFocus ? "End Focus" : "Focus on This Window") { [weak self] in
                guard let self else { return }
                if self.tiler.focusModeIsOn { self.tiler.exitSpotlight() } else { self.tiler.perform(.spotlight) }
            }
            focus.isEnabled = tiler.enabled && (inFocus || tiler.focusedID != nil)
            menu.addItem(focus)
            let floats = tiler.focusedFloats
            let float = action(floats == true ? "Tile This Window" : "Float This Window") { [weak self] in self?.tiler.toggleFloating() }
            float.toolTip = "Takes the window out of the tiles to float where you put it, or puts it back."
            float.isEnabled = tiler.enabled && floats != nil
            menu.addItem(float)
            let even = action("Tidy This Workspace") { [weak self] in self?.tiler.normalize() }
            even.isEnabled = tiler.enabled
            menu.addItem(even)
            let retile = action("Re-tile All Windows") { [weak self] in self?.tiler.retile() }
            retile.isEnabled = tiler.enabled
            menu.addItem(retile)
            let sort = action("Sort My Windows") { [weak self] in self?.onSort?() }
            sort.toolTip = "Sorts every open window into Workspaces by kind: your work, the web, chat and music. Only as many Workspaces as it takes, and Undo puts it all back."
            sort.isEnabled = tiler.enabled && !(sorting?() ?? false)
            menu.addItem(sort)
            if tiler.canUndoSort {
                menu.addItem(action("Undo Sort") { [weak self] in self?.onUndoSort?() })
            }
            menu.addItem(.separator())
        }

        // The time Lunchbox gave back this week, once there's any. How it's counted is in its tooltip.
        let week = TimeBackLedger.shared.week
        if trusted, !unlicensed, !week.isEmpty {
            let line = NSMenuItem(title: TimeBackWords.menuLine(week), action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = Self.howCounted(week)
            menu.addItem(line)
            menu.addItem(.separator())
        }
        let shortcuts = action("Cheat Sheet…") { [weak self] in self?.onShowHelp?() }
        shortcuts.toolTip = "Left ⌘⇧Space shows this anywhere"
        menu.addItem(shortcuts)
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let options = NSMenu()
        let displays = action("Use All Displays", checked: tiler.useAllDisplays) { [weak self] in
            guard let self else { return }
            self.tiler.setUseAllDisplays(!self.tiler.useAllDisplays)
        }
        displays.toolTip = "Turn off to tile only on the main display, for example when the other display is a dummy plug."
        options.addItem(displays)
        let login = action("Launch at Login", checked: LoginItem.isEnabled) { LoginItem.set(!LoginItem.isEnabled) }
        login.toolTip = "Also brings Lunchbox back by itself if it ever quits unexpectedly."
        options.addItem(login)
        options.addItem(action("Keyboard Shortcuts…") { [weak self] in self?.onShowShortcuts?() })
        options.addItem(action("Welcome & Setup…") { [weak self] in self?.onShowWelcome?() })
        let automatic = action("Check for Updates Automatically", checked: updater?.checksAutomatically ?? true) { [weak self] in
            guard let updater = self?.updater else { return }
            updater.checksAutomatically.toggle()
        }
        automatic.toolTip = "Looks for a new version about once an hour. Lunchbox always asks before installing one."
        options.addItem(automatic)
        let diagnostics = action("Copy Diagnostics") { [weak self] in self?.onCopyDiagnostics?() }
        diagnostics.toolTip = "Copies a summary for support to paste into an email: versions, displays, and which apps' windows are in each Workspace. No window titles, files or license key."
        options.addItem(diagnostics)
        if let license = licensing?.license {
            options.addItem(.separator())
            options.addItem(action("Licensed to \(license.email)…") { [weak self] in self?.onEnterLicense?() })
        }
        settings.submenu = options
        menu.addItem(settings)
        menu.addItem(.separator())
        let update = updater?.available.map { "Update to Lunchbox \($0)…" } ?? "Check for Updates…"
        menu.addItem(action(update) { [weak self] in self?.onCheckForUpdates?() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lunchbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// The working behind this week's number, for a tooltip.
    private static func howCounted(_ week: TimeBack.Tally) -> String {
        let rows = TimeBackWords.breakdown(week)
        return (TimeBackWords.howCounted + (rows.isEmpty ? [] : ["", "This week:"] + rows)
            + ["", "Counted on this Mac only."]).joined(separator: "\n")
    }

    /// "Lunchbox 1.3" in bold, the same on every build (the build number is in its tooltip).
    /// Clicking it copies the version, which also keeps it from being drawn dimmed like a note.
    private func versionLine() -> NSMenuItem {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let entry = action("") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Lunchbox \(version) (build \(build))", forType: .string)
        }
        entry.attributedTitle = NSAttributedString(string: "Lunchbox \(version)",
                                                   attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        entry.toolTip = "Version \(version) (build \(build)). Click to copy it."
        return entry
    }

    /// A small grey note in a menu.
    private static func footnote(_ text: String, toolTip: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        entry.isEnabled = false
        entry.toolTip = toolTip
        return entry
    }

    private func action(_ title: String, checked: Bool = false, _ body: @escaping () -> Void) -> NSMenuItem {
        let entry = ClosureMenuItem(title: title, body: body)
        entry.state = checked ? .on : .off
        return entry
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let body: () -> Void

    init(title: String, body: @escaping () -> Void) {
        self.body = body
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { body() }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        addItem(entry)
    }
}
