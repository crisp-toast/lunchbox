import CoreGraphics

/// Any arrangement of two or more windows can sit centered on the screen, smaller than it. Drag an
/// outer side, top or bottom of the arrangement and only that window grows or shrinks, its edge
/// following the pointer: the others keep their size and slide over, so the arrangement stays
/// centered on the screen. (Up and down, windows that span the whole height change with it, or the
/// tops and bottoms wouldn't line up.) Drag an outer corner and the whole arrangement resizes evenly
/// around the middle, every window keeping its share, the opposite corners moving to match. An edge
/// between two windows moves the split between them. The size belongs to those windows: open or
/// close one, or Tidy, and the arrangement fills the screen again.
extension Layout {
    public struct Area: Codable, Equatable, Sendable {
        /// The arrangement's width and height, as fractions of the usable area.
        public var width: Double
        public var height: Double
        /// The windows it's for.
        public var windows: Set<WindowID>
    }

    /// Which edges of a window are being dragged: a side, a top or bottom, or one of each (a corner).
    public struct Handle: Equatable, Sendable {
        /// Left or top (`low`), right or bottom (`high`).
        public enum Side: Sendable, Equatable { case low, high }
        public var horizontal: Side?
        public var vertical: Side?
        public init(horizontal: Side?, vertical: Side?) {
            self.horizontal = horizontal
            self.vertical = vertical
        }
    }

    /// The smallest an arrangement gets, as a fraction of the screen each way.
    public static let smallestArea = 0.2

    /// Two or more windows, not in Focus: they can be sized as an arrangement.
    public var isArrangement: Bool { windowCount >= 2 && spotlight == nil }

