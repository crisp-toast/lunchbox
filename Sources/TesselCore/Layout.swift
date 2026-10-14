import CoreGraphics

/// One vertical column of stacked windows.
public struct Column: Equatable, Sendable {
    public var windows: [WindowID]
    /// Relative heights of `windows`, same order.
    public var weights: [Double]
    /// Relative width of this column among its siblings.
    public var weight: Double

    public init(windows: [WindowID], weights: [Double]? = nil, weight: Double = 1) {
        self.windows = windows
        self.weights = weights ?? Array(repeating: 1, count: windows.count)
        self.weight = weight
    }

    var averageWeight: Double {
        weights.isEmpty ? 1 : weights.reduce(0, +) / Double(weights.count)
    }

    mutating func removeWindow(at index: Int) {
        windows.remove(at: index)
        weights.remove(at: index)
    }

    mutating func insertWindow(_ id: WindowID, at index: Int) {
        let w = averageWeight
        windows.insert(id, at: index)
        weights.insert(w, at: index)
    }
}

/// The tiling layout of one display.
///
/// Windows live in columns that sit side by side; a column can hold a stack of
/// windows. A display with a single window shows it centered at a comfortable
/// size instead of filling the screen.
public struct Layout: Equatable, Sendable {
    public var columns: [Column]
    /// Width of a lone window as a fraction of the usable screen width.
    public var singleScale: Double
    /// While set, this window sits alone in the center and the rest wait as
    /// small windows down the left edge (⌘⇧F). Any change to the layout ends it.
    public var spotlight: WindowID?

    public static let defaultSingleScale = 0.6
    public static let singleAspect = 1.6 // 16:10
    public static let singleScaleRange = 0.3...1.0
    public static let minFraction = 0.12

    public init(columns: [Column] = [], singleScale: Double = Layout.defaultSingleScale) {
        self.columns = columns
        self.singleScale = singleScale
    }

    // MARK: Queries

    public var windows: [WindowID] { columns.flatMap(\.windows) }
    public var windowCount: Int { columns.reduce(0) { $0 + $1.windows.count } }
    public var isEmpty: Bool { columns.isEmpty }

    public func contains(_ id: WindowID) -> Bool { position(of: id) != nil }

    public func position(of id: WindowID) -> (column: Int, row: Int)? {
        for (c, col) in columns.enumerated() {
            if let r = col.windows.firstIndex(of: id) { return (c, r) }
        }
        return nil
    }

    var averageColumnWeight: Double {
        columns.isEmpty ? 1 : columns.map(\.weight).reduce(0, +) / Double(columns.count)
    }

    // MARK: Adding and removing

    /// Adds a new window. It gets its own column while there is room
    /// (`maxColumns`), placed right after the focused window's column;
    /// after that it stacks into the column with the fewest windows.
    public mutating func insert(_ id: WindowID, near focused: WindowID?, maxColumns: Int) {
        guard !contains(id) else { return }
        spotlight = nil
        guard !columns.isEmpty else {
            columns = [Column(windows: [id])]
            return
        }
        let focusedPos = focused.flatMap { position(of: $0) }
        if columns.count < max(1, maxColumns) {
            let index = focusedPos.map { $0.column + 1 } ?? columns.count
            columns.insert(Column(windows: [id], weight: averageColumnWeight), at: index)
            return
        }
        let fewest = columns.map(\.windows.count).min() ?? 0
        var target = columns.lastIndex { $0.windows.count == fewest } ?? columns.count - 1
        if let f = focusedPos, columns[f.column].windows.count == fewest {
            target = f.column
        }
        let row = (focusedPos?.column == target) ? focusedPos!.row + 1 : columns[target].windows.count
        columns[target].insertWindow(id, at: row)
    }

    /// Adds a window arriving from a neighboring display. Entering from the left
    /// edge (moving right) makes it the first column; from the right edge, the
    /// last column. Entering from above or below stacks it at that end of the
    /// column nearest `relativeX` (0 = left edge, 1 = right edge).
    public mutating func insert(_ id: WindowID, entering direction: Direction, relativeX: Double = 0.5) {
        guard !contains(id) else { return }
        spotlight = nil
        guard !columns.isEmpty else {
            columns = [Column(windows: [id])]
            return
        }
        switch direction {
        case .right:
            columns.insert(Column(windows: [id], weight: averageColumnWeight), at: 0)
        case .left:
            columns.append(Column(windows: [id], weight: averageColumnWeight))
        case .up, .down:
            let c = min(columns.count - 1, max(0, Int(relativeX * Double(columns.count))))
            columns[c].insertWindow(id, at: direction == .down ? 0 : columns[c].windows.count)
        }
    }

    @discardableResult
    public mutating func remove(_ id: WindowID) -> Bool {
        guard let (c, r) = position(of: id) else { return false }
        columns[c].removeWindow(at: r)
        if columns[c].windows.isEmpty { columns.remove(at: c) }
        spotlight = nil
        return true
    }

