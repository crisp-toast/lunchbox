import AppKit
import LunchboxCore

/// ⇧Space: a small, instant app and window launcher.
///
/// Apps are listed from the Applications folders into memory, so matching runs
/// on every keystroke with no disk access. An app that's already open gets two
/// rows: go to its window, or open a new one. Open windows are found by the words
/// in their titles, from a snapshot taken as the panel opens, so typing never
/// waits on another app. Apps you open often rise. Summon doesn't search files: that
/// would need macOS's permission prompts for Desktop, Documents and Downloads.
final class Launcher: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    struct App {
        let name: String
        let url: URL
        let bundleID: String?
    }

    /// One entry in the list. Return runs the main action; an app with a window
    /// you can reach also offers a second one, a new window, on ⌘-Return.
    enum Result {
        /// `reachable`: it has a window you can get to, so Return goes there.
        /// `newWindow`: it also has a real New Window command, offered on ⇧↩.
        /// Otherwise Return opens the app.
        case app(App, running: NSRunningApplication?, reachable: Bool, newWindow: Bool)
        /// An open window, found by its title or app: Return goes to it, wherever it is.
        case window(Tiler.OpenWindow)
        /// Nothing matched: search the web for the text, or open it if it's an address.
        case web(String)

        var path: String {
            switch self {
            case .app(let a, _, _, _): return a.url.path
            case .window, .web: return ""
            }
        }

        /// The smaller second line, chosen with ⇧↩: a new window.
        var secondLine: (text: String, symbol: String)? {
            switch self {
            case .app(let a, _, true, true): return ("New \(a.name) window", "plus.rectangle.on.rectangle")
            default: return nil
            }
        }

        /// Which row this is, so it stays highlighted while the list changes around it.
        var key: String {
            switch self {
            case .app(let a, _, _, _): return "app " + a.url.path
            case .window(let w): return "window \(w.id)"
            case .web: return "web"
            }
        }
    }

    private let tiler: Tiler
    private var panel: LauncherPanel?
    private let field = NSTextField()
    private let rows = NSStackView()
    private var rowViews: [ResultRow] = []
    private var results: [Result] = []
    private var selected = 0
    private var apps: [App] = []
    private var appsLoadedAt: Date?
    /// The open windows as they were when the panel opened, and the search over their words.
    private var openWindows: [CGWindowID: Tiler.OpenWindow] = [:]
    private var windowSearch = WindowSearch([])
    /// What the query found, kept apart until they're put in order.
    private var appRows: [(app: Result, nameScore: Int)] = []
    private var windowRows: [Result] = []
    private var icons: [String: NSImage] = [:]

    private static let width: CGFloat = 640
    private static let fieldHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let maxRows = 8

    private var keyMonitor: Any?

    init(tiler: Tiler) {
        self.tiler = tiler
        super.init()
        reloadApps()
        // Catch ⇧↩ (a new window) here, before the search field sees it, so it
        // works however the field interprets Return.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel,
                  event.keyCode == 36 || event.keyCode == 76 else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.shift), !mods.contains(.command) else { return event }
            self.openSelection(newWindow: true)
            return nil
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show(query: String = "") {
        if appsLoadedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true { reloadApps() }
        let panel = self.panel ?? makePanel()
        field.stringValue = query
        snapshotWindows()
        update()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let height = panelHeight
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - Self.width / 2, y: area.maxY - area.height * 0.22 - height,
                              width: Self.width, height: height), display: false)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// For scripts and tests.
    func moveSelection(by delta: Int) { select(selected + delta) }
    func openSelection(newWindow: Bool = false) {
        if results.indices.contains(selected) { open(results[selected], newWindow: newWindow) }
    }
    var stateDescription: [String: Any] {
        ["visible": isVisible, "key": panel?.isKeyWindow ?? false, "query": field.stringValue, "selected": selected,
         "results": results.map { r -> String in
             let d = describe(r)
             return d.title + " | " + d.subtitle + " [↩]" + (r.secondLine.map { " + \($0.text) [⇧↩]" } ?? "")
         }]
    }

    // MARK: Apps

    private func reloadApps() {
        appsLoadedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.scanApplications()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = found
                if self.isVisible { self.update() } // a search typed before the list was ready
            }
        }
    }

    private static func scanApplications() -> [App] {
        let fm = FileManager.default
        var roots = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications",
        ]
        // Apps kept on another drive, in its own Applications folder.
        for volume in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] where !volume.hasPrefix(".") {
            roots.append("/Volumes/\(volume)/Applications")
        }
        // Xcode's own tools: Contents/Applications from Xcode 27 (Device Hub, which has Simulator,
        // Instruments, …), Contents/Developer/Applications before it.
        if let xcodes = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for x in xcodes where x.hasPrefix("Xcode") && x.hasSuffix(".app") {
                roots.append("/Applications/\(x)/Contents/Applications")
                roots.append("/Applications/\(x)/Contents/Developer/Applications")
            }
        }
        var found: [App] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let bundleID = Bundle(url: url)?.bundleIdentifier
            let key = bundleID ?? url.path
            guard !seen.contains(key), bundleID != Bundle.main.bundleIdentifier else { return }
            seen.insert(key)
            var name = fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            found.append(App(name: name, url: url, bundleID: bundleID))
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where !item.hasPrefix(".") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    add(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let inner = try? fm.contentsOfDirectory(atPath: url.path) {
                    for sub in inner where sub.hasSuffix(".app") { add(url.appendingPathComponent(sub)) }
                }
            }
        }
        return found
    }

    // MARK: Windows

    /// Takes the open windows with the titles LunchboxWM last read, so the first keystroke already
    /// finds them, then reads every title again (each app on its own queue) and searches anew.
    /// Typing itself never asks another app for anything. Fresh titles can put a window above
    /// the top row: like new files, a row you moved to stays highlighted; otherwise the top row is.
    private func snapshotWindows() {
        setWindows(tiler.openWindows())
        tiler.readWindowTitles { [weak self] in
            guard let self, self.isVisible else { return }
            self.setWindows(self.tiler.openWindows())
            guard !self.field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.update(keeping: self.selected > 0 && self.results.indices.contains(self.selected) ? self.results[self.selected].key : nil)
        }
    }

    private func setWindows(_ list: [Tiler.OpenWindow]) {
        openWindows = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        windowSearch = WindowSearch(list.map {
            SearchableWindow(id: $0.id, appID: $0.appID ?? "pid.\($0.pid)", appName: $0.appName, title: $0.title)
        })
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { update() }

    private func update(keeping key: String? = nil) {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let uses = UserDefaults.standard.dictionary(forKey: "launcherUses") as? [String: Int] ?? [:]
        let ranked: [(app: App, nameScore: Int)]
        if query.isEmpty {
            ranked = apps.filter { (uses[$0.url.path] ?? 0) > 0 }
                .sorted { (uses[$0.url.path] ?? 0) > (uses[$1.url.path] ?? 0) }
                .map { ($0, 0) }
        } else {
            ranked = apps.compactMap { app -> (App, Int, Int)? in
                guard let s = AppNames.score(query, name: app.name, bundleID: app.bundleID) else { return nil }
                return (app, s, s + min(uses[app.url.path] ?? 0, 40) * 25)
            }
            .sorted { $0.2 > $1.2 }
            .prefix(Self.maxRows)
            .map { ($0.0, $0.1) }
        }
        appRows = ranked.map { (row(for: $0.app), $0.nameScore) }
        windowRows = windowSearch.find(query, listedApps: Set(ranked.compactMap(\.app.bundleID)))
            .compactMap { openWindows[$0.id] }.map { .window($0) }
        compose(keeping: key)
    }

    private func row(for app: App) -> Result {
        let running = runningApp(app)
        let reachable = running.map { tiler.hasReachableWindow(ofApp: $0.processIdentifier) } ?? false
        var newWindow = false
        if reachable, let running {
            // Only apps with a real New Window command get the ⇧↩ line; the
            // first time, LunchboxWM looks at the app's menus and redraws.
            newWindow = tiler.supportsNewWindow(pid: running.processIdentifier, bundleID: app.bundleID) { [weak self] in
                self?.refreshKeepingSelection()
            } ?? false
        }
        return .app(app, running: running, reachable: reachable, newWindow: newWindow)
    }

    /// Puts the list together: apps named by the query, windows, then apps that only loosely
    /// match, with the web when no app matched. `key` stays highlighted if it's there.
    private func compose(keeping key: String? = nil) {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        results = Summon.order(apps: appRows, windows: windowRows, limit: Self.maxRows).map {
            switch $0 {
            case .app(let r), .window(let r): return r
            }
        }
        if !query.isEmpty, appRows.isEmpty {
            // A web address typed out is a site to open, ahead of windows that only partly match
            // it ("github.com" and a GitHub tab); a window matching all of it ("Tiler.swift") stays first.
            let complete = windowRows.contains { row in
                if case .window(let w) = row { return windowSearch.matchesEveryWord(query, window: w.id) }
                return false
            }
            if Self.address(in: query) != nil, !complete { results.insert(.web(query), at: 0) } else { results.append(.web(query)) }
        }
        selected = key.flatMap { k in results.firstIndex { $0.key == k } } ?? 0
        render()
    }

    /// Re-runs the search after a menu check or fresh titles, keeping the highlighted row.
    private func refreshKeepingSelection() {
        guard isVisible else { return }
        update(keeping: results.indices.contains(selected) ? results[selected].key : nil)
    }

    private func runningApp(_ app: App) -> NSRunningApplication? {
        guard let id = app.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    // MARK: Opening

    /// Runs exactly one action: going to the app's window (Return), or a new
    /// window (Shift-Return, only offered when the app has a window to go to).
    private func open(_ result: Result, newWindow: Bool) {
        hide()
        if case .window(let w) = result {
            // Wherever it is: another Workspace, another display, the Dock. If it closed
            // since Summon opened, its app's most recent window instead.
            if !tiler.goToWindow(w.id) { _ = tiler.goToWindow(ofApp: w.pid) }
            return
        }
        var uses = UserDefaults.standard.dictionary(forKey: "launcherUses") as? [String: Int] ?? [:]
        uses[result.path, default: 0] += 1
        UserDefaults.standard.set(uses, forKey: "launcherUses")

        // Whatever opens lands in this Workspace, tiled, and Focus ends here.
        switch result {
        case .app(let app, _, let reachable, let canNew) where (newWindow && canNew) || !reachable:
            tiler.prepareForOpening(with: app.bundleID)
            // A window is surely on its way (the app's first, or a new one): hold its
            // spot right now, so even a slow launch shows something happening.
            if let id = app.bundleID { tiler.expectWindow(from: id, another: newWindow && canNew) }
        case .web:
            tiler.prepareForOpening(with: Self.defaultBrowser.flatMap { Bundle(path: $0.path)?.bundleIdentifier })
        default:
            break
        }

        switch result {
        case .app(let app, let running?, true, let canNew):
            if newWindow && canNew {
                tiler.openNewWindow(ofApp: running.processIdentifier) { [weak self] opened in
                    if !opened { self?.launch(app) }
                }
            } else if !tiler.goToWindow(ofApp: running.processIdentifier) {
                launch(app)
            }
        case .app(let app, _, _, _):
            launch(app)
        case .web(let text):
            if let url = Self.webURL(for: text) { openWeb(url) }
        case .window:
            break // handled above
        }
    }

    /// Opens a search or address in the Workspace you're in: as a new tab in the browser's
    /// window here, or in a new window here when it has none here. Never in a window parked in
    /// another Workspace, and never a pop-up somewhere LunchboxWM then has to tidy (Little Arc).
    private func openWeb(_ url: URL) {
        guard let bundleID = Self.defaultBrowser.flatMap({ Bundle(path: $0.path)?.bundleIdentifier }),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated })
        else {
            // Not running yet: it opens a window for the page as it starts, and that window tiles here.
            NSWorkspace.shared.open(url)
            return
        }
        let pid = running.processIdentifier
        tiler.focusWindowHere(ofApp: bundleID) { [weak self] frame in
            guard let self else { return }
            guard Browsers.canScript(bundleID) else { return self.openUnscripted(url, pid: pid, windowHere: frame != nil) }
            Browsers.open(url, in: bundleID, windowAt: frame?.origin) { [weak self] ok in
                if !ok { self?.openUnscripted(url, pid: pid, windowHere: frame != nil) }
            }
        }
    }

    /// Without a script (a browser that has none, or Automation turned off for it), a browser
    /// opens a link in the window it used last. With one here, that's the one just focused;
    /// without, a new window opens here first (the browser's own New Window command) and the
    /// link goes into it.
    private func openUnscripted(_ url: URL, pid: pid_t, windowHere: Bool) {
        guard !windowHere else { NSWorkspace.shared.open(url); return }
        tiler.openNewWindowHere(ofApp: pid) { _ in NSWorkspace.shared.open(url) }
    }

    // MARK: Web

    /// The search engine chosen in macOS (Safari's setting is system-wide),
    /// as a display name and a URL template.
    private static var searchEngine: (name: String, template: String) {
        let provider = (UserDefaults.standard.dictionary(forKey: "NSPreferredWebServices")?["NSWebServicesProviderWebSearch"]) as? [String: Any]
        let id = (provider?["NSProviderIdentifier"] as? String ?? "com.google.www").lowercased()
        let name = provider?["NSDefaultDisplayName"] as? String
        let known: [(String, String, String)] = [
            ("duckduckgo", "DuckDuckGo", "https://duckduckgo.com/?q=%@"),
            ("bing", "Bing", "https://www.bing.com/search?q=%@"),
            ("yahoo", "Yahoo", "https://search.yahoo.com/search?p=%@"),
            ("ecosia", "Ecosia", "https://www.ecosia.org/search?q=%@"),
            ("baidu", "Baidu", "https://www.baidu.com/s?wd=%@"),
            ("yandex", "Yandex", "https://yandex.com/search/?text=%@"),
            ("sogou", "Sogou", "https://www.sogou.com/web?query=%@"),
        ]
        if let match = known.first(where: { id.contains($0.0) }) { return (name ?? match.1, match.2) }
        return (name ?? "Google", "https://www.google.com/search?q=%@")
    }

    /// Text that looks like a web address ("github.com", "apple.com/mac").
    private static func address(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" "), t.range(of: #"^(https?://)?[\w-]+(\.[\w-]+)+(:\d+)?(/\S*)?$"#, options: .regularExpression) != nil
        else { return nil }
        return URL(string: t.hasPrefix("http") ? t : "https://\(t)")
    }

    private static func webURL(for text: String) -> URL? {
        if let url = address(in: text) { return url }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let q = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchEngine.template.replacingOccurrences(of: "%@", with: q))
    }

    private static var defaultBrowser: (name: String, path: String)? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return (name, url.path)
    }

    private func launch(_ app: App) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { [weak self] _, error in
            guard let error else { return }
            log.error("launch \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { self?.tiler.stopExpecting(app.bundleID, why: "it couldn't open") }
        }
    }

    // MARK: Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): select(selected + 1)
        case #selector(NSResponder.moveUp(_:)): select(selected - 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⇧↩ opens a new window. Read the modifiers from the keyboard itself:
            // the panel doesn't activate LunchboxWM, so NSApp.currentEvent can be stale.
            let flags = NSEvent.modifierFlags.union(NSApp.currentEvent?.modifierFlags ?? [])
            openSelection(newWindow: flags.contains(.shift))
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func select(_ index: Int) {
        guard !results.isEmpty else { return }
        selected = (index + results.count) % results.count
        for (i, row) in rowViews.enumerated() { row.isSelected = i == selected }
    }

    // MARK: Drawing

    private var panelHeight: CGFloat {
        guard !results.isEmpty else { return Self.fieldHeight }
        let rows = results.map { $0.secondLine != nil ? Self.rowHeight + ResultRow.secondaryHeight : Self.rowHeight }
        return Self.fieldHeight + rows.reduce(0, +) + 12
    }

    private func describe(_ result: Result) -> (title: String, subtitle: String, icon: String) {
        switch result {
        case .app(let app, let running, let reachable, _):
            let subtitle = reachable ? "Go to its window" : (running == nil ? "Open" : "Open · running with no windows")
            return (app.name, subtitle, app.url.path)
        case .window(let w):
            let place = w.minimized ? "Minimized" : w.space.map { "Workspace \($0 + 1)" } ?? "Floating"
            let subtitle = ([w.appName, place] + (w.display.map { [$0] } ?? [])).joined(separator: " · ")
            return (w.title.isEmpty ? w.appName : w.title, subtitle, w.appURL?.path ?? "")
        case .web(let text):
            let browser = Self.defaultBrowser
            let inBrowser = browser.map { " in \($0.name)" } ?? ""
            if Self.address(in: text) != nil {
                return ("Open \(text)", "Website\(inBrowser)", browser?.path ?? "/Applications/Safari.app")
            }
            return ("Search the web for “\(text)”", "\(Self.searchEngine.name)\(inBrowser)", browser?.path ?? "/Applications/Safari.app")
        }
    }

    private func icon(for path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    private func render() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = results.enumerated().map { i, result in
            let d = describe(result)
            let row = ResultRow(title: d.title, subtitle: d.subtitle, icon: icon(for: d.icon), secondLine: result.secondLine)
            row.isSelected = i == selected
            row.onClick = { [weak self] secondLine in
                guard let self, self.results.indices.contains(i) else { return }
                self.open(self.results[i], newWindow: secondLine)
            }
            rows.addArrangedSubview(row)
            return row
        }
        rows.isHidden = results.isEmpty
        guard let panel, panel.isVisible else { return }
        var frame = panel.frame
        let height = panelHeight
        frame.origin.y += frame.height - height // keep the search field where it is
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
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
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.75).cgColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.placeholderString = "Summon an app, window or website"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.spacing = 0
        rows.alignment = .leading
        rows.distribution = .fill
        rows.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(field)
        background.addSubview(rows)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 13),
            rows.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            rows.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight + 4),
        ])
        panel.contentView = background
        self.panel = panel
        return panel
    }
}

