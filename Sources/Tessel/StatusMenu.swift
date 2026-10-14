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
        let symbol = tiler.enabled ? "rectangle.split.3x1" : "rectangle.dashed"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tessel")
        button.image?.isTemplate = true
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
                let entry = action("Space \(i + 1)", checked: tiler.enabled && tiler.currentSpace == i) { [weak self] in
                    self?.tiler.switchSpace(to: i, focusing: nil)
                }
                entry.isEnabled = tiler.enabled
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let float = action(tiler.focusedIsTiled ? "Float Focused Window" : "Tile Focused Window") { [weak self] in
                self?.tiler.toggleFloatingForFocused()
            }
            float.isEnabled = tiler.enabled && tiler.focusedID != nil
            menu.addItem(float)
            let even = action("Normalize Windows") { [weak self] in self?.tiler.normalize() }
            even.isEnabled = tiler.enabled
            menu.addItem(even)
            let retile = action("Re-tile All Windows") { [weak self] in self?.tiler.retile() }
            retile.isEnabled = tiler.enabled
            menu.addItem(retile)
            menu.addItem(.separator())
        }

        let shortcuts = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        let list = NSMenu()
        for line in [
            "Left ⌘ + arrows: focus the next window",
            "Left ⌘⇧ + arrows: move the window",
            "Left ⌘⇧ + plus / minus: more or less space",
            "Left ⌘⇧ + Delete: close the window",
            "Left ⌘⇧ + H: hide the window in space 3",
            "Left ⌘⇧ + F: spotlight the window, the rest shelved at the side",
            "Left ⌘⇧ + 0: normalize every window in this space",
            "⌘ + space key: go to space 1, 2 or 3",
            "⌘⇧ + space key: move the window to that space and go with it",
            "⇧ Space: open the launcher (apps, then files)",
            "Right ⌘ + arrows still move the text cursor",
        ] { list.addItem(disabled: line) }
        shortcuts.submenu = list
        menu.addItem(shortcuts)
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let options = NSMenu()
        let displays = action("Use All Displays", checked: tiler.useAllDisplays) { [weak self] in
            guard let self else { return }
            self.tiler.setUseAllDisplays(!self.tiler.useAllDisplays)
        }
        displays.toolTip = "Turn off to tile only on the main display, for example when the other display is a dummy plug."
        options.addItem(displays)
        options.addItem(action("Launch at Login", checked: SMAppService.mainApp.status == .enabled) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled { try service.unregister() } else { try service.register() }
            } catch {
                log.error("launch at login: \(error.localizedDescription, privacy: .public)")
            }
        })
        let teach = action("Set Up Space Keys…") { [weak self] in self?.onTeachKeys?() }
        teach.isEnabled = trusted
        options.addItem(teach)
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
