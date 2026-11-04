import Foundation
import Testing
@testable import LunchboxCore

/// Messages opened short, shook, and grew a little each time it was opened (2026-11-03): an
/// iPad-style app animates its window to every frame it's asked for, so LunchboxWM has to know
/// which apps those are and place their windows one step at a time.
@Suite struct IPadStyleApps {
    /// The keys that matter, as macOS 27 ships them.
    @Test func catalystAppsSayWhichDevicesTheyreFor() {
        let messages: [String: Any] = ["CFBundleIdentifier": "com.apple.MobileSMS", "DTPlatformName": "macosx",
                                       "UIDeviceFamily": [2, 6], "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": true]]
        let findMy: [String: Any] = ["CFBundleIdentifier": "com.apple.findmy", "DTPlatformName": "macosx", "UIDeviceFamily": [2, 6]]
        #expect(WindowBehavior.animatesItsOwnFrames(infoPlist: messages))
        #expect(WindowBehavior.animatesItsOwnFrames(infoPlist: findMy))
    }

    @Test func anIPadAppOnAMacToo() {
        let ipad: [String: Any] = ["CFBundleIdentifier": "com.example.game", "DTPlatformName": "iphoneos", "UIDeviceFamily": [1, 2]]
        #expect(WindowBehavior.animatesItsOwnFrames(infoPlist: ipad))
    }

    @Test func macAppsDont() {
        let notes: [String: Any] = ["CFBundleIdentifier": "com.apple.Notes", "DTPlatformName": "macosx", "NSPrincipalClass": "NSApplication"]
        let mail: [String: Any] = ["CFBundleIdentifier": "com.apple.mail", "DTPlatformName": "macosx"]
        #expect(!WindowBehavior.animatesItsOwnFrames(infoPlist: notes))
        #expect(!WindowBehavior.animatesItsOwnFrames(infoPlist: mail))
        #expect(!WindowBehavior.animatesItsOwnFrames(infoPlist: [:]))
    }

    /// The apps on this Mac, read the way LunchboxWM reads them, where they're installed.
    @Test func theAppsOnThisMac() {
        func plist(_ app: String) -> [String: Any]? {
            NSDictionary(contentsOfFile: "/System/Applications/\(app).app/Contents/Info.plist") as? [String: Any]
        }
        for app in ["Messages", "FindMy", "Home", "Stocks", "Weather"] {
            guard let info = plist(app) else { continue }
            #expect(WindowBehavior.animatesItsOwnFrames(infoPlist: info), "\(app)")
        }
        for app in ["Notes", "Mail", "TextEdit", "Calendar"] {
            guard let info = plist(app) ?? (NSDictionary(contentsOfFile: "/System/Applications/Utilities/\(app).app/Contents/Info.plist") as? [String: Any])
            else { continue }
            #expect(!WindowBehavior.animatesItsOwnFrames(infoPlist: info), "\(app)")
        }
    }
}
