import AppKit

/// Opens web pages in a browser's own windows, the way you would by hand: as a
/// new tab in its window in the Workspace you're looking at, or in a new window
/// when it has none here. Handing a link over the usual way lets the browser
/// put it anywhere (Arc pops it up in a floating Little Arc window).
enum Browsers {
    private enum Dialect { case chromium, safari }

    /// Browsers whose AppleScript can make tabs and windows.
    private static let dialects: [String: Dialect] = [
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

    /// Asks the browser to show `url` in a new tab of its front window (`asTab`)
    /// or in a new window. Calls back on the main queue with false when it
    /// couldn't, for example when Automation access to the browser is turned off,
    /// so the caller can fall back to a plain open.
    static func open(_ url: URL, in bundleID: String, asTab: Bool, completion: @escaping (Bool) -> Void) {
        guard let dialect = dialects[bundleID] else { completion(false); return }
        let link = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body: String
        switch (dialect, asTab) {
        case (.chromium, true):
            body = "tell front window to make new tab with properties {URL:\"\(link)\"}"
        case (.chromium, false):
            // Chrome's new window has a blank tab to fill; Arc's has none yet, so add one.
            body = """
            make new window
              try
                set URL of active tab of front window to "\(link)"
              on error
                tell front window to make new tab with properties {URL:"\(link)"}
              end try
            """
        case (.safari, true):
            body = "tell front window to set current tab to (make new tab with properties {URL:\"\(link)\"})"
        case (.safari, false):
            body = "make new document with properties {URL:\"\(link)\"}"
        }
        let script = "tell application id \"\(bundleID)\"\n  \(body)\n  activate\nend tell"

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
