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
    /// pair's area (centered on the screen) and the other window's frame: the mirror image of the
    /// dragged one across the middle of the screen, the same width and height, so the two stay
    /// identical. Never smaller than either window's minimum (`limits`). Nil when only the edge
    /// between them moved (that's the split) or it isn't a pair.
    public func pairResize(_ id: WindowID, dragged frame: CGRect, target: CGRect, in rect: CGRect, gap: CGFloat,
                           limits: [WindowID: SizeLimits] = [:]) -> (area: CGRect, other: WindowID, otherFrame: CGRect)? {
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

        // Never smaller than both windows side by side (or stacked) at their minimums.
        let minWidth = windows.compactMap { limits[$0]?.minWidth }.max() ?? 0
        let minHeight = windows.compactMap { limits[$0]?.minHeight }.max() ?? 0
        let smallest = sideBySide ? CGSize(width: 2 * minWidth + gap, height: minHeight)
            : CGSize(width: minWidth, height: 2 * minHeight + gap)
        var area = current
        // The span along the pair, from its far edge: centered on the screen.
        if outer {
            let edge = sideBySide ? (first ? max(usable.minX, frame.minX) : min(usable.maxX, frame.maxX))
                : (first ? max(usable.minY, frame.minY) : min(usable.maxY, frame.maxY))
            let center = sideBySide ? usable.midX : usable.midY
            let span = max(sideBySide ? smallest.width : smallest.height, 2 * abs(center - edge))
            if sideBySide { area.origin.x = center - span / 2; area.size.width = span }
            else { area.origin.y = center - span / 2; area.size.height = span }
        }
        // The span across it, from the dragged window's own (with ⌥, already around the middle).
        if across {
            if sideBySide {
                let height = max(smallest.height, min(usable.maxY, frame.maxY) - max(usable.minY, frame.minY))
                area.origin.y = usable.midY - height / 2
                area.size.height = height
            } else {
                let width = max(smallest.width, min(usable.maxX, frame.maxX) - max(usable.minX, frame.minX))
                area.origin.x = usable.midX - width / 2
                area.size.width = width
            }
        }
        // The other window: the dragged one's mirror image across the middle, the same size.
        let otherFrame = sideBySide
            ? CGRect(x: 2 * usable.midX - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
            : CGRect(x: frame.minX, y: 2 * usable.midY - frame.maxY, width: frame.width, height: frame.height)
        return (area, other, otherFrame)
    }

    /// You let go of a pair's outer edge: the pair keeps that size, centered, and the two windows
    /// are identical, half each. Returns false when only the split moved (see `adopt`) or it isn't a pair.
    @discardableResult
    public mutating func adoptPair(_ id: WindowID, dragged frame: CGRect, target: CGRect, in rect: CGRect, gap: CGFloat,
                                   limits: [WindowID: SizeLimits] = [:]) -> Bool {
        guard let resized = pairResize(id, dragged: frame, target: target, in: rect, gap: gap, limits: limits) else { return false }
        let usable = Self.usable(rect, gap: gap)
        let width = min(1, max(Self.pairSmallest, Double(resized.area.width / max(1, usable.width))))
        let height = min(1, max(Self.pairSmallest, Double(resized.area.height / max(1, usable.height))))
        pair = width >= 0.995 && height >= 0.995 ? nil : Pair(width: width, height: height, windows: Set(windows))
        // Identical windows: half each.
        for i in columns.indices {
            columns[i].weight = 1
            columns[i].weights = Array(repeating: 1, count: columns[i].windows.count)
        }
        return true
    }

    /// The screen less its margins, as `frames` measures it.
    static func usable(_ rect: CGRect, gap: CGFloat) -> CGRect {
        CGRect(x: (rect.minX + gap).rounded(), y: (rect.minY + gap).rounded(),
               width: (rect.width - 2 * gap).rounded(), height: (rect.height - 2 * gap).rounded())
    }
}
