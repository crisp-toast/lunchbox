// WindowLab: opens every kind of window Tessel has to handle, on command, and reports
// where each one is. For testing Tessel in a VM, never on a Mac someone is using.
//
//   scripts/windowlab/build.sh            builds build/WindowLab.app
//   windowlab <command>                   (scripts/windowlab/windowlab, a distributed notification)
//
// Commands:
//   normal                  a resizable document window
//   fixed:W:H               can't be resized, can be minimized (Calculator, a game)
//   min:W:H                 resizable, but not below W×H (1Password)
//   max:W:H                 resizable, but not above W×H
//   aspect:W:H              keeps its shape, starting at W×H (Simulator, a video)
//   about                   can't be resized or minimized (an About box)
//   alert                   an alert, shown without blocking (NSAlert's window)
//   panel                   a floating utility panel (an inspector)
//   pair                    two document windows at the same moment
//   littlearc               a window that animates itself to the middle after it opens (Little Arc)
//   resize:N:W:H            window number N (from report), or the newest of a kind (aspect…), resizes itself to W×H
//   device:W:H              the newest shape-keeping window switches to a W×H shape and size (Simulator: another device)
//   close:N  | closeall     closes one, or all
//   report:<path>           writes every window's title, number and frame (top-left origin) as JSON
import AppKit

final class Lab: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var count = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.tyleryouens.windowlab"), object: nil, queue: .main
        ) { [weak self] note in
            guard let command = note.object as? String else { return }
            self?.run(command)
        }
        if let first = CommandLine.arguments.dropFirst().first { run(first) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func make(_ kind: String, size: NSSize, style: NSWindow.StyleMask, panel: Bool = false) -> NSWindow {
        count += 1
        let rect = NSRect(origin: NSPoint(x: 120 + count * 24, y: 160 + count * 12), size: size)
        let w: NSWindow = panel
            ? NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        w.title = "lab-\(kind)-\(count)"
        w.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: w.title)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.frame = NSRect(x: 16, y: 16, width: 360, height: 26)
        w.contentView?.addSubview(label)
        windows.append(w)
        return w
    }

    let document: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    func run(_ command: String) {
        let parts = command.split(separator: ":").map(String.init)
        // Opening a window is something you do in the app in front; alerts and panels can come
        // from an app in the background.
        if !["alert", "panel", "report", "resize", "close", "closeall"].contains(parts.first ?? "") {
            NSApp.activate(ignoringOtherApps: true)
        }
        let n = parts.dropFirst().compactMap { Double($0) }
        switch parts.first ?? "" {
        case "normal":
            make("normal", size: NSSize(width: 700, height: 500), style: document).makeKeyAndOrderFront(nil)
        case "fixed" where n.count == 2:
            make("fixed", size: NSSize(width: n[0], height: n[1]), style: [.titled, .closable, .miniaturizable]).makeKeyAndOrderFront(nil)
        case "min" where n.count == 2:
            let w = make("min", size: NSSize(width: n[0], height: n[1]), style: document)
            w.contentMinSize = NSSize(width: n[0], height: n[1])
            w.makeKeyAndOrderFront(nil)
        case "max" where n.count == 2:
            let w = make("max", size: NSSize(width: n[0], height: n[1]), style: document)
            w.contentMaxSize = NSSize(width: n[0], height: n[1])
            w.makeKeyAndOrderFront(nil)
        case "aspect" where n.count == 2:
            let w = make("aspect", size: NSSize(width: n[0], height: n[1]), style: document)
            w.contentAspectRatio = NSSize(width: n[0], height: n[1])
            w.makeKeyAndOrderFront(nil)
        case "about":
            make("about", size: NSSize(width: 360, height: 220), style: [.titled, .closable]).makeKeyAndOrderFront(nil)
        case "alert":
            let alert = NSAlert()
            alert.messageText = "lab-alert"
            alert.informativeText = "Something needs your attention."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.layout()
            alert.window.title = "lab-alert-\(count)"
            windows.append(alert.window)
            alert.window.makeKeyAndOrderFront(nil)
        case "panel":
            let p = make("panel", size: NSSize(width: 260, height: 400), style: [.titled, .closable, .utilityWindow, .resizable], panel: true)
            (p as? NSPanel)?.isFloatingPanel = true
            p.orderFront(nil)
        case "pair":
            let a = make("pair", size: NSSize(width: 700, height: 500), style: document)
            let b = make("pair", size: NSSize(width: 700, height: 500), style: document)
            a.orderFront(nil); b.makeKeyAndOrderFront(nil)
        case "littlearc":
            let w = make("littlearc", size: NSSize(width: 842, height: 1100), style: document)
            w.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard let screen = w.screen ?? NSScreen.main else { return }
                let s = screen.visibleFrame
                let to = NSRect(x: s.midX - 421, y: s.midY - 550, width: 842, height: 1100).intersection(s)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    w.animator().setFrame(to, display: true)
                }
            }
        case "resize" where parts.count == 4:
            let which = parts[1]
            if let w = windows.first(where: { $0.windowNumber == Int(which) }) ?? windows.last(where: { $0.title.hasPrefix("lab-\(which)-") }),
               let width = Double(parts[2]), let height = Double(parts[3]) {
                let n = [0, width, height]
                var f = w.frame
                f.origin.y += f.height - n[2]
                f.size = NSSize(width: n[1], height: n[2])
                w.setFrame(f, display: true)
            }
        case "device" where n.count == 2:
            if let w = windows.last(where: { $0.title.hasPrefix("lab-aspect-") }) {
                w.contentAspectRatio = NSSize(width: n[0], height: n[1])
                var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: n[0], height: n[1])))
                f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
                w.setFrame(f, display: true)
            }
        case "close" where n.count == 1:
            windows.first { $0.windowNumber == Int(n[0]) }?.close()
        case "closeall":
            windows.forEach { $0.close() }
            windows.removeAll()
        case "report" where parts.count >= 2:
            let path = parts.dropFirst().joined(separator: ":")
            let top = NSScreen.screens.first?.frame.height ?? 0
            let list: [[String: Any]] = windows.filter(\.isVisible).map { w in
                let f = w.frame
                return ["title": w.title, "number": w.windowNumber,
                        "frame": [f.minX, top - f.maxY, f.width, f.height].map { Int($0.rounded()) },
                        "key": w.isKeyWindow]
            }
            let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: path))
        default:
            NSLog("windowlab: unknown command \(command)")
        }
    }
}

let app = NSApplication.shared
let lab = Lab()
app.delegate = lab
app.setActivationPolicy(.regular)
app.run()
