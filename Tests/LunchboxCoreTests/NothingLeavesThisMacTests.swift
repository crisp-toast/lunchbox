import Foundation
import Testing

/// Nothing leaves the Mac: the only code in LunchboxWM that opens a network connection itself
/// is the weekly license check. (Sparkle's update check
/// is set up in Info.plist, and Summon's web searches open in your browser.)
@Suite struct NothingLeavesThisMac {
    @Test func onlyTheLicenseCheckGoesOnline() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let networking = ["URLSession", "URLRequest", "NWConnection", "NWBrowser", "import Network",
                          "CFStream", "CFSocket", "socket(", "WebSocket", "URLConnection"]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if networking.contains(where: text.contains) {
                offenders.append(url.path.replacingOccurrences(of: sources.path + "/", with: ""))
            }
        }
        #expect(offenders == ["LunchboxWM/Licensing.swift"])
    }
}