    /// Puts `new` exactly where `old` was.
    @discardableResult
    public mutating func replace(_ old: WindowID, with new: WindowID) -> Bool {
        guard let (c, r) = position(of: old), !contains(new) else { return false }
        columns[c].windows[r] = new
        return true
    }

    /// Swaps two windows that are both in this layout.
    @discardableResult
    public mutating func swap(_ a: WindowID, _ b: WindowID) -> Bool {
        guard a != b, let pa = position(of: a), let pb = position(of: b) else { return false }
        columns[pa.column].windows[pa.row] = b
        columns[pb.column].windows[pb.row] = a
        return true
    }

    // MARK: Moving

    public enum MoveResult: Equatable, Sendable {
        case moved
        /// Nothing more to do on this display in that direction.
        case edge
        case notFound
    }

    /// Moves a window one step in `direction`.
    ///
    /// Up and down swap it with its neighbor in the stack. Left and right move it
    /// one step sideways: a window sharing a column leaves the stack and gets its
    /// own column on that side; a window alone in its column joins the
    /// neighboring column. Pressing again keeps it travelling, so any arrangement
    /// can be reached with the arrow keys alone.
    public mutating func move(_ id: WindowID, _ direction: Direction) -> MoveResult {
        guard let (c, r) = position(of: id) else { return .notFound }
        spotlight = nil
        switch direction {
        case .up, .down:
            let target = direction == .up ? r - 1 : r + 1
            guard columns[c].windows.indices.contains(target) else { return .edge }
            columns[c].windows.swapAt(r, target)
            columns[c].weights.swapAt(r, target)
            return .moved
        case .left, .right:
            if columns[c].windows.count > 1 {
                columns[c].removeWindow(at: r)
                let column = Column(windows: [id], weight: averageColumnWeight)
                columns.insert(column, at: direction == .left ? c : c + 1)
                return .moved
            }
            let neighbor = direction == .left ? c - 1 : c + 1
            guard columns.indices.contains(neighbor) else { return .edge }
            columns.remove(at: c)
            let target = direction == .left ? neighbor : neighbor - 1
            columns[target].insertWindow(id, at: columns[target].windows.count)
            return .moved
        }
    }

    // MARK: Sizing

    /// Gives a window more (positive `delta`) or less space. A lone window grows
    /// or shrinks around the screen center; a tiled window changes both its
    /// column's width and its height within the stack, where it has neighbors.
    @discardableResult
    public mutating func resize(_ id: WindowID, by delta: Double) -> Bool {
        guard let (c, r) = position(of: id) else { return false }
        if windowCount == 1 || spotlight == id {
            let next = min(Self.singleScaleRange.upperBound, max(Self.singleScaleRange.lowerBound, singleScale + delta))
            guard abs(next - singleScale) > 0.0001 else { return false }
            singleScale = next
            return true
        }
        var changed = false
        if columns.count > 1 {
            var widths = columns.map(\.weight)
            if Self.adjust(&widths, index: c, delta: delta) {
                for i in columns.indices { columns[i].weight = widths[i] }
                changed = true
            }
        }
        if columns[c].windows.count > 1 {
            changed = Self.adjust(&columns[c].weights, index: r, delta: delta) || changed
        }
        return changed
    }

    /// Takes on a size the user dragged a window to, as new proportions.
    @discardableResult
    public mutating func adopt(_ id: WindowID, size: CGSize, in rect: CGRect, gap: CGFloat) -> Bool {
        guard let (c, r) = position(of: id) else { return false }
        let usable = rect.insetBy(dx: gap, dy: gap)
        if windowCount == 1 {
            let scale = Double(size.width / max(1, usable.width))
            let next = min(Self.singleScaleRange.upperBound, max(Self.singleScaleRange.lowerBound, scale))
            let changed = abs(next - singleScale) > 0.005
            singleScale = next
            return changed
        }
        var changed = false
        if columns.count > 1 {
            let avail = Double(usable.width - gap * CGFloat(columns.count - 1))
            var widths = columns.map(\.weight)
            let current = widths[c] / widths.reduce(0, +)
            if Self.adjust(&widths, index: c, delta: Double(size.width) / avail - current) {
                for i in columns.indices { columns[i].weight = widths[i] }
                changed = true
            }
        }
        if columns[c].windows.count > 1 {
            let avail = Double(usable.height - gap * CGFloat(columns[c].windows.count - 1))
            let weights = columns[c].weights
            let current = weights[r] / weights.reduce(0, +)
            changed = Self.adjust(&columns[c].weights, index: r, delta: Double(size.height) / avail - current) || changed
        }
        return changed
    }

