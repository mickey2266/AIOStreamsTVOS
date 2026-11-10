import CoreText
import UIKit

/// The page's subtitle fonts (Android's names) as tvOS fonts. Each name lists PostScript names in the
/// order of preference, like the page's CSS stacks; the first the device has is used, and a name with
/// none falls back to the system font.
///
/// tvOS has none of the casual or script faces iOS and macOS have (Marker Felt, Chalkboard, Snell
/// Roundhand, Zapfino), so Casual and Cursive fell back to the system font and looked like Sans serif.
/// They come with the app instead, from App/Fonts, both under the SIL Open Font License (the licences
/// beside them): Comic Neue for Casual, the desktop app's Comic Sans MS redrawn, and Dancing Script
/// for Cursive, a script in place of its Segoe Script and Snell Roundhand.
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

    /// The app's own faces for a name, by file in App/Fonts, tried before the device's.
    private static let bundled: [String: (regular: String, bold: String, italic: String, boldItalic: String)] = [
        "casual": ("ComicNeue-Regular", "ComicNeue-Bold", "ComicNeue-Italic", "ComicNeue-BoldItalic"),
        // One variable file, its weight set for bold; a script has no italic of its own.
        "cursive": ("DancingScript", "DancingScript", "DancingScript", "DancingScript"),
    ]

    /// Dancing Script's weight axis, `wght`, and the weight its bold is drawn at.
    private static let weightAxis = 0x7767_6874
    private static let variableBoldWeight = 700.0

    /// The bundled files' descriptors, read once; a file missing from the build is left out.
    private static let descriptors: [String: CTFontDescriptor] = {
        var out: [String: CTFontDescriptor] = [:]
        for file in Set(bundled.values.flatMap { [$0.regular, $0.bold, $0.italic, $0.boldItalic] }) {
            guard let url = Bundle.main.url(forResource: file, withExtension: "ttf"),
                  let found = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let first = found.first else {
                NSLog("[subtitles] font %@.ttf isn't in the app", file)
                continue
            }
            out[file] = first
        }
        return out
    }()

    static var names: Set<String> { Set(candidates.keys) }

    /// The font for the page's name at a size and style, or nil when neither the app nor the device has one.
    static func font(_ name: String?, size: CGFloat, bold: Bool, italic: Bool) -> UIFont? {
        guard let name else { return nil }
        if let own = bundledFont(name, size: size, bold: bold, italic: italic) { return own }
        guard let set = candidates[name] else { return nil }
        let list = bold && italic ? set.boldItalic : bold ? set.bold : italic ? set.italic : set.regular
        for postScript in list + set.regular {
            if let font = UIFont(name: postScript, size: size) { return font }
        }
        return nil
    }

    private static func bundledFont(_ name: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont? {
        guard let files = bundled[name] else { return nil }
        let file = bold && italic ? files.boldItalic : bold ? files.bold : italic ? files.italic : files.regular
        guard var descriptor = descriptors[file] ?? descriptors[files.regular] else { return nil }
        // The variable file has one face for every weight; bold is its weight axis set.
        if bold, file == files.regular {
            descriptor = CTFontDescriptorCreateCopyWithVariation(
                descriptor, NSNumber(value: weightAxis) as CFNumber, CGFloat(variableBoldWeight))
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as UIFont
    }
}
