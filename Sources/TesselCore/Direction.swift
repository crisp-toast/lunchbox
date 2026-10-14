import CoreGraphics

/// A window ID as reported by the window server (CGWindowID).
public typealias WindowID = UInt32

public enum Direction: String, CaseIterable, Sendable {
    case left, right, up, down

    public var isHorizontal: Bool { self == .left || self == .right }

    public var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }
}

/// Finds the rectangle that lies nearest to `source` in `direction`.
///
/// Rectangles use top-left-origin coordinates (y grows downward), the same space
/// the Accessibility API uses. A candidate qualifies when it starts beyond the
/// source's leading edge (with a little tolerance for gaps and rounding), or,
/// failing that, when its center is past the source's center. Among qualifiers,
/// ones that overlap the source on the other axis win, then the closest.
public func nearest<Key: Hashable>(
    from source: CGRect,
    direction: Direction,
    in candidates: [Key: CGRect],
    tolerance: CGFloat = 24
) -> Key? {
    func score(_ r: CGRect, strict: Bool) -> (Bool, CGFloat, CGFloat, CGFloat)? {
        let distance: CGFloat
        let overlap: CGFloat
        let offAxis: CGFloat
        switch direction {
        case .right:
            if strict ? r.minX < source.maxX - tolerance : r.midX <= source.midX + 1 { return nil }
            distance = max(0, r.minX - source.maxX)
            overlap = min(r.maxY, source.maxY) - max(r.minY, source.minY)
            offAxis = abs(r.midY - source.midY)
        case .left:
            if strict ? r.maxX > source.minX + tolerance : r.midX >= source.midX - 1 { return nil }
            distance = max(0, source.minX - r.maxX)
            overlap = min(r.maxY, source.maxY) - max(r.minY, source.minY)
            offAxis = abs(r.midY - source.midY)
        case .down:
            if strict ? r.minY < source.maxY - tolerance : r.midY <= source.midY + 1 { return nil }
            distance = max(0, r.minY - source.maxY)
            overlap = min(r.maxX, source.maxX) - max(r.minX, source.minX)
            offAxis = abs(r.midX - source.midX)
        case .up:
            if strict ? r.maxY > source.minY + tolerance : r.midY >= source.midY - 1 { return nil }
            distance = max(0, source.minY - r.maxY)
            overlap = min(r.maxX, source.maxX) - max(r.minX, source.minX)
            offAxis = abs(r.midX - source.midX)
        }
        // Sort key: overlapping first, then nearest, then most centered, then top/left-most.
        let tieBreak = direction.isHorizontal ? r.minY : r.minX
        return (overlap > 0, distance, offAxis, tieBreak)
    }

    for strict in [true, false] {
        var best: (key: Key, score: (Bool, CGFloat, CGFloat, CGFloat))?
        for (key, rect) in candidates {
            guard let s = score(rect, strict: strict) else { continue }
            if let b = best {
                let better: Bool
                if s.0 != b.score.0 { better = s.0 }
                else if abs(s.1 - b.score.1) > 0.5 { better = s.1 < b.score.1 }
                else if abs(s.2 - b.score.2) > 0.5 { better = s.2 < b.score.2 }
                else { better = s.3 < b.score.3 }
                if better { best = (key, s) }
            } else {
                best = (key, s)
            }
        }
        if let best { return best.key }
    }
    return nil
}
