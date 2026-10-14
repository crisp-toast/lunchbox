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

    enum Result {
        case open(App)
        case goTo(App, NSRunningApplication)
        case newWindow(App, NSRunningApplication)
        case file(URL)

        var path: String {
            switch self {
            case .open(let a), .goTo(let a, _), .newWindow(let a, _): return a.url.path
            case .file(let url): return url.path
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
    private var fileQuery: NSMetadataQuery?
    private var fileSearch: DispatchWorkItem?
    private var icons: [String: NSImage] = [:]

    private static let width: CGFloat = 640
    private static let fieldHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let maxRows = 8

    init(tiler: Tiler) {
        self.tiler = tiler
        super.init()
        reloadApps()
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
    func openSelection() { if results.indices.contains(selected) { open(results[selected]) } }
    var stateDescription: [String: Any] {
        ["visible": isVisible, "query": field.stringValue, "selected": selected,
         "results": results.map { describe($0).title + " | " + describe($0).subtitle }]
    }

    // MARK: Apps

    private func reloadApps() {
        appsLoadedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.scanApplications()
            DispatchQueue.main.async { self?.apps = found }
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

        var list: [Result] = []
        for app in ranked {
            guard list.count < Self.maxRows else { break }
            if let running = runningApp(app) {
                list.append(.goTo(app, running))
                if list.count < Self.maxRows { list.append(.newWindow(app, running)) }
            } else {
                list.append(.open(app))
            }
        }
        results = list
        selected = 0
        render()

        if list.isEmpty, !query.isEmpty {
            let work = DispatchWorkItem { [weak self] in self?.searchFiles(query) }
            fileSearch = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
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
        results = files
        selected = 0
        render()
    }

    // MARK: Opening

    private func open(_ result: Result) {
        hide()
        var uses = UserDefaults.standard.dictionary(forKey: "launcherUses") as? [String: Int] ?? [:]
        uses[result.path, default: 0] += 1
        UserDefaults.standard.set(uses, forKey: "launcherUses")

        switch result {
        case .open(let app):
            launch(app)
        case .goTo(let app, let running):
            if !tiler.goToWindow(ofApp: running.processIdentifier) { launch(app) }
        case .newWindow(let app, let running):
            tiler.openNewWindow(ofApp: running.processIdentifier) { [weak self] opened in
                if !opened { self?.launch(app) }
            }
        case .file(let url):
            NSWorkspace.shared.open(url)
        }
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
        case #selector(NSResponder.insertNewline(_:)): openSelection()
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
        Self.fieldHeight + (results.isEmpty ? 0 : CGFloat(results.count) * Self.rowHeight + 12)
    }

    private func describe(_ result: Result) -> (title: String, subtitle: String, icon: String) {
        switch result {
        case .open(let app): return (app.name, "Open", app.url.path)
        case .goTo(let app, _): return (app.name, "Already open · go to its window", app.url.path)
        case .newWindow(let app, _): return ("New \(app.name) window", "Opens next to your other windows", app.url.path)
        case .file(let url):
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return (url.lastPathComponent, folder, url.path)
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
            let row = ResultRow(title: d.title, subtitle: d.subtitle, icon: icon(for: d.icon))
            row.isSelected = i == selected
            row.onClick = { [weak self] in
                guard let self, self.results.indices.contains(i) else { return }
                self.open(self.results[i])
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

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.placeholderString = "Open an app or file"
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

private final class ResultRow: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { refresh() } }
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    init(title text: String, subtitle detail: String, icon: NSImage) {
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
        for v in [iconView, title, subtitle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            widthAnchor.constraint(equalToConstant: 628),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        title.textColor = isSelected ? .white : .labelColor
        subtitle.textColor = isSelected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
