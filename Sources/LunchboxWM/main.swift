import AppKit
import ServiceManagement
import LunchboxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tiler = Tiler()
    private lazy var tap: HotkeyTap = HotkeyTap { [weak self] action in
        guard let self else { return }
        self.onboarding.noted(action)
        // Practicing in onboarding: shortcuts drive the pretend screen, including
        // its pretend Summon and Cheat Sheet.
        if self.onboarding.capturesWindowActions {
            self.onboarding.playgroundPerform(action)
            return
        }
        // During Sort My Windows' show, a Workspace's keys pick the Workspace to start in.
        if case .switchSpace(let index) = action, self.sorter.choose(workspace: index) { return }
        switch action {
        case .launcher: self.launcher.toggle()
        case .help: self.help.toggle()
        default: self.tiler.perform(action)
        }
    }
    private lazy var launcher: Launcher = Launcher(tiler: tiler)
    private lazy var help: HelpPanel = HelpPanel { [weak self] in (self?.tap.keymap ?? Keymap(), self?.tap.spaceKeys ?? []) }
    private lazy var menu: StatusMenu = StatusMenu(tiler: tiler)
    private lazy var onboarding: Onboarding = Onboarding(tap: tap, tiler: tiler)
    private lazy var shortcuts: ShortcutsWindow = ShortcutsWindow(tap: tap)
    private lazy var sorter: WindowSorter = WindowSorter(tiler: tiler)
    private let licensing = Licensing()
    private let updater = Updater()
    private lazy var licenseWindow = LicenseWindow(licensing: licensing)
    private var revocationTimer: Timer?
    private var trustPoll: Timer?
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !(DEBUG || LUNCHBOX_DEV)
        // Run from its disk image or Downloads: offer to move to Applications first.
        if Install.offerMoveToApplications() { return }
        #endif
        // Dragged to the Trash while running: stop opening at login, and quit (parked windows come back).
        Install.watchForTrash {
            log.notice("moved to the Trash; quitting, and no longer opening at login")
            Install.stopOpeningAtLogin()
            NSApp.terminate(nil)
        }
        // The time back is read now, so the menu has it even before tiling starts (waiting for
        // Accessibility, or for a license).
        TimeBackLedger.shared.load()
        tiler.onChange = { [weak self] in
            guard let self else { return }
            self.menu.refresh()
            self.tap.centeredWindows = self.tiler.centeredWindows
            self.tap.arrangedWindows = self.tiler.arrangedWindows
        }
        tap.onArrangementDrag = { [weak self] event in self?.tiler.arrangementDrag(event) }
        // The quiet line names the undo key: ⌘ and the number of the Workspace you were in.
        tiler.undoKeyName = { [weak self] space in
            guard let self, space < Command.maxWorkspaces else { return nil }
            return Keymap.keycaps(for: self.tap.keymap.binding(for: .goTo(space)), workspaceKeys: self.tap.spaceKeys).joined(separator: " ")
        }
        tap.spaceCount = tiler.spaceCount
        tiler.onSpaceCountChange = { [weak self] count in self?.tap.spaceCount = count }
        _ = launcher // build the app list now, so the first ⇧Space already finds apps
        menu.onToggle = { [weak self] in self?.toggleTiling() }
        menu.onShowWelcome = { [weak self] in
            self?.onboarding.show()
            self?.updateUnlicensedKeys()
        }
        menu.onShowShortcuts = { [weak self] in self?.shortcuts.show() }
        menu.licensing = licensing
        menu.onEnterLicense = { [weak self] in self?.licenseWindow.show() }
        menu.onBuy = { NSWorkspace.shared.open(Licensing.buyURL) }
        menu.onCheckForUpdates = { [weak self] in self?.updater.checkNow() }
        menu.updater = updater
        updater.onChange = { [weak self] in self?.menu.refresh() }
        menu.onCopyDiagnostics = { [weak self] in self?.copyDiagnostics() }
        licensing.onChange = { [weak self] in self?.licenseChanged() }
        // Activated mid-setup (the thank-you page's link): the welcome window comes back to the front.
        licenseWindow.onActivated = { [weak self] in self?.onboarding.bringToFront() }
        // licenseChanged has already paused tiling by then; this says why.
        licensing.onRevoked = { [weak self] license in
            self?.licenseWindow.show(error: "The license for \(license.email) was refunded, so it no longer unlocks Lunchbox. If that's a mistake, write to support@sentientdonut.com.")
        }
        shortcuts.onChange = { KeymapStore.save($0) }
        help.onCustomize = { [weak self] in self?.shortcuts.show() }
        onboarding.onCustomize = { [weak self] in self?.shortcuts.show() }
        onboarding.onKeymapChange = { [weak self] map in
            self?.tap.keymap = map
            KeymapStore.save(map)
        }
        onboarding.onClose = { [weak self] in self?.waitForLicense() }
        onboarding.sortPreview = { [weak self] in self?.tiler.previewSort() }
        onboarding.canTile = { [weak self] in self?.licensing.canTile ?? false }
        // Yes to sorting: right after setup closes, or once a license starts tiling.
        onboarding.onSort = { [weak self] in
            guard let self else { return }
            if self.tiler.enabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.sorter.run() }
            } else {
                self.sorter.pending = true
            }
        }
        sorter.keycaps = { [weak self] command in
            guard let self else { return nil }
            // "Left ⌘1", and a sequence spaced out: "⇧ then Space".
            return Keymap.keycaps(for: self.tap.keymap.binding(for: command), workspaceKeys: self.tap.spaceKeys)
                .map { $0 == "then" ? " then " : $0 }.joined()
        }
        menu.onSort = { [weak self] in self?.sorter.run() }
        menu.onUndoSort = { [weak self] in self?.sorter.undo() }
        onboarding.onStartFresh = { [weak self] windows in self?.sorter.startFresh(windows) }
        menu.sorting = { [weak self] in self?.sorter.isRunning ?? false }
        onboarding.onRequestAccess = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { Self.openAccessibilitySettings() }
        }
        menu.onShowHelp = { [weak self] in self?.help.show() }
        menu.onGrantAccess = { Self.openAccessibilitySettings() }
        tap.spaceKeys = (UserDefaults.standard.array(forKey: "spaceKeys") as? [Int]).map { $0.map(Int64.init) } ?? []
        tap.keymap = KeymapStore.load()

        // Quit cleanly on `kill`, so parked windows come back.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source

        listenForCommands()

        // New here (or setup unfinished): the welcome window walks through Accessibility and a
        // little practice instead of a bare system prompt. (Earlier versions had you choose
        // three Workspace keys: having them means setup was done.)
        let setUpBefore = UserDefaults.standard.bool(forKey: "onboardingDone") || tap.spaceKeys.count == 3
        if !AXIsProcessTrusted() {
            // Set up before (only access is missing again, say after a reinstall): just that step.
            onboarding.show(at: setUpBefore ? .access : .welcome, accessOnly: setUpBefore)
        } else if !setUpBefore {
            onboarding.show()
        }
        if AXIsProcessTrusted() {
            begin()
        } else {
            log.notice("waiting for Accessibility access")
            menu.refresh()
            trustPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.begin()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tiler.revealHiddenWindows()
        TimeBackLedger.shared.saveNow()
    }

    private func begin() {
        menu.trusted = true
        guard tap.start() else {
            // Access was just granted; the event tap can take a moment to be allowed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.begin() }
            return
        }
        if licensing.canTile {
            tap.enabled = true
            tiler.start()
            menu.refresh()
        } else {
            waitForLicense()
        }
        licensing.checkRevocationIfDue()
        // A licensed copy checks for refunds about once a week: look now and then, and after sleep.
        revocationTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.licensing.checkRevocationIfDue()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.licensing.checkRevocationIfDue()
        }
        // Start at login by default, once; the menu can turn it off and that sticks.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            LoginItem.set(true)
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        } else {
            LoginItem.migrate()
        }
    }

    private func toggleTiling() {
        setTiling(!tiler.enabled)
    }

    /// Pauses or resumes tiling and the shortcuts together. Pausing brings windows parked in other
    /// spaces back and lets every keystroke through. Asking for the current state does nothing.
    private func setTiling(_ on: Bool) {
        guard on != tiler.enabled, menu.trusted || !on else { return }
        if on, !licensing.canTile {
            licenseWindow.show()
            return
        }
        if on {
            tiler.start()
            tap.enabled = true
            // Setup's "Organize My Windows", said before there was a license: now, once the windows are in.
            if sorter.pending {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    if self?.sorter.pending == true { self?.sorter.run() }
                }
            }
        } else {
            tiler.stop()
            tap.enabled = false
        }
        log.notice("tiling \(on ? "resumed" : "paused", privacy: .public)")
        menu.refresh()
    }

    // MARK: License

    /// LunchboxWM is paid up front: without a license nothing tiles and keys pass straight
    /// through (windows stay where they are). The welcome window's practice screen still
    /// works, and once setup is done the license window asks for a key.
    private func waitForLicense() {
        guard !licensing.canTile, menu.trusted else { return }
        if tiler.enabled {
            log.notice("no license; pausing tiling")
            tiler.stop()
        }
        updateUnlicensedKeys()
        menu.refresh()
        if !onboarding.isVisible { licenseWindow.show() }
    }

    /// Unlicensed, the shortcuts are on only while the welcome window is open, for its practice
    /// screen; real windows aren't tiled meanwhile, since the tiler isn't running.
    private func updateUnlicensedKeys() {
        guard !licensing.canTile, menu.trusted else { return }
        tap.enabled = onboarding.isVisible
    }

    private func licenseChanged() {
        menu.refresh()
        if licensing.canTile {
            // Just licensed: tiling starts.
            if !tiler.enabled, menu.trusted { setTiling(true) }
        } else {
            // Refunded, or removed: tiling stops.
            waitForLicense()
        }
    }

    /// lunchbox://activate?key=… from the thank-you page or the license email.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "lunchbox" && url.host == "activate" {
            if let license = licensing.activate(url.absoluteString) {
                licenseWindow.show(activated: license)
            } else {
                licenseWindow.show(error: "That activation link didn't carry a complete license. Email apps sometimes cut long links short: copy the key from the email and paste it here.")
            }
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The distributed notification scripts post commands to (README, Scripting).
    static let commandChannel = Notification.Name("com.sentientdonut.lunchbox.command")

    /// Lets scripts drive LunchboxWM without the keyboard, e.g.
    /// `osascript -l JavaScript -e '…postNotificationName("<commandChannel>", "pause")…'`.
    /// Any process on the Mac can post these, so the builds customers get take only what an agent
    /// needs there: pause, resume, retile and balance. Everything else (pressing keys with LunchboxWM's
    /// Accessibility permission, dump, license:, find:, leave-app:…) exists only in development
    /// builds (see `Build`), and isn't in a release binary at all.
    private func listenForCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.commandChannel, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            self.run(command)
        }
    }

    private func run(_ command: String) {
        switch command {
        case "pause": setTiling(false)
        case "resume": setTiling(true)
        case "retile": tiler.retile()
        case "balance": tiler.normalize()
        default:
            #if DEBUG || LUNCHBOX_DEV
            runDevelopment(command)
            #else
            // Only the name, so whatever else a stranger sent stays out of the log (and out of
            // Copy Diagnostics).
            let name = command.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(32)
            log.error("ignored command \(String(name), privacy: .public): only development builds take it")
            #endif
        }
    }

    #if DEBUG || LUNCHBOX_DEV
    /// The commands for tests, demos and agents on test Macs: focus-/move-left|right|up|down, grow,
    /// shrink, space-1…9, send-1…9, workspaces-3…9, dump (writes the state to
    /// ~/Library/Application Support/LunchboxWM/state.json), press:, license:, timeback-add:… (README, Scripting).
    private func runDevelopment(_ command: String) {
        if command.hasPrefix("license:") {
            // license:<key> activates; license:window shows the window; license:remove forgets it.
            let arg = String(command.dropFirst(8))
            switch arg {
            case "window": licenseWindow.show()
            case "remove": licensing.removeLicense()
            case _ where arg.hasPrefix("snapshot:"):
                // license:snapshot:<png path>
                licenseWindow.snapshot(to: String(arg.dropFirst(9)))
            default: if licensing.activate(arg) == nil { licenseWindow.show(error: "Not a valid key.") }
            }
            return
        }
        if command.hasPrefix("find:") {
            launcher.show(query: String(command.dropFirst(5)))
            return
        }
        // leave-app:<bundle id> / manage-app:<bundle id>: an agent testing that app on the
        // spoof display asks LunchboxWM to stop tiling its windows, then to resume.
        if command.hasPrefix("leave-app:") || command.hasPrefix("manage-app:") {
            let leave = command.hasPrefix("leave-app:")
            tiler.setLeftAlone(String(command.drop(while: { $0 != ":" }).dropFirst()), leave)
            return
        }
        if command.hasPrefix("press:") {
            // press:<keycode>[:cmd][:shift][:opt] presses modifiers down, taps the
            // key, and lets go, through the whole system like a real keyboard
            // (so ⇧ then Space works too). For end-to-end tests and demo recordings.
            let parts = command.split(separator: ":").map(String.init)
            guard parts.count >= 2, let code = CGKeyCode(parts[1]) else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            var mods: [(CGKeyCode, CGEventFlags)] = []
            if parts.contains("cmd") { mods.append((55, [.maskCommand, CGEventFlags(rawValue: Shortcuts.leftCommandMask)])) }
            if parts.contains("shift") { mods.append((56, [.maskShift, CGEventFlags(rawValue: 0x02)])) }
            if parts.contains("opt") { mods.append((58, [.maskAlternate, CGEventFlags(rawValue: 0x20)])) }
            var flags = CGEventFlags()
            func post(_ key: CGKeyCode, _ down: Bool) {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
                e.flags = flags
                e.post(tap: .cghidEventTap)
            }
            for (key, f) in mods { flags.formUnion(f); post(key, true) }
            post(code, true)
            post(code, false)
            for (key, f) in mods.reversed() { flags.subtract(f); post(key, false) }
            return
        }
        // expect:<bundle id> holds a tile for a window of that app as if Summon had just
        // opened it (without opening anything), to try placeholders.
        if command.hasPrefix("expect:") {
            tiler.expectWindow(from: String(command.dropFirst(7)), another: true)
            return
        }
        // timeback-add:<action>:<count>[:<days ago>] counts time back as if LunchboxWM had done it
        // (tiled, arranged, sent, restored, summoned, corrected, displayReturned), to try the
        // menu line without a week of windows.
        if command.hasPrefix("timeback-add:") {
            let bits = command.dropFirst(13).split(separator: ":").map(String.init)
            guard let action = bits.first.flatMap(TimeBackAction.init(rawValue:)) else { return }
            let times = bits.count > 1 ? Int(bits[1]) ?? 1 : 1
            let ago = bits.count > 2 ? Int(bits[2]) ?? 0 : 0
            TimeBackLedger.shared.count(action, times: times, at: Date().addingTimeInterval(-Double(ago) * 86_400))
            return
        }
        if command.hasPrefix("help:") {
            help.show(query: String(command.dropFirst(5)))
            return
        }
        // practice:<command> drives onboarding's practice screen without real key
        // presses or keyboard focus (focus-left, grow, spotlight, space-2, launcher,
        // help, type:<text>, key:return|escape|up|down|shift-return), for testing.
        if command.hasPrefix("practice:") {
            let rest = String(command.dropFirst(9))
            if rest.hasPrefix("type:") { onboarding.playgroundType(String(rest.dropFirst(5))); return }
            if rest.hasPrefix("key:") { onboarding.playgroundKey(String(rest.dropFirst(4))); return }
            guard let action = Self.keyAction(rest) else { log.error("unknown practice command \(rest, privacy: .public)"); return }
            onboarding.noted(action)
            onboarding.playgroundPerform(action)
            return
        }
        // sort, sort@<display id> (only that display's windows), sort-demo@<display id> (made-up
        // windows, nothing moves), sort-pick (the Workspace lit up) or sort-pick:<n> (the show's nth,
        // from 1), sort-undo, sort-sound:<wav path> (and <path>-opening.wav beside it).
        // fresh-app:<bundle id>@<display id>: Start Fresh on one app's windows, no question asked,
        // its note on that display; fresh-question and fresh-cancel: setup's question, for screenshots.
        if command.hasPrefix("fresh-app:") {
            let bits = String(command.dropFirst(10)).split(separator: "@").map(String.init)
            let display = bits.count > 1 ? UInt32(bits[1]).flatMap { id in Display.current().first { $0.id == id } } : nil
            StartFresh.windows(onlyApp: bits[0]) { [weak self] found in self?.sorter.startFresh(found, noteOn: display) }
            return
        }
        if command == "fresh-question" { onboarding.showStartFreshQuestion(); return }
        if command == "fresh-cancel" { onboarding.cancelSheet(); return }
        if command == "sort" || command.hasPrefix("sort@") || command.hasPrefix("sort-") {
            let bits = command.split(separator: "@").map(String.init)
            let display = bits.count > 1 ? UInt32(bits[1]).flatMap { id in Display.current().first { $0.id == id } } : nil
            if command.hasPrefix("sort-demo") {
                if let display { sorter.demo(on: display) }
            } else if command == "sort-undo" {
                tiler.undoSort()
            } else if command == "sort-pick" || command.hasPrefix("sort-pick:") {
                sorter.pick(Int(command.dropFirst(10)).map { $0 - 1 })
            } else if command.hasPrefix("sort-sound:") {
                let timeline = Timeline(cards: 12, still: false)
                let plinks = (0..<12).map { (timeline.arrival($0), Double($0 % 3 - 1) * 0.45) }
                let sound = SortSound.render(timeline, plinks: plinks)
                let url = URL(fileURLWithPath: String(command.dropFirst(11)))
                try? sound.sorting.write(to: url)
                try? sound.opening.write(to: url.deletingLastPathComponent()
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-opening.wav"))
            } else {
                sorter.run(onDisplay: display?.uuid)
            }
            return
        }
        let parts = command.split(separator: "-").map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("focus", let d?): if let dir = Direction(rawValue: d) { tiler.perform(.focus(dir)) }
        case ("move", let d?): if let dir = Direction(rawValue: d) { tiler.perform(.move(dir)) }
        case ("grow", _): tiler.perform(.grow)
        case ("shrink", _): tiler.perform(.shrink)
        case ("close", let id?): if let id = CGWindowID(id) { tiler.close(windowID: id) }
        case ("close", _): tiler.perform(.close)
        case ("hide", _): tiler.perform(.hide)
        case ("spotlight", _): tiler.perform(.spotlight)
        case ("launcher", "open"?): launcher.openSelection()
        case ("launcher", "new"?): launcher.openSelection(newWindow: true)
        case ("launcher", "down"?): launcher.moveSelection(by: 1)
        case ("launcher", "up"?): launcher.moveSelection(by: -1)
        case ("launcher", _): launcher.toggle()
        case ("help", _): help.toggle()
        case ("shortcuts", _): shortcuts.show()
        case ("welcome", let n?):
            // welcome-<step>, or welcome-<step>@<display id> to open it on that display
            // without taking keyboard focus (agents test on a display Tyler can't see).
            let bits = n.split(separator: "@").map(String.init)
            guard let i = Int(bits[0]), let step = Onboarding.Step(rawValue: i) else { break }
            if bits.count > 1, let display = UInt32(bits[1]) {
                onboarding.show(at: step, onDisplay: display)
            } else {
                onboarding.show(at: step)
            }
        case ("welcome", _): onboarding.show()
        case ("welcomeclose", _): onboarding.close()
        case ("space", let n?): if let i = Int(n) { tiler.perform(.switchSpace(i - 1)) }
        case ("send", let n?): if let i = Int(n) { tiler.perform(.sendToSpace(i - 1)) }
        case ("displays", "all"?): tiler.setUseAllDisplays(true)
        case ("displays", "main"?): tiler.setUseAllDisplays(false)
        case ("balance", _), ("normalize", _): tiler.normalize()
        case ("retile", _): tiler.retile()
        case ("pause", _): setTiling(false)
        case ("resume", _): setTiling(true)
        // Float or tile the focused window.
        case ("float", _): tiler.toggleFloating()
        case ("dump", _): dumpState()
        case ("copy", "diagnostics"?): copyDiagnostics()
        case ("workspaces", let n?): if let n = Int(n) { tiler.setSpaceCount(n) }
        default: log.error("unknown command \(command, privacy: .public)")
        }
    }

    /// The shortcut a debug command names, like "focus-left" or "space-2".
    static func keyAction(_ command: String) -> KeyAction? {
        let parts = command.split(separator: "-").map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("focus", let d?): return Direction(rawValue: d).map { .focus($0) }
        case ("move", let d?): return Direction(rawValue: d).map { .move($0) }
        case ("grow", _): return .grow
        case ("shrink", _): return .shrink
        case ("close", _): return .close
        case ("hide", _): return .hide
        case ("spotlight", _): return .spotlight
        case ("balance", _), ("normalize", _): return .normalize
        case ("space", let n?): return Int(n).map { .switchSpace($0 - 1) }
        case ("send", let n?): return Int(n).map { .sendToSpace($0 - 1) }
        case ("launcher", _): return .launcher
        case ("help", _): return .help
        default: return nil
        }
    }

    private func dumpState() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LunchboxWM")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state = tiler.stateDescription()
        state["spaceKeys"] = tap.spaceKeys
        state["spaceCount"] = tiler.spaceCount
        state["launcher"] = launcher.stateDescription
        state["help"] = help.stateDescription
        state["timeBack"] = TimeBackLedger.shared.stateDescription
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("state.json"))
        }
    }
    #endif

    // MARK: Support

    /// Settings › Copy Diagnostics: a support summary on the clipboard, without window titles,
    /// file paths or the license.
    private func copyDiagnostics() {
        SupportDiagnostics.copy(tiler: tiler, licensing: licensing, trusted: menu.trusted)
    }
}

// Thrown away: don't run (or open at login) from the Trash.
Install.quitIfInTrash()
// LunchboxWM was Tessel: on a Mac that had it, take over from it, once.
OldAppID.carryOver()
// One LunchboxWM at a time; and when it's set to open at login, launchd runs it, so it comes
// back by itself after a crash.
if LoginItem.anotherCopyIsRunning() { exit(0) }
if LoginItem.handOff() { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

/// Saves the user's changed shortcuts; anything not changed follows the defaults.
enum KeymapStore {
    private static let key = "keymap"

    static func load() -> Keymap {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: KeyBinding].self, from: data) else { return Keymap() }
        var map = Keymap()
        for (name, binding) in stored {
            // Hide was called Stash before.
            if let c = Command(rawValue: name == "stash" ? "hide" : name) { map.overrides[c] = binding }
        }
        return map
    }

    static func save(_ map: Keymap) {
        let stored = Dictionary(uniqueKeysWithValues: map.overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: key) }
    }
}
