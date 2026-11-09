import UIKit

/// The page's subtitle fonts (Android's names) as tvOS fonts. Each name lists PostScript names in the
/// order of preference, like the page's CSS stacks; the first the device has is used, and a name with
/// none falls back to the system font.
enum SubtitleFonts {
    private static let candidates: [String: (regular: [String], bold: [String], italic: [String], boldItalic: [String])] = [
        "sans-serif": (
            ["HelveticaNeue"], ["HelveticaNeue-Bold"], ["HelveticaNeue-Italic"], ["HelveticaNeue-BoldItalic"]
        ),
        "serif": (
            ["TimesNewRomanPSMT", "Georgia"], ["TimesNewRomanPS-BoldMT", "Georgia-Bold"],
            ["TimesNewRomanPS-ItalicMT", "Georgia-Italic"], ["TimesNewRomanPS-BoldItalicMT", "Georgia-BoldItalic"]
        ),
        "monospace": (
            ["Menlo-Regular", "Courier"], ["Menlo-Bold", "Courier-Bold"],
            ["Menlo-Italic", "Courier-Oblique"], ["Menlo-BoldItalic", "Courier-BoldOblique"]
        ),
        "serif-monospace": (
            ["CourierNewPSMT", "Courier"], ["CourierNewPS-BoldMT", "Courier-Bold"],
            ["CourierNewPS-ItalicMT", "Courier-Oblique"], ["CourierNewPS-BoldItalicMT", "Courier-BoldOblique"]
        ),
        "casual": (
            ["MarkerFelt-Thin", "ChalkboardSE-Regular"], ["MarkerFelt-Wide", "ChalkboardSE-Bold"],
            ["MarkerFelt-Thin"], ["MarkerFelt-Wide"]
        ),
        "cursive": (
            ["SnellRoundhand", "Zapfino", "MarkerFelt-Thin"], ["SnellRoundhand-Bold", "SnellRoundhand"],
            ["SnellRoundhand"], ["SnellRoundhand-Bold"]
        ),
    ]

    static var names: Set<String> { Set(candidates.keys) }

    /// The font for the page's name at a size and style, or nil when the device has none of them.
    static func font(_ name: String?, size: CGFloat, bold: Bool, italic: Bool) -> UIFont? {
        guard let name, let set = candidates[name] else { return nil }
        let list = bold && italic ? set.boldItalic : bold ? set.bold : italic ? set.italic : set.regular
        for postScript in list + set.regular {
            if let font = UIFont(name: postScript, size: size) { return font }
        }
        return nil
    }
}
