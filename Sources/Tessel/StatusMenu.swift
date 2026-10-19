import AppKit
import ServiceManagement
import TesselCore

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
    var onShowWindowClasses: (() -> Void)?
    var onEnterLicense: (() -> Void)?
    var onBuy: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
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
        button.image = MenuBarGlyph.image(paused: !tiler.enabled)
        button.imagePosition = .imageLeading
        button.title = tiler.enabled ? " \(tiler.currentSpace + 1)" : ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !trusted {
            menu.addItem(disabled: "Tessel needs Accessibility access to move windows.")
            menu.addItem(action("Allow Accessibility Access…") { [weak self] in self?.onGrantAccess?() })
            menu.addItem(.separator())
        } else {
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
            if Learning.shared.isOn {
                let floats = tiler.focusedFloats
                let float = action(floats == true ? "Tile This Window" : "Float This Window") { [weak self] in self?.tiler.toggleFloating() }
                float.toolTip = "Tessel learns from this: the next window like it does the same."
                float.isEnabled = tiler.enabled && floats != nil
                menu.addItem(float)
            }
            let even = action("Tidy This Workspace") { [weak self] in self?.tiler.normalize() }
            even.isEnabled = tiler.enabled
            menu.addItem(even)
            let retile = action("Re-tile All Windows") { [weak self] in self?.tiler.retile() }
            retile.isEnabled = tiler.enabled
            menu.addItem(retile)
            menu.addItem(.separator())
        }

        // The time Tessel gave back this week, once there's any. How it's counted is in its
        // tooltip and in What Tessel Learned.
        let week = TimeBackLedger.shared.week
        let unlicensed = licensing.map { $0.license == nil } ?? false
        if trusted, !week.isEmpty {
            let line = NSMenuItem(title: TimeBackWords.menuLine(week), action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = Self.howCounted(week)
            menu.addItem(line)
            if !unlicensed { menu.addItem(.separator()) }
        }
        if let licensing, licensing.license == nil {
            switch licensing.trial {
            case .active(let days):
                let soFar = TimeBackLedger.shared.tally(since: licensing.trialStart ?? Date())
                menu.addItem(disabled: TimeBackWords.trialLine(daysLeft: days, soFar: soFar))
            case .ended: menu.addItem(disabled: "Free trial ended")
            }
            menu.addItem(action("Buy Tessel – $9.99…") { [weak self] in self?.onBuy?() })
            menu.addItem(action("Enter License…") { [weak self] in self?.onEnterLicense?() })
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
        login.toolTip = "Also brings Tessel back by itself if it ever quits unexpectedly."
        options.addItem(login)
        options.addItem(action("Keyboard Shortcuts…") { [weak self] in self?.onShowShortcuts?() })
        options.addItem(action("Welcome & Setup…") { [weak self] in self?.onShowWelcome?() })
        options.addItem(action("Check for Updates…") { [weak self] in self?.onCheckForUpdates?() })
        let diagnostics = action("Copy Diagnostics") { [weak self] in self?.onCopyDiagnostics?() }
        diagnostics.toolTip = "Copies a summary for support to paste into an email: versions, displays, and which apps' windows are in each Workspace. No window titles, files or license key."
        options.addItem(diagnostics)
        options.addItem(.separator())
        let learning = action("Learn Where Windows Go", checked: Learning.shared.isOn) { [weak self] in
            guard let self else { return }
            self.tiler.setLearning(!Learning.shared.isOn)
        }
        learning.toolTip = "Tessel learns which windows you float, how you arrange your apps, and which Workspace each app lives in. All on this Mac."
        learning.isEnabled = tiler.enabled
        options.addItem(learning)
        if Learning.shared.isOn {
            let learned = NSMenuItem(title: "What Tessel Learned", action: nil, keyEquivalent: "")
            let lessons = NSMenu()
            lessons.addItem(action("How Tessel Sees Your Windows…") { [weak self] in self?.onShowWindowClasses?() })
            lessons.addItem(.separator())
            let line = NSMenuItem(title: TimeBackWords.menuLine(week), action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = Self.howCounted(week)
            lessons.addItem(line)
            lessons.addItem(Self.footnote(TimeBackWords.howCounted.joined(separator: "\n"), toolTip: Self.howCounted(week)))
            lessons.addItem(.separator())
            let list = Learning.shared.lessons()
            if list.isEmpty {
                lessons.addItem(disabled: "Nothing yet")
                lessons.addItem(disabled: "Float a window, arrange some apps, or move an app to a Workspace.")
            } else {
                lessons.addItem(disabled: "Click a lesson to forget it")
                for lesson in list {
                    let row = action(lesson.text) { Learning.shared.forget(lesson.key) }
                    row.toolTip = "Forget this"
                    lessons.addItem(row)
                }
            }
            lessons.addItem(.separator())
            lessons.addItem(action("Reset What Tessel Learned…") { Self.confirmReset() })
            learned.submenu = lessons
            options.addItem(learned)
        }
        if let license = licensing?.license {
            options.addItem(.separator())
            options.addItem(action("Licensed to \(license.email)…") { [weak self] in self?.onEnterLicense?() })
        }
        settings.submenu = options
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tessel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// The working behind this week's number, for a tooltip.
    private static func howCounted(_ week: TimeBack.Tally) -> String {
        let rows = TimeBackWords.breakdown(week)
        return (TimeBackWords.howCounted + (rows.isEmpty ? [] : ["", "This week:"] + rows)
            + ["", "Counted on this Mac only. Reset What Tessel Learned clears it."]).joined(separator: "\n")
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

    /// Asks once, since it can't be undone. Windows stay where they are either way.
    private static func confirmReset() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget everything Tessel learned about how you work?"
        alert.informativeText = "Your windows stay where they are, and the count of time Tessel gave back starts over. Nothing Tessel learned ever left this Mac."
        alert.addButton(withTitle: "Forget Everything")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { Learning.shared.reset() }
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
