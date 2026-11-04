import Foundation

/// How a window should behave, decided the moment it appears.
public enum WindowBehavior: String, Codable, CaseIterable, Sendable {
    /// A document or main window: it tiles.
    case document
    /// A tool window: an inspector, a palette, a settings or info window, a small companion
    /// window. It floats where it is.
    case panel
    /// Here and gone: a progress or copy window, a splash or welcome screen, a pop-up. LunchboxWM
    /// leaves it alone and never shuffles the tiles for it.
    case transient
    /// Picture in Picture, a mini player, a call's floating window: it floats, and stays in
    /// view in every Workspace.
    case media
    /// Asking you something (an alert, a prompt, an Open or Save panel), even when it doesn't
    /// say so the usual way: it floats, centered.
    case dialog

    /// Whether LunchboxWM tiles it.
    public var tiles: Bool { self == .document }
}

extension WindowBehavior {
    /// Apps whose windows always float: overlays, not windows you work in. (Simulator,
    /// Calculator, System Settings and the like tile, at the size they take.) LunchboxWM never even
    /// watches these two: the screenshot UI isn't a regular app, and LunchboxWM is itself.
    public static let floatingApps: Set<String> = ["com.apple.screencaptureui", "com.sentientdonut.lunchbox"]

    /// Whether an app, by its Info.plist, is an iPad-style app: Mac Catalyst (Messages, Find My,
    /// Home, Stocks, Weather) or an iPad app on a Mac with Apple silicon. Those say which devices
    /// they're for (`UIDeviceFamily`); a Mac app made with AppKit never does.
    ///
    /// Their windows animate to every frame they're asked for, over about a quarter of a second,
    /// and a second ask while one is on its way starts from where the window is shown right then:
    /// a size sent right after a position puts the window back where it was (held to the screen
    /// from there, so it comes out short), and a position sent right after a size drops the size.
    /// So LunchboxWM places them one step at a time, each shown before the next is sent.
    public static func animatesItsOwnFrames(infoPlist: [String: Any]) -> Bool {
        infoPlist["UIDeviceFamily"] != nil
    }
}
