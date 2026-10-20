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
    /// Width of a lone window as a fraction of the usable screen width, once
    /// the user has grown, shrunk or dragged it (see `singleOwner`).
    public var singleScale: Double
    /// Height of a lone or spotlighted window as a fraction of the usable
    /// height, once the user has dragged it to a shape of their own. nil means
    /// the default 16:10.
    public var singleHeight: Double?
    /// The window `singleScale` and `singleHeight` were set for. Any other
    /// window centered here shows at the default 16:10.
    public var singleOwner: WindowID?
    /// While set, this window sits alone in the center and the rest wait as
    /// small windows down the left edge (⌘⇧F). Any change to the layout ends it.
    public var spotlight: WindowID?
    /// The arrangement sized smaller than the screen, centered (`Area`), or nil to fill it.
    public var area: Area?
    /// While a placeholder that made the 2×2 grid waits for its window: the columns from
    /// before, so if the app gives up, everything goes back. Not saved, like the placeholder.
    var beforeGrid: GridUndo?

    struct GridUndo: Equatable, Sendable {
        var placeholder: WindowID
        var before: [Column]
        var grid: [Column]
    }

    public static let defaultSingleScale = 0.6
    public static let singleAspect = 1.6 // 16:10
    public static let singleScaleRange = 0.2...1.0
    public static let singleHeightRange = 0.15...1.0
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
    /// The fourth window makes a 2×2 grid instead (`grid(adding:)`), when every window fits
    /// in it.
    /// - room: the usable area and gap, with `limits`, so a window that can't be squeezed
    ///   (a minimum height, a fixed size) stacks where it fits, or gets a column of its own when
    ///   no column has the height for it and the others leave enough width.
    public mutating func insert(_ id: WindowID, near focused: WindowID?, maxColumns: Int,
                                limits: [WindowID: SizeLimits] = [:], room: (area: CGSize, gap: CGFloat)? = nil) {
        guard !contains(id) else { return }
        spotlight = nil
        guard !columns.isEmpty else {
            columns = [Column(windows: [id])]
            return
        }
        if windowCount == 3 {
            var grid = grid(adding: id)
            // Not when a window's minimum height can't share a column with another.
            let fits = room.map { room in
                grid.columns.allSatisfy { Self.stackHeight($0.windows, limits: limits, gap: room.gap) <= room.area.height }
            } ?? true
            if fits {
                grid.beforeGrid = Placeholder.isPlaceholder(id) ? GridUndo(placeholder: id, before: columns, grid: grid.columns) : nil
                self = grid
                return
            }
        }
        let focusedPos = focused.flatMap { position(of: $0) }
        if columns.count < max(1, maxColumns) {
            let index = focusedPos.map { $0.column + 1 } ?? columns.count
            columns.insert(Column(windows: [id], weight: averageColumnWeight), at: index)
            return
        }
        var candidates = Array(columns.indices)
        if let room, let natural = limits[id]?.maxWidth {
            // A narrow window (it keeps its own width: Calculator, a phone in Simulator) gets a
            // column of its own when the others keep a comfortable width, rather than squeezing
            // into a stack.
            let used = columns.map { col -> CGFloat in
                let caps = col.windows.map { limits[$0]?.maxWidth }
                return caps.contains(where: { $0 == nil }) ? 800 : caps.compactMap { $0 }.max() ?? 800
            }.reduce(0, +) + room.gap * CGFloat(columns.count)
            if used + natural <= room.area.width {
                let index = focusedPos.map { $0.column + 1 } ?? columns.count
                columns.insert(Column(windows: [id], weight: averageColumnWeight), at: index)
                return
            }
        }
        if let room {
            let fitting = columns.indices.filter {
                Self.stackHeight(columns[$0].windows + [id], limits: limits, gap: room.gap) <= room.area.height
            }
            if fitting.isEmpty {
                // Narrow columns (windows that keep their own width) can leave room beside them.
                func width(_ col: Column) -> CGFloat {
                    let caps = col.windows.map { limits[$0]?.maxWidth }
                    let widest = caps.contains(where: { $0 == nil }) ? 400 : caps.compactMap { $0 }.max() ?? 400
                    return max(col.windows.compactMap { limits[$0]?.minWidth }.max() ?? 0, widest)
                }
                let needed = limits[id].flatMap { $0.minWidth ?? $0.maxWidth } ?? 400
                let used = columns.map(width).reduce(0, +) + room.gap * CGFloat(columns.count)
                if used + needed <= room.area.width {
                    let index = focusedPos.map { $0.column + 1 } ?? columns.count
                    columns.insert(Column(windows: [id], weight: averageColumnWeight), at: index)
                    return
                }
            } else {
                candidates = fitting
            }
        }
        let fewest = candidates.map { columns[$0].windows.count }.min() ?? 0
        var target = candidates.last { columns[$0].windows.count == fewest } ?? columns.count - 1
        if let f = focusedPos, candidates.contains(f.column), columns[f.column].windows.count == fewest {
            target = f.column
        }
        let row = (focusedPos?.column == target) ? focusedPos!.row + 1 : columns[target].windows.count
        columns[target].insertWindow(id, at: row)
    }

    /// The height a stack of these windows needs: every window at least a sliver, a window with
    /// a minimum height that much.
    static func stackHeight(_ ids: [WindowID], limits: [WindowID: SizeLimits], gap: CGFloat) -> CGFloat {
        ids.map { max(limits[$0]?.minHeight ?? 0, 80) }.reduce(0, +) + gap * CGFloat(ids.count - 1)
    }

    /// The 2×2 grid that four windows make: this layout's three and `id`, two columns of two,
    /// evenly. The windows already there move as little as they can: two columns with a stack
    /// of two take the newcomer under the lone one; otherwise the first two windows (left to
    /// right, top to bottom) make the left column and the third sits over the newcomer.
    public func grid(adding id: WindowID) -> Layout {
        var grid = self
        grid.spotlight = nil
        grid.beforeGrid = nil
        let counts = columns.map(\.windows.count)
        if counts == [2, 1] || counts == [1, 2] {
            let lone = counts[0] == 1 ? 0 : 1
            grid.columns[lone].windows.append(id)
        } else {
            let all = windows
            grid.columns = [Column(windows: Array(all.prefix(2))), Column(windows: Array(all.dropFirst(2)) + [id])]
        }
        for c in grid.columns.indices {
            grid.columns[c].weight = 1
            grid.columns[c].weights = Array(repeating: 1, count: grid.columns[c].windows.count)
        }
        return grid
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
        // The placeholder that made the grid, and nothing changed since: back to before.
        if let undo = beforeGrid, undo.placeholder == id {
            beforeGrid = nil
            if columns == undo.grid {
                columns = undo.before
                spotlight = nil
                return true
            }
        }
        guard let (c, r) = position(of: id) else { return false }
        columns[c].removeWindow(at: r)
        if columns[c].windows.isEmpty { columns.remove(at: c) }
        spotlight = nil
        if singleOwner == id { resetSingle() }
        return true
    }

    /// Puts `new` exactly where `old` was.
    @discardableResult
    public mutating func replace(_ old: WindowID, with new: WindowID) -> Bool {
        guard let (c, r) = position(of: old), !contains(new) else { return false }
        columns[c].windows[r] = new
        if singleOwner == old { singleOwner = new }
        if spotlight == old { spotlight = new }
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

    // MARK: Restoring

    /// Puts a window back in the spot it had in `saved`, an earlier copy of this
    /// layout (from before LunchboxWM relaunched), going by the windows already back:
    /// into the stack it shared with them, at the same place in it, or as a
    /// column of its own in the same order among theirs, with the shares it had.
    /// Restoring every window of `saved`, in any order, gives `saved` again.
    /// Returns false when `saved` doesn't have the window.
    @discardableResult
    public mutating func restore(_ id: WindowID, from saved: Layout) -> Bool {
        guard !contains(id), let (sc, sr) = saved.position(of: id) else { return false }
        spotlight = nil
        let stack = saved.columns[sc]
        if let c = columns.firstIndex(where: { column in column.windows.contains { stack.windows.contains($0) } }) {
            let above = stack.windows[..<sr], below = stack.windows[(sr + 1)...]
            let row = columns[c].windows.lastIndex { above.contains($0) }.map { $0 + 1 }
                ?? columns[c].windows.firstIndex { below.contains($0) }
                ?? columns[c].windows.count
            columns[c].windows.insert(id, at: row)
            columns[c].weights.insert(stack.weights[sr], at: row)
        } else {
            // Right after the last column holding a window that was to its left.
            let index = columns.lastIndex { column in
                column.windows.contains { saved.position(of: $0).map { $0.column < sc } ?? false }
            }.map { $0 + 1 } ?? 0
            columns.insert(Column(windows: [id], weights: [stack.weights[sr]], weight: stack.weight), at: index)
        }
        if saved.singleOwner == id, singleOwner == nil {
            singleOwner = id
            singleScale = saved.singleScale
            singleHeight = saved.singleHeight
        }
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

    /// Resize mode's arrows: an arrow pushes the window's edge on that side, so what it does
    /// depends on where the window is. Toward a neighbor, the edge they share moves that way and
    /// the window grows; against the screen's edge, its other edge moves that way and it shrinks.
    /// So in the right column ← widens it, in the left column →; at the top of a stack ↓ makes
    /// it taller, at the bottom ↑. Only that one edge moves; nothing else shifts. A centered
    /// window has no neighbors: → and ↑ grow it, ← and ↓ shrink it, around its center.
    ///
    /// With `limits`, a press only counts when the window changes on screen (see `visibly`).
    @discardableResult
    public mutating func resize(_ id: WindowID, toward direction: Direction, by step: Double, in rect: CGRect, gap: CGFloat,
                                limits: [WindowID: SizeLimits]) -> Bool {
        visibly(id, step, in: rect, gap: gap, limits: limits) { $0.resize(id, toward: direction, by: $1, in: rect, gap: gap) }
    }

    @discardableResult
    public mutating func resize(_ id: WindowID, toward direction: Direction, by step: Double, in rect: CGRect, gap: CGFloat) -> Bool {
        guard let (c, r) = position(of: id) else { return false }
        let horizontal = direction == .left || direction == .right
        if windowCount == 1 || spotlight == id {
            return resize(id, by: direction == .right || direction == .up ? step : -step, horizontal: horizontal, in: rect, gap: gap)
        }
        let forward = direction == .right || direction == .down
        func push(_ shares: inout [Double], at i: Int) -> Bool {
            guard shares.count > 1 else { return false }
            let toward = forward ? i + 1 : i - 1
            if shares.indices.contains(toward) { return Self.shift(&shares, to: i, from: toward, by: step) }
            return Self.shift(&shares, to: forward ? i - 1 : i + 1, from: i, by: step)
        }
        if horizontal {
            var widths = columns.map(\.weight)
            guard push(&widths, at: c) else { return false }
            for i in columns.indices { columns[i].weight = widths[i] }
            return true
        }
        return push(&columns[c].weights, at: r)
    }

    /// Moves the edge between two neighbors: `to` gets `step` of the whole more and `from` that
    /// much less, without either going under its smallest share.
    static func shift(_ shares: inout [Double], to: Int, from: Int, by step: Double) -> Bool {
        let total = shares.reduce(0, +)
        guard total > 0 else { return false }
        let moved = min(step * total, shares[from] - minFraction * total)
        guard moved > 0.0001 * total else { return false }
        shares[to] += moved
        shares[from] -= moved
        return true
    }

    /// Width or height alone (resize mode): `horizontal` changes the width, else the height;
    /// a negative `delta` makes it smaller. A tiled window's column gets wider or narrower, or its
    /// share of its stack taller or shorter; a centered window (alone, or in Focus) changes that
    /// side only and stays centered. `rect` is the display's usable area, to keep the other side.
    @discardableResult
    public mutating func resize(_ id: WindowID, by delta: Double, horizontal: Bool, in rect: CGRect, gap: CGFloat) -> Bool {
        guard let (c, r) = position(of: id) else { return false }
        if windowCount == 1 || spotlight == id {
            let usable = rect.insetBy(dx: gap, dy: gap)
            guard usable.width > 0, usable.height > 0 else { return false }
            let now = centeredFrame(id, in: usable)
            var scale = Double(now.width / usable.width), height = Double(now.height / usable.height)
            if horizontal {
                scale = min(Self.singleScaleRange.upperBound, max(Self.singleScaleRange.lowerBound, scale + delta))
            } else {
                height = min(Self.singleHeightRange.upperBound, max(Self.singleHeightRange.lowerBound, height + delta))
            }
            let changed = singleOwner != id || abs(scale - singleScale) > 0.0001 || abs(height - (singleHeight ?? -1)) > 0.0001
            singleOwner = id
            singleScale = scale
            singleHeight = height
            return changed
        }
        if horizontal {
            guard columns.count > 1 else { return false }
            var widths = columns.map(\.weight)
            guard Self.adjust(&widths, index: c, delta: delta) else { return false }
            for i in columns.indices { columns[i].weight = widths[i] }
            return true
        }
        guard columns[c].windows.count > 1 else { return false }
        return Self.adjust(&columns[c].weights, index: r, delta: delta)
    }

    /// ⌘⇧+ and ⌘⇧−, counting only what shows (see `visibly`): a window at its smallest doesn't
    /// take another shrink, so the next grow always grows it. Width and height each stop at
    /// their own limit. `rect`, `gap` and `limits` as for `frames`.
    @discardableResult
    public mutating func resize(_ id: WindowID, by delta: Double, in rect: CGRect, gap: CGFloat,
                                limits: [WindowID: SizeLimits]) -> Bool {
        guard let (c, r) = position(of: id) else { return false }
        if windowCount == 1 || spotlight == id {
            return visibly(id, delta, in: rect, gap: gap, limits: limits) { $0.resize(id, by: $1) }
        }
        var changed = false
        if columns.count > 1 {
            changed = visibly(id, delta, in: rect, gap: gap, limits: limits) { layout, d in
                var widths = layout.columns.map(\.weight)
                guard Self.adjust(&widths, index: c, delta: d) else { return false }
                for i in layout.columns.indices { layout.columns[i].weight = widths[i] }
                return true
            }
        }
        if columns[c].windows.count > 1 {
            changed = visibly(id, delta, in: rect, gap: gap, limits: limits) { Self.adjust(&$0.columns[c].weights, index: r, delta: $1) }
                || changed
        }
        return changed
    }

    /// Takes a resize step (`apply` with `delta`) only as far as the window `id` actually changes.
    /// A window that's reached its minimum (or maximum, or a neighbor's) stays that size however
    /// small its share gets, so a step past that point would change nothing you can see, and the
    /// step back would then do nothing either. So:
    /// - a step that wouldn't change the window doesn't happen;
    /// - a step that reaches a limit partway stops where the window stops;
    /// - a share already past where the window stops (shrunk before LunchboxWM knew its minimum) is
    ///   skipped over, so the step starts where the window starts moving.
    mutating func visibly(_ id: WindowID, _ delta: Double, in rect: CGRect, gap: CGFloat, limits: [WindowID: SizeLimits],
                          apply: (inout Layout, Double) -> Bool) -> Bool {
        guard delta != 0 else { return false }
        let base = self
        func size(_ t: Double) -> CGSize? {
            var layout = base
            if t > 0 { _ = apply(&layout, delta * t) }
            return layout.frames(in: rect, gap: gap, limits: limits)[id]?.size
        }
        func same(_ a: CGSize?, _ b: CGSize?) -> Bool {
            guard let a, let b else { return a == b }
            return abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }
        let now = size(0)
        // Past this every share is at its bound.
        let reach = max(1, 1 / abs(delta))
        var start = 0.0
        if same(size(1), now) {
            guard !same(size(reach), now) else { return false }
            var low = 1.0, high = reach
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if same(size(mid), now) { low = mid } else { high = mid }
            }
            start = low
        }
        let end = start + 1, target = size(end)
        var low = start, high = end
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if same(size(mid), target) { high = mid } else { low = mid }
        }
        // A step that ends within a few points of a limit (or none at all) is taken whole.
        if end - high < 0.05 { high = end }
        var next = base
        guard apply(&next, delta * high), next != base else { return false }
        self = next
        return true
    }

    /// Gives a window more (positive `delta`) or less space. A lone window grows
    /// or shrinks around the screen center; a tiled window changes both its
    /// column's width and its height within the stack, where it has neighbors.
    @discardableResult
    public mutating func resize(_ id: WindowID, by delta: Double) -> Bool {
        guard let (c, r) = position(of: id) else { return false }
        if windowCount == 1 || spotlight == id {
            // Another window's shape doesn't carry over: start from the default.
            if singleOwner != id {
                resetSingle()
                singleOwner = id
            }
            var next = min(Self.singleScaleRange.upperBound, max(Self.singleScaleRange.lowerBound, singleScale + delta))
            if let h = singleHeight {
                // A shape the user chose grows and shrinks in proportion, stopping
                // when either side reaches its limit so the shape never changes.
                var k = next / singleScale
                k = min(k, Self.singleHeightRange.upperBound / h)
                k = max(k, Self.singleHeightRange.lowerBound / h)
                next = singleScale * k
                guard abs(k - 1) > 0.0001 else { return false }
                singleHeight = h * k
            }
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
        if windowCount == 1 || spotlight == id {
            // Any shape the user drags to; it stays centered.
            let width = min(Self.singleScaleRange.upperBound, max(Self.singleScaleRange.lowerBound,
                                                                   Double(size.width / max(1, usable.width))))
            let height = min(Self.singleHeightRange.upperBound, max(Self.singleHeightRange.lowerBound,
                                                                     Double(size.height / max(1, usable.height))))
            let changed = singleOwner != id || abs(width - singleScale) > 0.005 || abs(height - (singleHeight ?? -1)) > 0.005
            singleScale = width
            singleHeight = height
            singleOwner = id
            return changed
        }
        var changed = false
        let area = arrangementArea(usable)
        if columns.count > 1 {
            let avail = Double(area.width - gap * CGFloat(columns.count - 1))
            var widths = columns.map(\.weight)
            let current = widths[c] / widths.reduce(0, +)
            if Self.adjust(&widths, index: c, delta: Double(size.width) / avail - current) {
                for i in columns.indices { columns[i].weight = widths[i] }
                changed = true
            }
        }
        if columns[c].windows.count > 1 {
            let avail = Double(area.height - gap * CGFloat(columns[c].windows.count - 1))
            let weights = columns[c].weights
            let current = weights[r] / weights.reduce(0, +)
            changed = Self.adjust(&columns[c].weights, index: r, delta: Double(size.height) / avail - current) || changed
        }
        return changed
    }

    /// Resets every window to an even share, and a lone or spotlighted window to
    /// the default size and shape. Spotlight stays on.
    public mutating func balance() {
        for i in columns.indices {
            columns[i].weight = 1
            columns[i].weights = Array(repeating: 1, count: columns[i].windows.count)
        }
        resetSingle()
        area = nil
    }

    private mutating func resetSingle() {
        singleScale = Self.defaultSingleScale
        singleHeight = nil
        singleOwner = nil
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
    /// - limits: windows that can't fill a tile (see `SizeLimits`). Each sits at the size it
    ///   takes, centered in its slot, and its column (or its share of a stack) is sized to fit
    ///   it, so a narrow window doesn't leave half the screen empty.
    public func frames(in rect: CGRect, gap: CGFloat, limits: [WindowID: SizeLimits] = [:]) -> [WindowID: CGRect] {
        let usable = CGRect(
            x: (rect.minX + gap).rounded(), y: (rect.minY + gap).rounded(),
            width: (rect.width - 2 * gap).rounded(), height: (rect.height - 2 * gap).rounded()
        )
        var result: [WindowID: CGRect] = [:]
        if windowCount == 1, let id = windows.first {
            result[id] = Self.fit(id, in: centeredFrame(id, in: usable), limits: limits, within: usable)
            return result
        }
        if let spot = spotlight, contains(spot) {
            let center = Self.fit(spot, in: centeredFrame(spot, in: usable), limits: limits, within: usable)
            result[spot] = center
            let others = windows.filter { $0 != spot }
            for (id, frame) in zip(others, Self.shelfFrames(count: others.count, beside: center, in: usable, gap: gap)) {
                result[id] = frame
            }
            return result
        }

        // A column needs at least the widest minimum among its windows, and is never wider
        // than its widest window can be (when every window in it has a maximum).
        let mins = columns.map { col in col.windows.compactMap { limits[$0]?.minWidth }.max() ?? 0 }
        let maxs = columns.map { col -> CGFloat in
            let caps = col.windows.map { limits[$0]?.maxWidth }
            return caps.contains(where: { $0 == nil }) ? .infinity : caps.compactMap { $0 }.max() ?? .infinity
        }
        // An arrangement sized smaller than the screen sits centered; otherwise it has all of it.
        let area = arrangementArea(usable)
        let availWidth = area.width - gap * CGFloat(columns.count - 1)
        let widths = Self.distribute(availWidth, weights: columns.map(\.weight), mins: mins.map { min($0, availWidth) }, maxs: maxs)
        // Columns that all stopped short of the screen sit together in the middle.
        var x = area.minX + max(0, (availWidth - widths.reduce(0, +)) / 2).rounded()
        for (c, column) in columns.enumerated() {
            let width = widths[c]
            let availHeight = area.height - gap * CGFloat(column.windows.count - 1)
            let heights = Self.distribute(
                availHeight, weights: column.weights,
                mins: column.windows.map { min(limits[$0]?.minHeight ?? 0, availHeight) },
                maxs: column.windows.map { limits[$0]?.maxHeight ?? .infinity })
            var y = area.minY + max(0, (availHeight - heights.reduce(0, +)) / 2).rounded()
            for (r, id) in column.windows.enumerated() {
                let slot = CGRect(x: x, y: y, width: width, height: heights[r])
                result[id] = Self.fit(id, in: slot, limits: limits, within: usable)
                y += heights[r] + gap
            }
            x += width + gap
        }
        return result
    }

    /// A window's frame in its slot: the slot itself, or for a window that can't fill it, the
    /// nearest size it takes, centered on the slot and kept on the screen.
    static func fit(_ id: WindowID, in slot: CGRect, limits: [WindowID: SizeLimits], within usable: CGRect) -> CGRect {
        guard let l = limits[id], !l.isEmpty else { return slot }
        let size = l.clamp(slot.size)
        guard size != slot.size else { return slot }
        var x = (slot.midX - size.width / 2).rounded(), y = (slot.midY - size.height / 2).rounded()
        x = max(usable.minX, min(x, usable.maxX - size.width))
        y = max(usable.minY, min(y, usable.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Where a lone or spotlighted window sits: the shape the user gave it, else
    /// the default 16:10.
    func centeredFrame(_ id: WindowID, in usable: CGRect) -> CGRect {
        if singleOwner == id { return Self.singleFrame(in: usable, scale: singleScale, height: singleHeight) }
        return Self.singleFrame(in: usable, scale: Self.defaultSingleScale)
    }

    /// A lone (or spotlighted) window, centered. By default 16:10 at `scale` of
    /// the usable width and never taller than the screen; at full scale it
    /// fills the usable area. With `height` (a fraction of the usable height)
    /// it keeps the shape the user dragged it to.
    static func singleFrame(in usable: CGRect, scale: Double, height: Double? = nil) -> CGRect {
        if scale >= singleScaleRange.upperBound - 0.0001, height == nil { return usable }
        let width = min(usable.width, (usable.width * CGFloat(scale)).rounded())
        let h = height.map { (usable.height * CGFloat($0)).rounded() } ?? (width / CGFloat(singleAspect)).rounded()
        let clamped = min(usable.height, h)
        return CGRect(
            x: (usable.midX - width / 2).rounded(),
            y: (usable.midY - clamped / 2).rounded(),
            width: width, height: clamped
        )
    }

    // MARK: Spotlight

    /// The windows waiting on the shelf while another is spotlighted.
    public var shelved: [WindowID] {
        guard let spot = spotlight, contains(spot), windowCount > 1 else { return [] }
        return windows.filter { $0 != spot }
    }

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

// MARK: Saving

extension Column: Codable {
    private enum CodingKeys: String, CodingKey { case windows, weights, weight }

    /// Shares that don't fit their windows (a damaged save) start over even.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let windows = try container.decode([WindowID].self, forKey: .windows)
        let weights = try container.decodeIfPresent([Double].self, forKey: .weights) ?? []
        let weight = try container.decodeIfPresent(Double.self, forKey: .weight) ?? 1
        func usable(_ w: Double) -> Bool { w > 0 && w.isFinite }
        self.init(windows: windows,
                  weights: weights.count == windows.count && weights.allSatisfy(usable) ? weights : nil,
                  weight: usable(weight) ? weight : 1)
    }
}

extension Layout: Codable {
    // Focus (`spotlight`) isn't saved: it's a moment's view, not part of the arrangement.
    private enum CodingKeys: String, CodingKey { case columns, singleScale, singleHeight, singleOwner, area }
}
