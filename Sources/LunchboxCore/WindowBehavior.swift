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
}