/// A borderless panel that can take typing without activating LunchboxWM, so the
/// app you were in stays in front (the way Spotlight behaves).
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One app (or window, or web search) in the list. The main line carries a ↩ keycap; an app with
/// a window to go to gets a second, smaller line, "New … window", with ⇧↩ (and
/// the folder offer gets "Don't show this again").
/// Both lines are one selection, so a key press can only ever do one thing.
private final class ResultRow: NSView {
    static let mainHeight: CGFloat = 46
    static let secondaryHeight: CGFloat = 30

    var onClick: ((_ secondLine: Bool) -> Void)?
    var isSelected = false { didSet { refresh() } }
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let returnKey = Keycap(text: "↩")
    private var secondLabel: NSTextField?
    private var shiftReturnKey: Keycap?
    private let hasSecondary: Bool

    init(title text: String, subtitle detail: String, icon: NSImage, secondLine: (text: String, symbol: String)?) {
        hasSecondary = secondLine != nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        title.stringValue = text
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.stringValue = detail
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.lineBreakMode = .byTruncatingMiddle
        for v in [iconView, title, subtitle, returnKey] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let height = Self.mainHeight + (hasSecondary ? Self.secondaryHeight : 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            widthAnchor.constraint(equalToConstant: 628),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.mainHeight / 2),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: returnKey.leadingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: returnKey.leadingAnchor, constant: -10),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            returnKey.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            returnKey.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.mainHeight / 2),
        ])

        if let secondLine {
            let label = NSTextField(labelWithString: secondLine.text)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            let symbol = NSImageView(image: NSImage(systemSymbolName: secondLine.symbol, accessibilityDescription: nil) ?? NSImage())
            symbol.contentTintColor = .secondaryLabelColor
            let key = Keycap(text: "⇧↩")
            for v in [symbol, label, key] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                symbol.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                symbol.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Self.secondaryHeight / 2 - 3),
                symbol.widthAnchor.constraint(equalToConstant: 16),
                symbol.heightAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 7),
                label.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -10),
                key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                key.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
            ])
            secondLabel = label
            shiftReturnKey = key
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        title.textColor = isSelected ? .white : .labelColor
        subtitle.textColor = isSelected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        secondLabel?.textColor = isSelected ? NSColor.white.withAlphaComponent(0.92) : .labelColor
        returnKey.onAccent = isSelected
        shiftReturnKey?.onAccent = isSelected
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        // The second line sits at the bottom of the row (AppKit y grows upward).
        onClick?(hasSecondary && y < Self.secondaryHeight + 4)
    }
}

/// A small key-shaped label like ↩ or ⇧↩.
final class Keycap: NSView {
    private let label: NSTextField
    var onAccent = false { didSet { refresh() } }

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        let color = onAccent ? NSColor.white : NSColor.secondaryLabelColor
        label.textColor = color
        layer?.borderColor = color.withAlphaComponent(onAccent ? 0.7 : 0.45).cgColor
        layer?.backgroundColor = (onAccent ? NSColor.white.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.05)).cgColor
    }
}