    /// Where the arrangement sits within `usable` (the screen less its margins): all of it, or the
    /// centered size it was dragged to.
    func arrangementArea(_ usable: CGRect) -> CGRect {
        guard isArrangement, let area, area.windows == Set(windows) else { return usable }
        let w = (usable.width * CGFloat(area.width)).rounded(), h = (usable.height * CGFloat(area.height)).rounded()
        return CGRect(x: (usable.midX - w / 2).rounded(), y: (usable.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Whether a window's side is on the outside of the arrangement (its column is the first or last).
    public func isOuter(_ id: WindowID, horizontal side: Handle.Side) -> Bool {
        guard let (c, _) = position(of: id) else { return false }
        return side == .low ? c == 0 : c == columns.count - 1
    }

    /// Whether a window's top or bottom is on the outside of the arrangement (first or last in its column).
    public func isOuter(_ id: WindowID, vertical side: Handle.Side) -> Bool {
        guard let (c, r) = position(of: id) else { return false }
        return side == .low ? r == 0 : r == columns[c].windows.count - 1
    }

    /// Window `id`'s `handle` dragged to `point`: the layout after it, never smaller than any
    /// window's minimum (`limits`). Nil if it isn't an arrangement.
    public func dragged(_ id: WindowID, handle: Handle, to point: CGPoint, in rect: CGRect, gap: CGFloat,
                        limits: [WindowID: SizeLimits] = [:]) -> Layout? {
        guard isArrangement, let (c, r) = position(of: id) else { return nil }
        let usable = Self.usable(rect, gap: gap)
        let area = arrangementArea(usable)
        // Every window at least its minimum (and 80 points).
        let columnLeast = columns.map { col in max(80, col.windows.compactMap { limits[$0]?.minWidth }.max() ?? 0) }
        func rowLeast(_ id: WindowID) -> CGFloat { max(80, limits[id]?.minHeight ?? 0) }
        let leastWidth = columnLeast.reduce(0, +) + gap * CGFloat(columns.count - 1)
        let leastHeight = columns.map { col in col.windows.map(rowLeast).reduce(0, +) + gap * CGFloat(col.windows.count - 1) }.max() ?? 80
        var next = self
        var width = area.width, height = area.height
        // A corner resizes every window evenly; a side, top or bottom only the window dragged.
        let corner = handle.horizontal != nil && handle.vertical != nil

        if let side = handle.horizontal {
            let wanted = min(usable.width, max(leastWidth, 2 * abs(usable.midX - point.x)))
            if isOuter(id, horizontal: side) && corner {
                width = wanted
            } else if isOuter(id, horizontal: side) {
                // Only the dragged column takes the change; the others keep their widths.
                let avail = area.width - gap * CGFloat(columns.count - 1)
                let total = columns.map(\.weight).reduce(0, +)
                var widths = columns.map { CGFloat($0.weight / total) * avail }
                widths[c] = max(columnLeast[c], widths[c] + wanted - area.width)
                width = min(usable.width, widths.reduce(0, +) + gap * CGFloat(columns.count - 1))
                let sum = widths.reduce(0, +)
                for i in columns.indices { next.columns[i].weight = Double(widths[i] / sum) * Double(columns.count) }
            } else {
                // The split between this column and its neighbor on that side follows the pointer.
                let n = side == .low ? c - 1 : c + 1, lo = min(c, n), hi = max(c, n)
                let avail = area.width - gap * CGFloat(columns.count - 1)
                let total = columns.map(\.weight).reduce(0, +)
                let widths = columns.map { CGFloat($0.weight / total) * avail }
                let loLeft = area.minX + widths[..<lo].reduce(0, +) + gap * CGFloat(lo)
                let both = widths[lo] + widths[hi]
                let loRight = c == lo ? point.x : point.x - gap
                let loWidth = min(both - columnLeast[hi], max(columnLeast[lo], loRight - loLeft))
                let weight = columns[lo].weight + columns[hi].weight
                next.columns[lo].weight = weight * Double(loWidth / both)
                next.columns[hi].weight = weight - next.columns[lo].weight
            }
        }
        if let side = handle.vertical {
            let wanted = min(usable.height, max(leastHeight, 2 * abs(usable.midY - point.y)))
            if isOuter(id, vertical: side) && corner {
                height = wanted
            } else if isOuter(id, vertical: side) {
                // In the dragged window's column only it takes the change; its neighbors in the stack
                // keep their heights. Other columns span the whole height, so they change with it.
                let column = columns[c]
                let avail = area.height - gap * CGFloat(column.windows.count - 1)
                let total = column.weights.reduce(0, +)
                var heights = column.weights.map { CGFloat($0 / total) * avail }
                heights[r] = max(rowLeast(column.windows[r]), heights[r] + wanted - area.height)
                height = min(usable.height, max(leastHeight, heights.reduce(0, +) + gap * CGFloat(column.windows.count - 1)))
                let sum = heights.reduce(0, +)
                next.columns[c].weights = heights.map { Double($0 / sum) * Double(heights.count) }
            } else {
                // The split between this window and its neighbor in the stack follows the pointer.
                let column = columns[c]
                let n = side == .low ? r - 1 : r + 1, lo = min(r, n), hi = max(r, n)
                let avail = area.height - gap * CGFloat(column.windows.count - 1)
                let total = column.weights.reduce(0, +)
                let heights = column.weights.map { CGFloat($0 / total) * avail }
                let loTop = area.minY + heights[..<lo].reduce(0, +) + gap * CGFloat(lo)
                let both = heights[lo] + heights[hi]
                let loBottom = r == lo ? point.y : point.y - gap
                let loHeight = min(both - rowLeast(column.windows[hi]), max(rowLeast(column.windows[lo]), loBottom - loTop))
                let weight = column.weights[lo] + column.weights[hi]
                next.columns[c].weights[lo] = weight * Double(loHeight / both)
                next.columns[c].weights[hi] = weight - next.columns[c].weights[lo]
            }
        }
        if width >= usable.width - 0.5 && height >= usable.height - 0.5 {
            next.area = nil
        } else {
            next.area = Area(width: min(1, max(Self.smallestArea, Double(width / usable.width))),
                             height: min(1, max(Self.smallestArea, Double(height / usable.height))),
                             windows: Set(windows))
        }
        return next
    }

    /// The screen less its margins, as `frames` measures it.
    static func usable(_ rect: CGRect, gap: CGFloat) -> CGRect {
        CGRect(x: (rect.minX + gap).rounded(), y: (rect.minY + gap).rounded(),
               width: (rect.width - 2 * gap).rounded(), height: (rect.height - 2 * gap).rounded())
    }
}
