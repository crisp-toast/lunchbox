import CoreGraphics

/// The sizes a window will take, as far as Tessel has seen. Most windows take any size
/// and fill their tile. Some can't be resized at all (a fixed-size window), some stop at a
/// minimum or maximum, and some keep their shape (Simulator, a video): those still tile,
/// but at the size they allow, centered in their slot, with their column sized to fit.
/// nil means no limit seen in that direction.
public struct SizeLimits: Equatable, Sendable, Codable {
    public var minWidth: CGFloat?
    public var maxWidth: CGFloat?
    public var minHeight: CGFloat?
    public var maxHeight: CGFloat?

    public init(minWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil, maxHeight: CGFloat? = nil) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
    }

    /// A window that can't be resized.
    public static func fixed(_ size: CGSize) -> SizeLimits {
        SizeLimits(minWidth: size.width, maxWidth: size.width, minHeight: size.height, maxHeight: size.height)
    }

    public var isEmpty: Bool { minWidth == nil && maxWidth == nil && minHeight == nil && maxHeight == nil }

    /// The nearest size to `size` the window takes.
    public func clamp(_ size: CGSize) -> CGSize {
        CGSize(width: Self.clamp(size.width, minWidth, maxWidth), height: Self.clamp(size.height, minHeight, maxHeight))
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat?, _ high: CGFloat?) -> CGFloat {
        var v = value
        if let high { v = min(v, high) }
        if let low { v = max(v, low) }
        return v
    }

    /// What a window that settled at `actual` after being asked for `target` says about its
    /// limits. Bigger than asked: it won't go smaller. Clearly smaller than asked: it won't go
    /// bigger. It took a size outside what was known: that limit was wrong, so it's dropped.
    ///
    /// A maximum sticks (Tessel stops asking for more), so it takes clear evidence: more than
    /// `slack` short (Terminal snaps to whole character cells, a few points short of what's
    /// asked), from a slot of a fair size, and not while the window grew the other way.
    public func learning(asked target: CGSize, got actual: CGSize, tolerance: CGFloat = 2, slack: CGFloat = 24) -> SizeLimits {
        var next = self
        let grewW = actual.width > target.width + tolerance, grewH = actual.height > target.height + tolerance
        Self.learn(&next.minWidth, &next.maxWidth, asked: target.width, got: actual.width, tolerance: tolerance, slack: slack,
                   maxAllowed: !grewH)
        Self.learn(&next.minHeight, &next.maxHeight, asked: target.height, got: actual.height, tolerance: tolerance, slack: slack,
                   maxAllowed: !grewW)
        return next
    }

    private static func learn(_ low: inout CGFloat?, _ high: inout CGFloat?, asked: CGFloat, got: CGFloat,
                              tolerance: CGFloat, slack: CGFloat, maxAllowed: Bool) {
        if got > asked + tolerance {
            low = got
            if let h = high, h < got - tolerance { high = nil }
        } else if got < asked - slack {
            guard maxAllowed, asked >= 300 else { return }
            high = got
            if let l = low, l > got + tolerance { low = nil }
        } else if got >= asked - tolerance {
            if let h = high, got > h + tolerance { high = nil }
            if let l = low, got < l - tolerance { low = nil }
        }
    }
}

extension Layout {
    /// Splits `total` among items by `weights`, keeping each within its bounds: an item that
    /// would get less than its minimum or more than its maximum gets exactly that, and the
    /// others share what's left by weight. When every item is at its maximum the sizes add up
    /// to less than `total`; when the minimums don't fit they add up to more.
    static func distribute(_ total: CGFloat, weights: [Double], mins: [CGFloat], maxs: [CGFloat]) -> [CGFloat] {
        let n = weights.count
        guard n > 0 else { return [] }
        // Minimums that can't all fit (a dozen Finder windows in one column), leaving the others at
        // least a sliver each, shrink in proportion: every window gets most of what it needs, and
        // those that won't go that small overlap their neighbors a little, shared out evenly, rather
        // than a lot. Never off the screen, never zero.
        let unbounded = (0..<n).filter { mins[$0] <= 0 }.count
        let wanted = mins.reduce(0, +), spare = total - CGFloat(unbounded) * 80
        if wanted > spare {
            let scale = max(0, spare) / wanted
            return distribute(total, weights: weights, mins: mins.map { ($0 * scale).rounded(.down) }, maxs: maxs)
        }
        var settled = [CGFloat?](repeating: nil, count: n)
        for _ in 0...n {
            let free = (0..<n).filter { settled[$0] == nil }
            guard !free.isEmpty else { break }
            let remaining = total - settled.compactMap { $0 }.reduce(0, +)
            let weightSum = free.map { max(weights[$0], 0.0001) }.reduce(0, +)
            let shares = Dictionary(uniqueKeysWithValues: free.map { ($0, remaining * CGFloat(max(weights[$0], 0.0001) / weightSum)) })
            // Settle the items under their minimum first; only then those over their maximum.
            let under = free.filter { shares[$0]! < mins[$0] }
            let over = free.filter { shares[$0]! > maxs[$0] }
            if !under.isEmpty {
                for i in under { settled[i] = mins[i] }
            } else if !over.isEmpty {
                for i in over { settled[i] = maxs[i] }
            } else {
                for i in free { settled[i] = shares[i]! }
                break
            }
        }
        // Whole points; whatever rounding leaves over goes to the last item that isn't held to a bound.
        var sizes = settled.map { ($0 ?? 0).rounded() }
        let flexible = (0..<n).filter { sizes[$0] > mins[$0] && sizes[$0] < maxs[$0] }
        if let last = flexible.last {
            let leftover = total - sizes.reduce(0, +)
            if abs(leftover) < CGFloat(n) + 1 { sizes[last] += leftover }
        }
        return sizes
    }
}
