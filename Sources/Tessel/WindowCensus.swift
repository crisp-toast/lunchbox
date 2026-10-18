import AppKit
import os
import TesselCore

/// Reads `WindowTraits` over Accessibility, for the window classifier. Runs on an app's own
/// queue (or a background one), never the main thread.
enum WindowReader {
    private static let categories = OSAllocatedUnfairLock(initialState: [String: String?]())

    /// The app's LSApplicationCategoryType, read once per app.
    static func category(of bundleID: String) -> String? {
        if let known = categories.withLock({ $0[bundleID] }) { return known }
        let category = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        categories.withLock { $0[bundleID] = category }
        return category
    }

    /// The window server's level for a window: 0 for normal windows.
    static func layer(of id: CGWindowID) -> Int {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
        return (info?.first?[kCGWindowLayer as String] as? Int) ?? 0
    }

    static func traits(of element: AXUIElement, id: CGWindowID, bundleID: String, appName: String?, frame: CGRect,
                       screens: [CGRect], appWindows: Int) -> WindowTraits {
        var buttons: WindowButtons = []
        if element.element(kAXCloseButtonAttribute) != nil { buttons.insert(.close) }
        let minimize = element.element(kAXMinimizeButtonAttribute)
        if minimize != nil { buttons.insert(.minimize) }
        if element.element(kAXZoomButtonAttribute) != nil { buttons.insert(.zoom) }
        if element.element(kAXFullScreenButtonAttribute) != nil { buttons.insert(.fullScreen) }
        let children = element.elements(kAXChildrenAttribute).map { $0.role }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = screens.first { $0.contains(center) }
            ?? screens.max { $0.intersection(frame).size.area < $1.intersection(frame).size.area }
        let share = screen.map { frame.size.area / max(1, $0.size.area) } ?? 0.3
        return WindowTraits(
            app: bundleID, appName: appName, appCategory: category(of: bundleID),
            role: element.role, subrole: element.subrole, identifier: element.string(kAXIdentifierAttribute),
            title: element.string(kAXTitleAttribute), buttons: buttons, resizable: element.isResizable,
            minimizable: minimize.map { $0.bool(kAXEnabledAttribute) } ?? false,
            modal: element.bool(kAXModalAttribute),
            hasDefaultButton: element.element(kAXDefaultButtonAttribute) != nil,
            hasCancelButton: element.element(kAXCancelButtonAttribute) != nil,
            hasToolbar: children.contains("AXToolbar"), hasTabs: children.contains("AXTabGroup"),
            isDocument: element.value(kAXDocumentAttribute) != nil, isMain: element.bool(kAXMainAttribute),
            layer: layer(of: id), width: Double(frame.width), height: Double(frame.height),
            screenShare: (Double(share) * 1000).rounded() / 1000, appWindows: appWindows)
    }
}

/// `snapshot:<path>` writes every window of every app, as `WindowTraits` with titles, to a
/// JSON Lines file: how the labeled set the window classifier learns from is built, in the
/// test VMs. It's never run on its own, and Tessel never writes titles anywhere else.
enum WindowCensus {
    struct Record: Codable {
        var id: CGWindowID
        var traits: WindowTraits
        var minimized: Bool
        var fullScreen: Bool
        var onScreen: Bool
        var frame: [Double]
        var os: String
        var time: Double
    }

    static func write(to path: String, screens: [CGRect]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let onScreen = onScreenWindowIDs()
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            var lines: [String] = []
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited
                && app.processIdentifier != getpid() {
                let element = AXUIElement.application(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.5)
                let windows = element.elements(kAXWindowsAttribute)
                for window in windows {
                    guard let id = window.windowID, let frame = window.frame else { continue }
                    let traits = WindowReader.traits(of: window, id: id, bundleID: app.bundleIdentifier ?? "?",
                                                     appName: app.localizedName, frame: frame, screens: screens,
                                                     appWindows: windows.count)
                    let record = Record(id: id, traits: traits, minimized: window.isMinimized, fullScreen: window.isFullScreen,
                                        onScreen: onScreen.contains(id),
                                        frame: [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
                                        os: os, time: Date().timeIntervalSince1970)
                    if let data = try? encoder.encode(record) { lines.append(String(decoding: data, as: UTF8.self)) }
                }
            }
            let text = lines.joined(separator: "\n") + "\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
            }
            log.notice("wrote \(lines.count) windows to \(path, privacy: .public)")
        }
    }
}

private extension CGSize {
    var area: CGFloat { width * height }
}
