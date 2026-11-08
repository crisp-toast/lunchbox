import CoreGraphics

extension WindowSort {
    /// A sorted Workspace's windows tiled on one display (`windows`: the one that matters most
    /// first), the room shared out for how they're used. Every way of putting them in columns and
    /// stacks is tried, the window that matters most top left, and each split nudged a step at a
    /// time while that helps; each window counts for its weight (`Plan.weights`) times how well it
    /// gets on at its size (`Comfort`). So the window you've been in all along gets the big tile,
    /// the others the rest, chat and music take a narrow column, and a window with a minimum size
    /// keeps it. Only when that's clearly better than every column and stack an even share, and
    /// never by squeezing a window that's easy to use at an even share below the size it's easy
    /// to use at: with windows used about as much, or a crowded Workspace (more than two to a
    /// column), it stays even. Without `room`, always even.
    public static func layout(_ windows: [WindowID], maxColumns: Int, weights: [WindowID: Double] = [:],
                              comforts: [WindowID: Comfort] = [:], limits: [WindowID: SizeLimits] = [:],
                              room: (area: CGSize, gap: CGFloat)? = nil) -> Layout {
        let even = evenly(windows, maxColumns: maxColumns, limits: limits, room: room)
        guard let room, windows.count > 1, windows.count <= 2 * max(1, maxColumns),
              room.area.width > 0, room.area.height > 0 else { return even }
        let screen = CGRect(x: 0, y: 0, width: room.area.width + 2 * room.gap, height: room.area.height + 2 * room.gap)
        func usable(_ id: WindowID, _ frames: [WindowID: CGRect]) -> Bool {
            let size = frames[id]?.size ?? .zero, smallest = (comforts[id] ?? .usual).smallest
            return size.width >= smallest.width && size.height >= smallest.height
        }
        let atEven = even.frames(in: screen, gap: room.gap, limits: limits)
        let keepUsable = windows.filter { usable($0, atEven) }
        func score(_ layout: Layout) -> Double {
            let frames = layout.frames(in: screen, gap: room.gap, limits: limits)
            guard keepUsable.allSatisfy({ usable($0, frames) }) else { return 0 }
            return windows.reduce(0) { $0 + (weights[$1] ?? 1) * (comforts[$1] ?? .usual).value(of: frames[$1]?.size ?? .zero) }
        }
        // Every column keeps its windows' minimum widths and every stack their minimum heights.
        func fits(_ layout: Layout) -> Bool {
            let widths = layout.columns.map { col in col.windows.compactMap { limits[$0]?.minWidth }.max() ?? 0 }
            return widths.reduce(0, +) + room.gap * CGFloat(layout.columns.count - 1) <= room.area.width
                && layout.columns.allSatisfy { Layout.stackHeight($0.windows, limits: limits, gap: room.gap) <= room.area.height }
        }
        let n = windows.count
        // Columns of at least 600 points: a third on most desktop displays, for narrow windows.
        let most = min(n, mostColumns(maxColumns: maxColumns, width: room.area.width))
        let fewest = maxColumns > 1 ? min(2, most) : 1
        // The ones that want width first, for the bigger tiles.
        let wideFirst = [Comfort.wide, .usual, .narrow].flatMap { c in windows.filter { (comforts[$0] ?? .usual) == c } }
        let orders = wideFirst == windows ? [windows] : [windows, wideFirst]
        var best = even, top = score(even)
        let bar = top * 1.015
        for count in fewest...max(fewest, most) {
            for rows in splits(n, into: count, most: max(3, (n + count - 1) / count)) {
                for order in orders {
                    var start = Layout(), next = 0
                    start.columns = rows.map { r in
                        defer { next += r }
                        return Column(windows: Array(order[next..<next + r]))
                    }
                    guard fits(start) else { continue }
                    let (layout, s) = climb(start, score: score)
                    if s > top { (best, top) = (layout, s) }
                }
            }
        }
        return top > bar ? best : even
    }

    /// How many columns a sorted Workspace can have on a display `width` points wide: the usual
    /// (`Layout.maxColumns`), or one more while each keeps 600 points, for narrow windows.
    public static func mostColumns(maxColumns: Int, width: CGFloat) -> Int {
        min(4, max(maxColumns, min(maxColumns + 1, Int(width / 600))))
    }

    /// Whether windows that take at least these sizes (`.zero`: no minimum) can all be on a screen
    /// with `area` at once without overlapping, in up to `columns` columns: each column as wide as
    /// the widest minimum in it and as tall as its windows stacked, `gap` apart. Music and Podcasts
    /// together can't, on a 1920 × 1080 display: each needs about 1000 × 600. With more than six
    /// windows that have a minimum it doesn't look, and says yes.
    public static func canShare(_ mins: [CGSize], area: CGSize, gap: CGFloat, columns: Int) -> Bool {
        let sliver: CGFloat = 80 // the least height a window gets in a stack
        let tight = mins.filter { $0.width > 0 || $0.height > sliver }
        let loose = mins.count - tight.count
        guard !tight.isEmpty, tight.count <= 6 else { return true }
        let columns = max(1, min(columns, mins.count))
        var assignment = Array(repeating: 0, count: tight.count)
        func works() -> Bool {
            var widths = Array(repeating: CGFloat(0), count: columns), heights = Array(repeating: -gap, count: columns)
            var used = Array(repeating: false, count: columns)
            for (k, c) in assignment.enumerated() {
                widths[c] = max(widths[c], tight[k].width)
                heights[c] += max(tight[k].height, sliver) + gap
                used[c] = true
            }
            // The windows without a minimum go where there's height left, or in a column of their own.
            for _ in 0..<loose {
                if let c = used.indices.filter({ used[$0] && area.height - heights[$0] >= sliver + gap })
                    .max(by: { heights[$0] > heights[$1] }) {
                    heights[c] += sliver + gap
                } else if let c = used.firstIndex(of: false) {
                    used[c] = true
                    widths[c] = sliver
                    heights[c] = sliver
                } else {
                    return false
                }
            }
            let n = used.filter { $0 }.count
            return zip(widths, used).reduce(0) { $0 + ($1.1 ? $1.0 : 0) } + gap * CGFloat(n - 1) <= area.width
                && zip(heights, used).allSatisfy { !$1 || $0 <= area.height }
        }
        // Every way of putting them in columns (at most 4⁶ of them).
        while true {
            if works() { return true }
            var k = 0
            while k < assignment.count {
                assignment[k] += 1
                if assignment[k] < columns { break }
                assignment[k] = 0
                k += 1
            }
            if k == assignment.count { return false }
        }
    }

