import CoreGraphics
import Foundation

/// How a window should behave, decided the moment it appears.
public enum WindowBehavior: String, Codable, CaseIterable, Sendable {
    /// A document or main window: it tiles.
    case document
    /// A tool window: an inspector, a palette, a settings or info window, a small companion
    /// window. It floats where it is.
    case panel
    /// Here and gone: a progress or copy window, a splash or welcome screen, a pop-up. Lunchbox
    /// leaves it alone and never shuffles the tiles for it.
    case transient
    /// Picture in Picture, a mini player, a call's floating window: it floats, and stays in
    /// view in every Workspace.
    case media
    /// Asking you something (an alert, a prompt, an Open or Save panel), even when it doesn't
    /// say so the usual way: it floats, centered.
    case dialog

    /// Whether Lunchbox tiles it.
    public var tiles: Bool { self == .document }
}

/// What Lunchbox can read about a window when it appears: its Accessibility role and buttons,
/// its window level and size, and its app. `title` is read for the decision and kept in memory
/// only; nothing Lunchbox writes down contains it.
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
    /// Its minimize button is there and enabled. Nil for windows read before Lunchbox noted it
    /// (2026-10-17); a minimize button being there stands in for it then.
    public var minimizable: Bool?
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
                minimizable: Bool? = nil, modal: Bool = false, hasDefaultButton: Bool = false, hasCancelButton: Bool = false,
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
        self.minimizable = minimizable
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
    /// Apps whose windows always float: overlays, not windows you work in. (Simulator,
    /// Calculator, System Settings and the like tile, at the size they take.) Lunchbox never even
    /// watches these two: the screenshot UI isn't a regular app, and Lunchbox is itself.
    public static let floatingApps: Set<String> = ["com.apple.screencaptureui", "com.sentientdonut.lunchbox"]

    /// What Lunchbox's hand-written rules do with a window, in the same terms, so the two can be
    /// compared:
    /// - a window of an app that always floats is left where it is;
    /// - a dialog floats, centered (`Dialogs.isDialog`); a "dialog" that resizes, has every
    ///   title-bar button and isn't asking anything (Little Arc) is a window;
    /// - so does a window that can be neither resized nor minimized (an About box);
    /// - any other window tiles, at its own size if it can't be resized (Calculator), unless
    ///   its app always floats;
    /// - everything else (a palette, a floating panel) floats where it is.
    public static func byRules(_ t: WindowTraits, floatingApps: Set<String>) -> WindowBehavior {
        if floatingApps.contains(t.app) { return .panel }
        let r = RulesReading(t)
        if r.centered { return .dialog }
        return r.tiles ? .document : .panel
    }

    /// What can never be learned, because Lunchbox never asks the classifier: a window the rules
    /// center (a dialog, an About box), and one that isn't window-like (no standard window's
    /// role, and not a resizable window with every title-bar button). Those get the rules.
    public static func hardRule(_ t: WindowTraits) -> WindowBehavior? {
        let r = RulesReading(t)
        if r.centered { return .dialog }
        return r.windowLike ? nil : .panel
    }
}

/// How `Tiler.readWindow` reads a window, from its traits. Keep the two in step.
struct RulesReading {
    /// It floats, centered: a dialog, or a window that can be neither resized nor minimized.
    let centered: Bool
    /// The rules tile it (at its own size, if it can't be resized).
    let tiles: Bool
    /// Lunchbox asks the classifier about it (`windowLike`).
    let windowLike: Bool

    init(_ t: WindowTraits) {
        let windowButtons = t.buttons.isSuperset(of: [.close, .minimize, .zoom])
        let dialogSubrole = t.subrole.map(Dialogs.subroles.contains) ?? false
        let dialog = Dialogs.isDialog(subrole: t.subrole, identifier: t.identifier, hasDefaultButton: t.hasDefaultButton,
                                      hasCancelButton: t.hasCancelButton, modal: t.modal,
                                      looksLikeWindow: dialogSubrole && t.resizable && windowButtons)
        let windowRole = t.role == "AXWindow" && (t.subrole == "AXStandardWindow" || (dialogSubrole && !dialog))
        let minimizable = t.resizable || (t.minimizable ?? t.buttons.contains(.minimize))
        let panel = windowRole && !minimizable
        centered = dialog || panel
        tiles = windowRole && !centered
        windowLike = !centered && (tiles || (t.resizable && t.role == "AXWindow" && windowButtons))
    }
}