    /// Resets every window to an even share and lone windows to the default size.
    public mutating func balance() {
        for i in columns.indices {
            columns[i].weight = 1
            columns[i].weights = Array(repeating: 1, count: columns[i].windows.count)
        }
        singleScale = Self.defaultSingleScale
    }

    /// Changes one share by `delta` (as a fraction of the whole) and rescales the
    /// others to fit. Returns the weights normalized to sum to 1.
    static func adjust(_ weights: inout [Double], index: Int, delta: Double) -> Bool {
        guard weights.count > 1, weights.indices.contains(index) else { return false }
        let total = weights.reduce(0, +)
        guard total > 0 else { return false }
        let current = weights[index] / total
        let maxFraction = 1 - minFraction * Double(weights.count - 1)
        let next = min(maxFraction, max(minFraction, current + delta))
        guard abs(next - current) > 0.0001 else { return false }
        let others = total - weights[index]
        for i in weights.indices where i != index {
            weights[i] = others > 0 ? weights[i] / others * (1 - next) : (1 - next) / Double(weights.count - 1)
        }
        weights[index] = next
        return true
    }

    // MARK: Geometry

    /// Target frames for every window, in top-left-origin screen coordinates.
    public func frames(in rect: CGRect, gap: CGFloat) -> [WindowID: CGRect] {
        let usable = CGRect(
            x: (rect.minX + gap).rounded(), y: (rect.minY + gap).rounded(),
            width: (rect.width - 2 * gap).rounded(), height: (rect.height - 2 * gap).rounded()
        )
        var result: [WindowID: CGRect] = [:]
        if windowCount == 1, let id = windows.first {
            result[id] = Self.singleFrame(in: usable, scale: singleScale)
            return result
        }
        if let spot = spotlight, contains(spot) {
            let center = Self.singleFrame(in: usable, scale: singleScale)
            result[spot] = center
            let others = windows.filter { $0 != spot }
            for (id, frame) in zip(others, Self.shelfFrames(count: others.count, beside: center, in: usable, gap: gap)) {
                result[id] = frame
            }
            return result
        }

        let widthTotal = columns.map(\.weight).reduce(0, +)
        let availWidth = usable.width - gap * CGFloat(columns.count - 1)
        var x = usable.minX
        for (c, column) in columns.enumerated() {
            let width = c == columns.count - 1
                ? usable.maxX - x
                : (availWidth * CGFloat(column.weight / widthTotal)).rounded()
            let heightTotal = column.weights.reduce(0, +)
            let availHeight = usable.height - gap * CGFloat(column.windows.count - 1)
            var y = usable.minY
            for (r, id) in column.windows.enumerated() {
                let height = r == column.windows.count - 1
                    ? usable.maxY - y
                    : (availHeight * CGFloat(column.weights[r] / heightTotal)).rounded()
                result[id] = CGRect(x: x, y: y, width: width, height: height)
                y += height + gap
            }
            x += width + gap
        }
        return result
    }

    /// A lone window: centered, 16:10, `scale` of the usable width, never taller
    /// than the screen. At full scale it fills the usable area.
    static func singleFrame(in usable: CGRect, scale: Double) -> CGRect {
        if scale >= singleScaleRange.upperBound - 0.0001 { return usable }
        let width = (usable.width * CGFloat(scale)).rounded()
        let height = min(usable.height, (width / CGFloat(singleAspect)).rounded())
        return CGRect(
            x: (usable.midX - width / 2).rounded(),
            y: (usable.midY - height / 2).rounded(),
            width: width, height: height
        )
    }

    // MARK: Spotlight

    /// ⌘⇧F: puts `id` alone in the center with the others shelved, or ends
    /// spotlight if it's on. Does nothing for a window that's already alone.
    @discardableResult
    public mutating func toggleSpotlight(_ id: WindowID) -> Bool {
        if spotlight != nil {
            spotlight = nil
            return true
        }
        guard windowCount > 1, contains(id) else { return false }
        spotlight = id
        return true
    }

    /// Small windows stacked down the left edge, vertically centered, in the
    /// space left of the centered window (never narrower than 160 points).
    static func shelfFrames(count: Int, beside center: CGRect, in usable: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let width = max(160, min(420, center.minX - usable.minX - gap)).rounded()
        let slot = (usable.height - gap * CGFloat(count - 1)) / CGFloat(count)
        let height = min((width / CGFloat(singleAspect)).rounded(), slot.rounded(.down))
        let total = height * CGFloat(count) + gap * CGFloat(count - 1)
        var y = (usable.minY + (usable.height - total) / 2).rounded()
        return (0..<count).map { _ in
            defer { y += height + gap }
            return CGRect(x: usable.minX, y: y, width: width, height: height)
        }
    }

    /// How many side-by-side columns new windows get before they start stacking.
    public static func maxColumns(forWidth width: CGFloat) -> Int {
        max(1, min(4, Int(width / 800)))
    }
}
