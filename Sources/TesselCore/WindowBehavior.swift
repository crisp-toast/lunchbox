import CoreGraphics
import Foundation

/// How a window should behave, decided the moment it appears.
public enum WindowBehavior: String, Codable, CaseIterable, Sendable {
    /// A document or main window: it tiles.
    case document
    /// A tool window: an inspector, a palette, a settings or info window, a small companion
    /// window. It floats where it is.
    case panel
    /// Here and gone: a progress or copy window, a splash or welcome screen, a pop-up. Tessel
    /// leaves it alone and never shuffles the tiles for it.
    case transient
    /// Picture in Picture, a mini player, a call's floating window: it floats, and stays in
    /// view in every Workspace.
    case media
    /// Asking you something (an alert, a prompt, an Open or Save panel), even when it doesn't
    /// say so the usual way: it floats, centered.
    case dialog

    /// Whether Tessel tiles it.
    public var tiles: Bool { self == .document }
}

/// What Tessel can read about a window when it appears: its Accessibility role and buttons,
/// its window level and size, and its app. `title` is read for the decision and kept in memory
/// only; nothing Tessel writes down contains it.
public struct WindowTraits: Codable, Equatable, Sendable {
    public var app: String
    public var appName: String?
    /// The app's LSApplicationCategoryType, like "public.app-category.video".
    public var appCategory: String?
    public var role: String?
    public var subrole: String?
    /// AXIdentifier, like "open-panel".
    public var identifier: String?
    public var title: String?
    public var buttons: WindowButtons
    public var resizable: Bool
    public var modal: Bool
    public var hasDefaultButton: Bool
    public var hasCancelButton: Bool
    public var hasToolbar: Bool
    public var hasTabs: Bool
    /// It shows a file (AXDocument).
    public var isDocument: Bool
    /// The app calls it its main window (AXMain).
    public var isMain: Bool
    /// The window server's level: 0 for normal windows, 3 for floating panels, higher for
    /// things that float over everything.
    public var layer: Int
    public var width: Double
    public var height: Double
    /// Its area as a share of the usable area of its display.
    public var screenShare: Double
    /// How many windows its app has.
    public var appWindows: Int

    public init(app: String, appName: String? = nil, appCategory: String? = nil, role: String? = "AXWindow",
                subrole: String? = "AXStandardWindow", identifier: String? = nil, title: String? = nil,
                buttons: WindowButtons = [.close, .minimize, .zoom, .fullScreen], resizable: Bool = true,
                modal: Bool = false, hasDefaultButton: Bool = false, hasCancelButton: Bool = false,
                hasToolbar: Bool = false, hasTabs: Bool = false, isDocument: Bool = false, isMain: Bool = false,
                layer: Int = 0, width: Double = 900, height: Double = 600, screenShare: Double = 0.3, appWindows: Int = 1) {
        self.app = app
        self.appName = appName
        self.appCategory = appCategory
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.buttons = buttons
        self.resizable = resizable
        self.modal = modal
        self.hasDefaultButton = hasDefaultButton
        self.hasCancelButton = hasCancelButton
        self.hasToolbar = hasToolbar
        self.hasTabs = hasTabs
        self.isDocument = isDocument
        self.isMain = isMain
        self.layer = layer
        self.width = width
        self.height = height
        self.screenShare = screenShare
        self.appWindows = appWindows
    }

    /// The same window with its title left out, for anything that's kept.
    public var withoutTitle: WindowTraits {
        var copy = self
        copy.title = nil
        return copy
    }
}

// MARK: Today's rules, as behaviors

extension WindowBehavior {
    /// What Tessel's hand-written rules do with a window, in the same terms, so the two can be
    /// compared: dialogs center (`Dialogs.isDialog`), standard resizable windows tile unless
    /// their app always floats, and everything else floats (a panel, as far as the rules know).
    public static func byRules(_ t: WindowTraits, floatingApps: Set<String>) -> WindowBehavior {
        if Dialogs.isDialog(subrole: t.subrole, identifier: t.identifier, hasDefaultButton: t.hasDefaultButton,
                            hasCancelButton: t.hasCancelButton, modal: t.modal) { return .dialog }
        let standard = t.role == "AXWindow" && t.subrole == "AXStandardWindow"
        if standard, t.resizable, !floatingApps.contains(t.app) { return .document }
        return .panel
    }

    /// What can never be learned: a window the rules call a dialog, or one that can't be
    /// resized, never tiles; a dialog is always centered.
    public static func hardRule(_ t: WindowTraits) -> WindowBehavior? {
        if Dialogs.isDialog(subrole: t.subrole, identifier: t.identifier, hasDefaultButton: t.hasDefaultButton,
                            hasCancelButton: t.hasCancelButton, modal: t.modal) { return .dialog }
        return nil
    }
}
