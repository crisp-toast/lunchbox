import AppKit

/// A connected display, with frames in top-left-origin screen coordinates
/// (the space the Accessibility API uses).
struct Display: Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    /// The whole display.
    let frame: CGRect
    /// The part windows may use: below the menu bar, beside the Dock.
    let visible: CGRect
    let isMain: Bool

    static func current() -> [Display] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        func flip(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            } ?? "display-\(id)"
            return Display(
                id: id, uuid: uuid, name: screen.localizedName,
                frame: flip(screen.frame), visible: flip(screen.visibleFrame),
                isMain: screen == primary
            )
        }
    }

    /// Where windows in other spaces wait: just past the bottom-right corner of
    /// the right-most display, so only a sliver could ever show.
    static func hidingSpot(in displays: [Display]) -> CGPoint {
        guard let d = displays.max(by: { ($0.frame.maxX, $0.frame.maxY) < ($1.frame.maxX, $1.frame.maxY) }) else {
            return CGPoint(x: 10_000, y: 10_000)
        }
        return CGPoint(x: d.frame.maxX - 1, y: d.frame.maxY - 1)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

extension CGSize {
    func isClose(to other: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

extension NSScreen {
    /// Converts a top-left-origin point to AppKit's bottom-left-origin space.
    static func cocoaPoint(fromTopLeft p: CGPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    static func topLeftPoint(fromCocoa p: CGPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }
}
