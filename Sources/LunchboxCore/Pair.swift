import CoreGraphics

/// Two windows can sit as a centered pair smaller than the screen. Drag an outer edge (a top, a
/// bottom, or the far side of either window) and both resize together, staying centered and
/// touching, the way a lone window resizes around the middle. The edge between them still moves
/// the split.
extension Layout {
    public struct Pair: Codable, Equatable, Sendable {
        /// The pair's width and height, as fractions of the usable area.
        public var width: Double
        public var height: Double
        /// The two windows it's for: any other pair fills the screen.
        public var windows: Set<WindowID>
    }

    /// The smallest a pair gets, as a fraction of the screen each way.
    public static let pairSmallest = 0.3

    /// Two windows side by side (two columns of one) or stacked (one column of two), not in Focus.
    public var isPair: Bool { windowCount == 2 && spotlight == nil }

    /// Side by side (true) or stacked (false).
    public var pairSideBySide: Bool { columns.count == 2 }

    /// Where a pair sits within `usable` (the screen less its margins): all of it, or the centered
    /// size it was dragged to. Anything else has all of it.
    func pairArea(_ usable: CGRect) -> CGRect {
        guard isPair, let pair, pair.windows == Set(windows) else { return usable }
        let w = (usable.width * CGFloat(pair.width)).rounded(), h = (usable.height * CGFloat(pair.height)).rounded()
        return CGRect(x: (usable.midX - w / 2).rounded(), y: (usable.midY - h / 2).rounded(), width: w, height: h)
    }

    /// One window of a pair is being resized: given its frame now and before (`target`), the
    /// pair's area (centered on the screen, the windows touching) and the other window's frame.
    /// Nil when only the edge between them moved (that's the split) or it isn't a pair.
    public func pairResize(_ id: WindowID, dragged frame: CGRect, target: CGRect, in rect: CGRect, gap: CGFloat)
        -> (area: CGRect, other: WindowID, otherFrame: CGRect)? {
        guard isPair, let other = windows.first(where: { $0 != id }), let (c, r) = position(of: id) else { return nil }
        let usable = Self.usable(rect, gap: gap)
        let current = pairArea(usable)
        let sideBySide = pairSideBySide
        let first = sideBySide ? c == 0 : r == 0 // the left (or top) window
        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 2 }
        // Along the pair: its far edge. Across it: either edge (both move together with ⌥).
        let outer = sideBySide ? moved(first ? frame.minX : frame.maxX, first ? target.minX : target.maxX)
            : moved(first ? frame.minY : frame.maxY, first ? target.minY : target.maxY)
        let across = sideBySide ? moved(frame.minY, target.minY) || moved(frame.maxY, target.maxY)
            : moved(frame.minX, target.minX) || moved(frame.maxX, target.maxX)
        guard outer || across else { return nil }

        var area = current
        if sideBySide {
            if outer {
                let edge = first ? max(usable.minX, frame.minX) : min(usable.maxX, frame.maxX)
                let half = abs(usable.midX - edge)
                area.origin.x = usable.midX - half
                area.size.width = 2 * half
            }
            if across {
                area.origin.y = max(usable.minY, frame.minY)
                area.size.height = min(usable.maxY, frame.maxY) - area.minY
            }
            let otherFrame = first
                ? CGRect(x: frame.maxX + gap, y: area.minY, width: area.maxX - (frame.maxX + gap), height: area.height)
                : CGRect(x: area.minX, y: area.minY, width: frame.minX - gap - area.minX, height: area.height)
            return (area, other, otherFrame)
        }
        if outer {
            let edge = first ? max(usable.minY, frame.minY) : min(usable.maxY, frame.maxY)
            let half = abs(usable.midY - edge)
            area.origin.y = usable.midY - half
            area.size.height = 2 * half
        }
        if across {
            area.origin.x = max(usable.minX, frame.minX)
            area.size.width = min(usable.maxX, frame.maxX) - area.minX
        }
        let otherFrame = first
            ? CGRect(x: area.minX, y: frame.maxY + gap, width: area.width, height: area.maxY - (frame.maxY + gap))
            : CGRect(x: area.minX, y: area.minY, width: area.width, height: frame.minY - gap - area.minY)
        return (area, other, otherFrame)
    }

    /// You let go of a pair's outer edge: the pair keeps that size, centered, and the split it had
    /// as you dragged. Returns false when only the split moved (see `adopt`) or it isn't a pair.
    @discardableResult
    public mutating func adoptPair(_ id: WindowID, dragged frame: CGRect, target: CGRect, in rect: CGRect, gap: CGFloat) -> Bool {
        guard let resized = pairResize(id, dragged: frame, target: target, in: rect, gap: gap),
              let (c, r) = position(of: id) else { return false }
        let usable = Self.usable(rect, gap: gap)
        let width = min(1, max(Self.pairSmallest, Double(resized.area.width / max(1, usable.width))))
        let height = min(1, max(Self.pairSmallest, Double(resized.area.height / max(1, usable.height))))
        pair = width >= 0.995 && height >= 0.995 ? nil : Pair(width: width, height: height, windows: Set(windows))
        // The split: the dragged window's share of the pair.
        if pairSideBySide {
            var widths = columns.map(\.weight)
            let avail = Double(resized.area.width - gap)
            if Self.adjust(&widths, index: c, delta: Double(frame.width) / max(1, avail) - widths[c] / widths.reduce(0, +)) {
                for i in columns.indices { columns[i].weight = widths[i] }
            }
        } else {
            let weights = columns[c].weights
            let avail = Double(resized.area.height - gap)
            _ = Self.adjust(&columns[c].weights, index: r, delta: Double(frame.height) / max(1, avail) - weights[r] / weights.reduce(0, +))
        }
        return true
    }

    /// The screen less its margins, as `frames` measures it.
    static func usable(_ rect: CGRect, gap: CGFloat) -> CGRect {
        CGRect(x: (rect.minX + gap).rounded(), y: (rect.minY + gap).rounded(),
               width: (rect.width - 2 * gap).rounded(), height: (rect.height - 2 * gap).rounded())
    }
}
