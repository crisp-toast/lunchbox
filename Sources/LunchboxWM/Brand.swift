import AppKit

/// How the name looks: LunchboxWM, with "WM" in the brand's blue (the site's accent and the
/// icon's lunchbox), lighter in dark mode so it still stands out.
enum Brand {
    static let name = "LunchboxWM"

    static let blue = NSColor(name: "LunchboxWMBlue") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.43, green: 0.61, blue: 1, alpha: 1)   // #6e9bff
            : NSColor(srgbRed: 0.18, green: 0.42, blue: 1, alpha: 1)   // #2f6bff
    }

    /// `text` in `font`, with the "WM" of every "LunchboxWM" in it blue.
    static func wordmark(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
        let styled = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        var rest = text.startIndex..<text.endIndex
        while let found = text.range(of: name, range: rest) {
            let wm = text.index(found.upperBound, offsetBy: -2)..<found.upperBound
            styled.addAttribute(.foregroundColor, value: blue, range: NSRange(wm, in: text))
            rest = found.upperBound..<text.endIndex
        }
        return styled
    }
}
