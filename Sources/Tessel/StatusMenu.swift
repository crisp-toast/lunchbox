import AppKit
import ServiceManagement

/// The menu bar item: the current space number, plus a menu.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tiler: Tiler
    var trusted = false
    var onToggle: (() -> Void)?
    var onTeachKeys: (() -> Void)?
    var onGrantAccess: (() -> Void)?
    var onShowHelp: (() -> Void)?
    var onShowWelcome: (() -> Void)?
    var onShowShortcuts: (() -> Void)?
    var onEnterLicense: (() -> Void)?
    var onBuy: (() -> Void)?
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
            for i in 0..<Tiler.spaceCount {
                let entry = action("Workspace \(i + 1)", checked: tiler.enabled && tiler.currentSpace == i) { [weak self] in
                    self?.tiler.switchSpace(to: i, focusing: nil)
                }
                entry.isEnabled = tiler.enabled
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let inFocus = tiler.focusModeIsOn
            let focus = action(inFocus ? "End Focus" : "Focus on This Window") { [weak self] in
                guard let self else { return }
                if self.tiler.focusModeIsOn { self.tiler.exitSpotlight() } else { self.tiler.perform(.spotlight) }
            }
            focus.isEnabled = tiler.enabled && (inFocus || tiler.focusedID != nil)
            menu.addItem(focus)
            let even = action("Tidy This Workspace") { [weak self] in self?.tiler.normalize() }
            even.isEnabled = tiler.enabled
            menu.addItem(even)
            let retile = action("Re-tile All Windows") { [weak self] in self?.tiler.retile() }
            retile.isEnabled = tiler.enabled
            menu.addItem(retile)
            menu.addItem(.separator())
        }

        if let licensing, licensing.license == nil {
            switch licensing.trial {
            case .active(let days): menu.addItem(disabled: "Free trial: \(days) day\(days == 1 ? "" : "s") left")
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
        let teach = action("Set Up Workspace Keys…") { [weak self] in self?.onTeachKeys?() }
        teach.isEnabled = trusted
        options.addItem(teach)
        options.addItem(action("Welcome & Setup…") { [weak self] in self?.onShowWelcome?() })
        if let license = licensing?.license {
            options.addItem(.separator())
            options.addItem(action("Licensed to \(license.email)…") { [weak self] in self?.onEnterLicense?() })
        }
        settings.submenu = options
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tessel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
