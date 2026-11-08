import CoreGraphics
import Testing
@testable import LunchboxCore

/// Summon's web searches open in the Workspace you're in: a tab in the browser's window here,
/// found by its corner where the browser reports bounds, or a new window.
@Suite struct BrowserScripts {
    let search = "https://www.google.com/search?q=desk%20lamp"

    @Test func aTabGoesIntoTheWindowHereFoundByItsCorner() {
        let script = BrowserScript.newTab(.chromium, bundleID: "com.google.Chrome", url: search, windowAt: CGPoint(x: 1288, y: 41))
        #expect(script.hasPrefix("tell application id \"com.google.Chrome\""))
        #expect(script.contains("set target to front window"))
        #expect(script.contains("(item 1 of b) > 1280 and (item 1 of b) < 1296 and (item 2 of b) > 33 and (item 2 of b) < 49"))
        #expect(script.contains("set target to contents of w"))
        #expect(script.contains("tell target to make new tab with properties {URL:\"\(search)\"}"))
        // The tab never goes to "front window" directly: only to the window found, or the one just focused.
        #expect(!script.contains("tell front window"))
        #expect(script.contains("set index of target to 1"))
        #expect(script.hasSuffix("  activate\nend tell"))
    }

    @Test func browsersWithoutBoundsUseTheWindowJustFocused() {
        // Arc has no window bounds: the search is in a try, so its front window (just focused) is used.
        let script = BrowserScript.newTab(.chromium, bundleID: "company.thebrowser.Browser", url: search, windowAt: CGPoint(x: 10, y: 40))
        let search = script.range(of: "try\n    repeat with w in windows")
        let tab = script.range(of: "tell target to make new tab")
        #expect(search != nil && tab != nil && search!.lowerBound < tab!.lowerBound)
    }

    @Test func safariSelectsTheNewTab() {
        let script = BrowserScript.newTab(.safari, bundleID: "com.apple.Safari", url: search, windowAt: CGPoint(x: 0, y: 25))
        #expect(script.contains("tell target to set current tab to (make new tab with properties {URL:\"\(search)\"})"))
        #expect(script.contains("bounds of w"))
    }

    @Test func noWindowHereMeansANewWindow() {
        let chrome = BrowserScript.newWindow(.chromium, bundleID: "com.google.Chrome", url: search)
        #expect(chrome.contains("make new window"))
        #expect(chrome.contains("set URL of active tab of front window to \"\(search)\""))
        let safari = BrowserScript.newWindow(.safari, bundleID: "com.apple.Safari", url: search)
        #expect(safari.contains("make new document with properties {URL:\"\(search)\"}"))
        #expect(!safari.contains("bounds"))
    }

    @Test func addressesAreQuotedSafely() {
        let script = BrowserScript.newWindow(.safari, bundleID: "com.apple.Safari", url: #"https://a.com/?q="x"\y"#)
        #expect(script.contains(#"{URL:"https://a.com/?q=\"x\"\\y"}"#))
    }
}
