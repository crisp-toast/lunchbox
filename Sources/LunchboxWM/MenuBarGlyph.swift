import AppKit

/// LunchboxWM's menu bar glyph: the app icon's lunchbox in black and white (a template image,
/// so macOS tints it for light and dark menu bars). The box with its handle, and inside it the
/// three compartments in the icon's layout: a tall one on the left, two stacked on the right.
/// While tiling is paused the compartments are drawn hollow.
enum MenuBarGlyph {
    static func image(paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            // The handle: a rounded loop on the lid.
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 6.1, y: 4.2))
            handle.line(to: NSPoint(x: 6.1, y: 2.6))
            handle.appendArc(withCenter: NSPoint(x: 7.4, y: 2.6), radius: 1.3, startAngle: 180, endAngle: 270, clockwise: false)
            handle.line(to: NSPoint(x: 9.6, y: 1.3))
            handle.appendArc(withCenter: NSPoint(x: 9.6, y: 2.6), radius: 1.3, startAngle: 270, endAngle: 0, clockwise: false)
            handle.line(to: NSPoint(x: 10.9, y: 4.2))
            handle.lineWidth = 1.3
            handle.lineCapStyle = .round
            handle.stroke()
            // The box.
            let box = NSBezierPath(roundedRect: NSRect(x: 1.15, y: 4.15, width: 14.7, height: 10.7), xRadius: 2.4, yRadius: 2.4)
            box.lineWidth = 1.3
            box.stroke()
            // Its compartments.
            let compartments = [NSRect(x: 3.2, y: 6.2, width: 4.6, height: 6.6),
                                NSRect(x: 9.2, y: 6.2, width: 4.6, height: 2.8),
                                NSRect(x: 9.2, y: 10.0, width: 4.6, height: 2.8)]
            for rect in compartments {
                if paused {
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), xRadius: 0.8, yRadius: 0.8)
                    path.lineWidth = 0.8
                    path.stroke()
                } else {
                    NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "LunchboxWM (paused)" : "LunchboxWM"
        return image
    }
}
