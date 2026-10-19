import AppKit
import LunchboxCore

/// Settings › What Lunchbox Learned › How Lunchbox Sees Your Windows: every window open right now,
/// what the window classifier makes of it, how sure it is, and what the hand-written rules would
/// have done. Titles are shown here and kept nowhere.
final class WindowClassesWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var id: CGWindowID
        var app: String
        var appID: String
        var title: String
        var behavior: WindowBehavior
        var confidence: Double
        var rules: WindowBehavior
        var byModel: Bool
    }

    struct Survey {
        var rows: [Row]
        /// Milliseconds spent reading every window over Accessibility, and deciding.
        var readMs: Double
        var decideMs: Double
    }

    /// Reads and classifies every window of every app Lunchbox tiles. Off the main thread.
    static func survey(screens: [CGRect]) -> Survey {
        var rows: [Row] = []
        var read = 0.0, decide = 0.0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            guard let bundleID = app.bundleIdentifier else { continue }
            let element = AXUIElement.application(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            let windows = element.elements(kAXWindowsAttribute)
            for window in windows where !window.isMinimized {
                guard let id = window.windowID, let frame = window.frame else { continue }
                var started = CACurrentMediaTime()
                let traits = WindowReader.traits(of: window, id: id, bundleID: bundleID, appName: app.localizedName,
                                                 frame: frame, screens: screens, appWindows: windows.count)
                read += CACurrentMediaTime() - started
                started = CACurrentMediaTime()
                let meaning = TitleMeaning.shared.vector(traits.title)
                let verdict = BehaviorDecision.decide(traits, model: Learning.model, meaning: meaning, floatingApps: Tiler.floatingApps)
                decide += CACurrentMediaTime() - started
                rows.append(Row(id: id, app: app.localizedName ?? bundleID, appID: bundleID, title: traits.title ?? "",
                                behavior: verdict.behavior, confidence: verdict.confidence,
                                rules: WindowBehavior.byRules(traits, floatingApps: Tiler.floatingApps), byModel: verdict.byModel))
            }
        }
        rows.sort { ($0.byModel ? 0 : 1, $0.app.lowercased(), $0.id) < ($1.byModel ? 0 : 1, $1.app.lowercased(), $1.id) }
        return Survey(rows: rows, readMs: read * 1000, decideMs: decide * 1000)
    }

    private var window: NSWindow?
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private var rows: [Row] = []

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc func refresh() {
        let screens = Display.current().map(\.visible)
        footer.stringValue = "Looking…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let survey = Self.survey(screens: screens)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rows = survey.rows
                self.table.reloadData()
                let differ = survey.rows.filter(\.byModel).count
                let n = max(1, survey.rows.count)
                self.footer.stringValue = String(
                    format: "%d windows, %d where Lunchbox goes against the old rules (listed first). Reading them took %.1f ms a window; deciding, %.3f ms a window. %@",
                    survey.rows.count, differ, survey.readMs / Double(n), survey.decideMs / Double(n),
                    Learning.model.map { "The model learned from \($0.trainedOn) windows of test apps; never from yours." } ?? "")
            }
        }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 480), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "How Lunchbox Sees Your Windows"
        w.isReleasedWhenClosed = false
        let columns: [(String, String, CGFloat)] = [("app", "App", 140), ("title", "Window", 280), ("lunchbox", "Lunchbox", 110),
                                                    ("sure", "Sure", 60), ("rules", "Old rules", 110), ("does", "So it", 120)]
        for (id, name, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = name
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let refresh = NSButton(title: "Look Again", target: self, action: #selector(refresh))
        footer.lineBreakMode = .byWordWrapping
        footer.maximumNumberOfLines = 3
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        let bottom = NSStackView(views: [footer, refresh])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        let stack = NSStackView(views: [scroll, bottom])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        w.contentView = content
        w.center()
        window = w
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let text: String
        switch column?.identifier.rawValue {
        case "app": text = r.app
        case "title": text = r.title.isEmpty ? "(no title)" : r.title
        case "lunchbox": text = (r.byModel ? "◆ " : "") + Self.name(r.behavior)
        case "sure": text = String(format: "%.0f%%", r.confidence * 100)
        case "rules": text = Self.name(r.rules)
        default: text = Self.does(r.behavior)
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if r.byModel, column?.identifier.rawValue == "lunchbox" { label.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return label
    }

    static func name(_ b: WindowBehavior) -> String {
        switch b {
        case .document: return "Document"
        case .panel: return "Tool panel"
        case .transient: return "Here and gone"
        case .media: return "Video or call"
        case .dialog: return "Asking you"
        }
    }

    static func does(_ b: WindowBehavior) -> String {
        switch b {
        case .document: return "tiles"
        case .panel, .transient: return "floats"
        case .media: return "floats, every Workspace"
        case .dialog: return "floats, centered"
        }
    }
}
