import CoreGraphics
import Foundation
import Testing
@testable import LunchboxCore

/// Copy Diagnostics: what goes to support says enough to help, and nothing private.
@Suite struct SupportSummaryText {
    let summary = SupportSummary(
        app: "Lunchbox 1.0 (52), release build",
        system: "macOS 15.7.1 (24G231), Mac16,10",
        license: "free trial, 5 days left",
        settings: ["Accessibility: allowed", "tiling: on"],
        screens: [
            .init(name: "LG UltraFine", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                  visible: CGRect(x: 0, y: 25, width: 2560, height: 1415), scale: 2, isMain: true, tiled: true),
            .init(name: "AOC28E850.HDR", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                  visible: CGRect(x: -1920, y: 30, width: 1920, height: 1050), scale: 2, isMain: false, tiled: false),
        ],
        currentWorkspace: 1,
        workspaces: [
            .init(number: 1, tiles: [.init(display: "LG UltraFine", columns: [
                [.init(id: 101, app: "com.apple.Safari", state: "tiled", kind: .document, limits: SizeLimits(minWidth: 500, minHeight: 400))],
                [.init(id: 102, app: "com.apple.TextEdit", state: "tiled"),
                 .init(id: 103, app: "com.apple.Notes", state: "tiled", resizable: false)],
            ])]),
            .init(number: 2, tiles: []),
        ],
        untiled: [.init(id: 104, app: "com.apple.finder", state: "floats (panel or dialog)", kind: .panel)],
        errors: ["10-18 21:02:11 tiler: window 101 (com.apple.Safari) didn't move"]
    )

    @Test func saysWhatSupportNeeds() {
        let text = summary.text
        for part in ["Lunchbox 1.0 (52), release build", "macOS 15.7.1 (24G231), Mac16,10", "License: free trial, 5 days left",
                     "LG UltraFine (main): 2560×1440 at 0,0, @2x, usable 2560×1415 at 0,25",
                     "AOC28E850.HDR: 1920×1080 at -1920,0, @2x, usable 1920×1050 at -1920,30, not tiled",
                     "Workspaces: 2, current 1", "Workspace 1 (current)", "Workspace 2: no windows",
                     "column 1: 101 com.apple.Safari: tiled, document, min 500×400",
                     "column 2: 102 com.apple.TextEdit: tiled", "103 com.apple.Notes: tiled, fixed size",
                     "- 104 com.apple.finder: floats (panel or dialog), panel",
                     "Errors in the last day (1)", "didn't move"] {
            #expect(text.contains(part), "missing: \(part)")
        }
    }

    @Test func stackedWindowsLineUpUnderTheirColumn() throws {
        let lines = summary.text.split(separator: "\n").map(String.init)
        let top = try #require(lines.first { $0.contains("102 com.apple.TextEdit") })
        let below = try #require(lines.first { $0.contains("103 com.apple.Notes") })
        #expect(top.range(of: "102")?.lowerBound.utf16Offset(in: top) == below.range(of: "103")?.lowerBound.utf16Offset(in: below))
    }

    @Test func emptySectionsSayNone() {
        var empty = summary
        empty.untiled = []
        empty.errors = []
        #expect(empty.text.contains("Not in a tile (0)\n  none"))
        #expect(empty.text.contains("Errors in the last day (0)\n  none"))
    }

    @Test func limits() {
        #expect(SupportSummary.limitsText(SizeLimits(maxWidth: 430, maxHeight: 932)) == "max 430×932")
        #expect(SupportSummary.limitsText(SizeLimits(minWidth: 500)) == "min 500×–")
        #expect(SupportSummary.limitsText(.fixed(CGSize(width: 600, height: 400))) == "fixed 600×400")
        #expect(SupportSummary.limitsText(SizeLimits(minWidth: 320.5, maxHeight: 900)) == "min 320.5×–, max –×900")
    }
}

/// Log lines are scrubbed before they're shared.
@Suite struct SupportScrub {
    let home = "/Users/pat"

    @Test func fileAndFolderNamesInQuotesGo() {
        let line = "couldn't write the learning log: The file “Secret plans.json” couldn’t be saved in the folder “Lunchbox”."
        #expect(SupportSummary.scrub(line, home: home) == "couldn't write the learning log: The file “…” couldn’t be saved in the folder “…”.")
    }

    @Test func pathsGo() {
        #expect(SupportSummary.scrub("can't open /Users/pat/Documents/Taxes 2026.pdf now", home: home) == "can't open <path>")
        #expect(SupportSummary.scrub("saved to /Volumes/Master Storage/x.json; retrying", home: home) == "saved to <path>; retrying")
        #expect(SupportSummary.scrub("launch failed (/Applications/Thing.app)", home: home) == "launch failed (<path>)")
        #expect(SupportSummary.scrub("read ~/Library/Caches/x", home: home) == "read <path>")
        #expect(!SupportSummary.scrub("home is /Users/pat", home: home).contains("pat"))
    }

    @Test func linksEmailsAndLicensesGo() {
        let key = "lunchbox1.eyJwIjoidGVzc2VsIn0.c2lnbmF0dXJl"
        #expect(SupportSummary.scrub("opened lunchbox://activate?key=\(key)", home: home) == "opened <link>")
        #expect(SupportSummary.scrub("key \(key) didn't parse", home: home) == "key <license> didn't parse")
        #expect(SupportSummary.scrub("licensed to pat@example.com today", home: home) == "licensed to <email> today")
    }

    @Test func ordinaryLinesStay() {
        let line = "window 1234 (com.apple.Safari) didn't move to {{0, 25}, {1280, 1415}}; it's at {{0, 25}, {1270, 1415}}"
        #expect(SupportSummary.scrub(line, home: home) == line)
        #expect(SupportSummary.scrub("1/2 of the screen, and/or more", home: home) == "1/2 of the screen, and/or more")
    }

    @Test func longLinesAreCut() {
        let cut = SupportSummary.scrub(String(repeating: "a", count: 500), home: home)
        #expect(cut.count == 240)
        #expect(cut.hasSuffix("…"))
    }
}
