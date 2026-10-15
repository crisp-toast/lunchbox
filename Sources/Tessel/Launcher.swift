import AppKit
import TesselCore

/// ⇧Space: a small, instant app and file launcher.
///
/// Apps are listed from the Applications folders into memory, so matching runs
/// on every keystroke with no disk access. An app that's already open gets two
/// rows: go to its window, or open a new one. When no app matches, Spotlight's
/// index is searched for files and folders instead. Apps you open often rise.
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
        case file(URL)
        /// Nothing matched: search the web for the text, or open it if it's an address.
        case web(String)

        var path: String {
            switch self {
            case .app(let a, _, _, _): return a.url.path
            case .file(let url): return url.path
            case .web: return ""
            }
        }

        var hasNewWindowAction: Bool {
            if case .app(_, _, true, true) = self { return true }
            return false
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
    private var fileQuery: NSMetadataQuery?
    private var fileSearch: DispatchWorkItem?
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
        fileQuery?.stop()
        fileQuery = nil
        fileSearch?.cancel()
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
             return d.title + " | " + d.subtitle + " [↩]" + (r.hasNewWindowAction ? " + New window [⇧↩]" : "")
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
            "/Volumes/Master Storage/Applications",
        ]
        // Xcode's own tools (Simulator, Instruments, …).
        if let xcodes = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for x in xcodes where x.hasPrefix("Xcode") && x.hasSuffix(".app") {
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

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { update() }

    private func update() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        fileSearch?.cancel()
        fileQuery?.stop()
        fileQuery = nil

        let uses = UserDefaults.standard.dictionary(forKey: "launcherUses") as? [String: Int] ?? [:]
        let ranked: [App]
        if query.isEmpty {
            ranked = apps.filter { (uses[$0.url.path] ?? 0) > 0 }
                .sorted { (uses[$0.url.path] ?? 0) > (uses[$1.url.path] ?? 0) }
        } else {
            ranked = apps.compactMap { app -> (App, Int)? in
                guard let s = Fuzzy.score(query, app.name) else { return nil }
                return (app, s + min(uses[app.url.path] ?? 0, 40) * 25)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        }

        let list: [Result] = ranked.prefix(Self.maxRows).map { app in
            let running = runningApp(app)
            let reachable = running.map { tiler.hasReachableWindow(ofApp: $0.processIdentifier) } ?? false
            var newWindow = false
            if reachable, let running {
                // Only apps with a real New Window command get the ⇧↩ line; the
                // first time, Tessel looks at the app's menus and redraws.
                newWindow = tiler.supportsNewWindow(pid: running.processIdentifier, bundleID: app.bundleID) { [weak self] in
                    self?.refreshKeepingSelection()
                } ?? false
            }
            return .app(app, running: running, reachable: reachable, newWindow: newWindow)
        }
        results = list
        if list.isEmpty, !query.isEmpty { results = [.web(query)] }
        selected = 0
        render()

        if list.isEmpty, !query.isEmpty {
            let work = DispatchWorkItem { [weak self] in self?.searchFiles(query) }
            fileSearch = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    /// Re-runs the search after a menu check, keeping the highlighted row.
    private func refreshKeepingSelection() {
        guard isVisible, results.allSatisfy({ if case .app = $0 { return true }; return false }) else { return }
        let keep = selected
        update()
        select(min(keep, max(0, results.count - 1)))
    }

    private func runningApp(_ app: App) -> NSRunningApplication? {
        guard let id = app.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    /// Files and folders whose name contains the query, from Spotlight's index,
    /// most recently used first.
    private func searchFiles(_ query: String) {
        let cleaned = query.filter { $0 != "*" && $0 != "?" && $0 != "\"" }
        guard !cleaned.isEmpty else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(cleaned)*")
        q.searchScopes = [NSMetadataQueryUserHomeScope, URL(fileURLWithPath: "/Volumes/Master Storage")]
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(filesFound(_:)), name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.addObserver(self, selector: #selector(filesFound(_:)), name: .NSMetadataQueryDidUpdate, object: q)
        fileQuery = q
        q.start()
    }

    @objc private func filesFound(_ note: Notification) {
        guard let q = note.object as? NSMetadataQuery, q === fileQuery else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        let skip = ["/Library/", "/.", "/node_modules/", "/.build/", "/DerivedData/", "/Caches/", ".app/"]
        var files: [Result] = []
        for i in 0..<min(q.resultCount, 200) {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !skip.contains(where: { path.contains($0) }), !path.hasSuffix(".app") else { continue }
            files.append(.file(URL(fileURLWithPath: path)))
            if files.count == Self.maxRows { break }
        }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        results = files + (query.isEmpty ? [] : [.web(query)])
        selected = 0
        render()
    }

    // MARK: Opening

    /// Runs exactly one action: going to the app's window (Return), or a new
    /// window (Shift-Return, only offered when the app has a window to go to).
    private func open(_ result: Result, newWindow: Bool) {
        hide()
        var uses = UserDefaults.standard.dictionary(forKey: "launcherUses") as? [String: Int] ?? [:]
        uses[result.path, default: 0] += 1
        UserDefaults.standard.set(uses, forKey: "launcherUses")

        // Whatever opens lands in this Workspace, tiled, and Focus ends here.
        switch result {
        case .app(let app, _, let reachable, let canNew) where (newWindow && canNew) || !reachable:
            tiler.prepareForOpening(with: app.bundleID)
        case .file(let url):
            tiler.prepareForOpening(with: NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier })
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
        case .file(let url):
            NSWorkspace.shared.open(url)
        case .web(let text):
            if let url = Self.webURL(for: text) { openWeb(url) }
        }
    }

    /// Opens a search or address in the default browser's own window: a new tab in
    /// its window in this Workspace, or a new window here when it has none, so it
    /// never pops up somewhere Tessel then has to tidy (like Little Arc).
    private func openWeb(_ url: URL) {
        guard let bundleID = Self.defaultBrowser.flatMap({ Bundle(path: $0.path)?.bundleIdentifier }),
              Browsers.canScript(bundleID),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        else {
            // Not running yet (it opens a window for the page as it starts) or not scriptable.
            NSWorkspace.shared.open(url)
            return
        }
        let asTab = tiler.focusWindowHere(ofApp: bundleID)
        Browsers.open(url, in: bundleID, asTab: asTab) { ok in
            if !ok { NSWorkspace.shared.open(url) }
        }
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
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error { log.error("launch \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)") }
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
            // the panel doesn't activate Tessel, so NSApp.currentEvent can be stale.
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
        let rows = results.map { $0.hasNewWindowAction ? Self.rowHeight + ResultRow.secondaryHeight : Self.rowHeight }
        return Self.fieldHeight + rows.reduce(0, +) + 12
    }

    private func describe(_ result: Result) -> (title: String, subtitle: String, icon: String) {
        switch result {
        case .app(let app, let running, let reachable, _):
            let subtitle = reachable ? "Go to its window" : (running == nil ? "Open" : "Open · running with no windows")
            return (app.name, subtitle, app.url.path)
        case .file(let url):
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return (url.lastPathComponent, folder, url.path)
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
            var newWindowTitle: String?
            if case .app(let app, _, true, true) = result { newWindowTitle = "New \(app.name) window" }
            let row = ResultRow(title: d.title, subtitle: d.subtitle, icon: icon(for: d.icon), newWindowTitle: newWindowTitle)
            row.isSelected = i == selected
            row.onClick = { [weak self] newWindow in
                guard let self, self.results.indices.contains(i) else { return }
                self.open(self.results[i], newWindow: newWindow)
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
        field.placeholderString = "Summon an app, file or website"
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

/// A borderless panel that can take typing without activating Tessel, so the
/// app you were in stays in front (the way Spotlight behaves).
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One app (or file) in the list. The main line carries a ↩ keycap; an app with
/// a window to go to gets a second, smaller line, "New … window", with ⇧↩.
/// Both lines are one selection, so a key press can only ever do one thing.
private final class ResultRow: NSView {
    static let mainHeight: CGFloat = 46
    static let secondaryHeight: CGFloat = 30

    var onClick: ((_ newWindow: Bool) -> Void)?
    var isSelected = false { didSet { refresh() } }
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let returnKey = Keycap(text: "↩")
    private var newWindowLabel: NSTextField?
    private var shiftReturnKey: Keycap?
    private let hasSecondary: Bool

    init(title text: String, subtitle detail: String, icon: NSImage, newWindowTitle: String?) {
        hasSecondary = newWindowTitle != nil
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

        if let newWindowTitle {
            let label = NSTextField(labelWithString: newWindowTitle)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            let plus = NSImageView(image: NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil) ?? NSImage())
            plus.contentTintColor = .secondaryLabelColor
            let key = Keycap(text: "⇧↩")
            for v in [plus, label, key] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                plus.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                plus.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Self.secondaryHeight / 2 - 3),
                plus.widthAnchor.constraint(equalToConstant: 16),
                plus.heightAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 7),
                label.centerYAnchor.constraint(equalTo: plus.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -10),
                key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                key.centerYAnchor.constraint(equalTo: plus.centerYAnchor),
            ])
            newWindowLabel = label
            shiftReturnKey = key
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        title.textColor = isSelected ? .white : .labelColor
        subtitle.textColor = isSelected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        newWindowLabel?.textColor = isSelected ? NSColor.white.withAlphaComponent(0.92) : .labelColor
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
