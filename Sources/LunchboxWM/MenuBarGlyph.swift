import AppKit

/// LunchboxWM's menu bar glyph: the app icon's lunchbox in black and white (a template image,
/// so macOS tints it for light and dark menu bars). The box is a rounded square like the icon's
/// squircle, and inside it are the three compartments in the icon's layout: a tall one on the left,
/// two stacked on the right. Every edge lands on the 2x pixel grid.
/// While tiling is paused the compartments are drawn hollow. While an update is out (`badge`), a
/// round gap is cut at the top right for the orange dot the menu bar item lays over it: the glyph
/// stays a template, so macOS still tints it, and only the dot is in color.
enum MenuBarGlyph {
    static let size: CGFloat = 16
    /// The orange dot, in the glyph's points from its top left.
    static let badge = NSRect(x: 10.5, y: 0, width: 5.5, height: 5.5)
    /// The clear ring around the dot.
    static let badgeGap: CGFloat = 1.25

    static func image(paused: Bool, badge: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            // The box.
            let box = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 12.5, height: 12.5), xRadius: 2.6, yRadius: 2.6)
            box.lineWidth = 1.5
            box.stroke()
            // Its compartments.
            let compartments = [NSRect(x: 3.5, y: 3.5, width: 4, height: 9),
                                NSRect(x: 8.5, y: 3.5, width: 4, height: 4),
                                NSRect(x: 8.5, y: 8.5, width: 4, height: 4)]
            for rect in compartments {
                if paused {
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 0.6, yRadius: 0.6)
                    path.lineWidth = 1
                    path.stroke()
                } else {
                    NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                }
            }
            if badge, let context = NSGraphicsContext.current?.cgContext {
                context.setBlendMode(.clear)
                context.fillEllipse(in: Self.badge.insetBy(dx: -badgeGap, dy: -badgeGap))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = (paused ? "Lunchbox (paused)" : "Lunchbox") + (badge ? ", update available" : "")
        return image
    }
}