    /// The same windows in the same columns and stacks, at the same shares (to a hundredth).
    public static func sameArrangement(_ a: Layout?, _ b: Layout?) -> Bool {
        guard let a, let b, a.columns.count == b.columns.count, a.spotlight == nil, b.spotlight == nil else { return a == nil && b == nil }
        func shares(_ w: [Double]) -> [Double] {
            let total = w.reduce(0, +)
            return w.map { total > 0 ? $0 / total : 0 }
        }
        func close(_ x: [Double], _ y: [Double]) -> Bool { zip(shares(x), shares(y)).allSatisfy { abs($0 - $1) < 0.01 } }
        return zip(a.columns, b.columns).allSatisfy { $0.windows == $1.windows && close($0.weights, $1.weights) }
            && close(a.columns.map(\.weight), b.columns.map(\.weight))
    }

    /// The old way, and the one to beat: each window joins next to the last, then every column
    /// and stack gets an even share.
    static func evenly(_ windows: [WindowID], maxColumns: Int, limits: [WindowID: SizeLimits],
                       room: (area: CGSize, gap: CGFloat)?) -> Layout {
        var layout = Layout()
        for id in windows { layout.insert(id, near: layout.windows.last, maxColumns: maxColumns, limits: limits, room: room) }
        // Each window joining takes half of its neighbor's share, which leaves a stack of three
        // at a half and two quarters: even them out.
        layout.balance()
        return layout
    }

    /// The ways to put `n` windows in `count` columns, `most` to a column at most, the column on
    /// the left with the fewest (its tiles are the biggest).
    static func splits(_ n: Int, into count: Int, most: Int, least: Int = 1) -> [[Int]] {
        guard count > 0 else { return n == 0 ? [[]] : [] }
        guard least <= most, n >= least * count, n <= most * count else { return [] }
        return (least...min(most, n)).flatMap { first in
            splits(n - first, into: count - 1, most: most, least: first).map { [first] + $0 }
        }
    }

    /// Nudges the splits between neighboring columns, and between neighbors in a stack, a step at
    /// a time while the step makes the layout better, each step the best one there is.
    static func climb(_ start: Layout, score: (Layout) -> Double) -> (Layout, Double) {
        var layout = start, top = score(start)
        for _ in 0..<24 {
            var best: (Layout, Double)?
            for candidate in nudges(of: layout) {
                let s = score(candidate)
                if s > top * 1.002, s > best?.1 ?? 0 { best = (candidate, s) }
            }
            guard let best else { break }
            (layout, top) = best
        }
        return (layout, top)
    }

    /// Every layout one step from `layout`: a twentieth of the width from one column to its
    /// neighbor, or of a column's height from one window to the next. No share under a fifth or
    /// over seven tenths, and in a stack none taller than the one above it, so the bigger window
    /// is always on top and the stacks read the same way.
    static func nudges(of layout: Layout) -> [Layout] {
        let step = 0.05, low = 0.2, high = 0.7
        func shifted(_ shares: [Double], _ to: Int, _ from: Int, downward: Bool = false) -> [Double]? {
            let total = shares.reduce(0, +)
            guard total > 0 else { return nil }
            var s = shares.map { $0 / total }
            s[to] += step
            s[from] -= step
            guard s[to] <= high + 1e-9, s[from] >= low - 1e-9 else { return nil }
            if downward, zip(s, s.dropFirst()).contains(where: { $1 > $0 + 1e-9 }) { return nil }
            return s.map { ($0 * 1000).rounded() / 1000 }
        }
        var found: [Layout] = []
        let widths = layout.columns.map(\.weight)
        for i in 0..<max(0, layout.columns.count - 1) {
            for (to, from) in [(i, i + 1), (i + 1, i)] {
                guard let s = shifted(widths, to, from) else { continue }
                var next = layout
                for c in next.columns.indices { next.columns[c].weight = s[c] }
                found.append(next)
            }
        }
        for c in layout.columns.indices {
            let heights = layout.columns[c].weights
            for i in 0..<max(0, heights.count - 1) {
                for (to, from) in [(i, i + 1), (i + 1, i)] {
                    guard let s = shifted(heights, to, from, downward: true) else { continue }
                    var next = layout
                    next.columns[c].weights = s
                    found.append(next)
                }
            }
        }
        return found
    }
}
