import AppKit

/// Tessel's menu bar glyph: the app icon's tiles in black and white (a template
/// image, so macOS tints it for light and dark menu bars). The tall tile, the
/// focused tile with its ring, and the third tile faded, as on the icon. While
/// tiling is paused the tiles are drawn hollow.
enum MenuBarGlyph {
    static func image(paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 16), flipped: true) { _ in
            // The icon's tile layout (a 508-point square starting at 258) scaled to 14 points.
            let k: CGFloat = 14 / 508, ox: CGFloat = 1.5, oy: CGFloat = 1
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: ox + (x - 258) * k, y: oy + (y - 258) * k, width: w * k, height: h * k)
            }
            let radius: CGFloat = 1.6
            let tall = NSBezierPath(roundedRect: r(258, 258, 232, 508), xRadius: radius, yRadius: radius)
            let top = NSBezierPath(roundedRect: r(534, 258, 232, 232).insetBy(dx: 0.9, dy: 0.9), xRadius: radius - 0.5, yRadius: radius - 0.5)
            let bottom = NSBezierPath(roundedRect: r(534, 534, 232, 232), xRadius: radius, yRadius: radius)
            let ring = NSBezierPath(roundedRect: r(534, 258, 232, 232).insetBy(dx: -0.35, dy: -0.35), xRadius: radius + 0.4, yRadius: radius + 0.4)
            ring.lineWidth = 1
            NSColor.black.setStroke()
            if paused {
                for path in [tall, top, bottom] { path.lineWidth = 1; path.setLineDash([1.6, 1.2], count: 2, phase: 0) }
                tall.stroke(); bottom.stroke(); ring.stroke()
            } else {
                NSColor.black.setFill()
                tall.fill()
                top.fill()
                ring.stroke()
                NSColor.black.withAlphaComponent(0.45).setFill()
                bottom.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "Tessel (paused)" : "Tessel"
        return image
    }
}
