import AppKit
import LunchboxCore

/// Opens web pages in a browser's own windows, the way you would by hand: as a
/// new tab in its window in the Workspace you're looking at, or in a new window
/// when it has none here. Handing a link over the usual way lets the browser
/// put it anywhere (Arc pops it up in a floating Little Arc window).
enum Browsers {
    /// Browsers whose AppleScript can make tabs and windows.
    private static let dialects: [String: BrowserScript.Dialect] = [
        "company.thebrowser.Browser": .chromium, // Arc
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
    ]

    static func canScript(_ bundleID: String) -> Bool { dialects[bundleID] != nil }

    /// Asks the browser to show `url` in a new tab of its window at `windowAt` (its window in
    /// this Workspace, just focused), or in a new window when that's nil. Calls back on the main
    /// queue with false when it couldn't, for example when Automation access to the browser is
    /// turned off, so the caller can open it another way.
    static func open(_ url: URL, in bundleID: String, windowAt origin: CGPoint?, completion: @escaping (Bool) -> Void) {
        guard let dialect = dialects[bundleID] else { completion(false); return }
        let script = origin != nil
            ? BrowserScript.newTab(dialect, bundleID: bundleID, url: url.absoluteString, windowAt: origin)
            : BrowserScript.newWindow(dialect, bundleID: bundleID, url: url.absoluteString)

        // osascript runs off the main thread: the first time, macOS asks whether
        // LunchboxWM may control the browser and the call waits for that answer.
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            var ok = false
            do {
                try process.run()
                process.waitUntilExit()
                ok = process.terminationStatus == 0
            } catch {}
            if !ok {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log.error("browser script for \(bundleID, privacy: .public) failed: \(message, privacy: .public)")
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
