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

    /**
     * The bundled files as Core Graphics fonts, read once; a file missing from the build or that won't
     * read is left out, and said so in the app menu's subtitle log. Read from their bytes rather than
     * by name, so nothing hangs on what PostScript names the files carry or on registering them.
     */
    private static let files: [String: CGFont] = {
        var out: [String: CGFont] = [:]
        var missing: [String] = []
        for file in Set(bundled.values.flatMap { [$0.regular, $0.bold, $0.italic, $0.boldItalic] }).sorted() {
            guard let url = Bundle.main.url(forResource: file, withExtension: "ttf")
                    ?? Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts"),
                  let provider = CGDataProvider(url: url as CFURL),
                  let font = CGFont(provider) else {
                missing.append(file)
                continue
            }
            out[file] = font
        }
        EngineLogBook.note(missing.isEmpty
            ? "[subtitles] the app's fonts read: \(out.keys.sorted().joined(separator: ", "))"
            : "[subtitles] the app's fonts not in the build or unreadable: \(missing.joined(separator: ", "))")
        return out
    }()

    /// Names already said in the log, so each is said once.
    private static var told = Set<String>()

    static var names: Set<String> { Set(candidates.keys) }

    /**
     * The font for the page's name at a size and style, or nil when neither the app nor the device has one.
     *
     * Sized to look as large as the system font the default draws in at `size`, not just to share its
     * point size: a face's letters fill a different share of its em. As a share of the em (x-height,
     * then cap height), Comic Neue and Dancing Script read from App/Fonts' files, the others the faces'
     * published metrics: the system font (SF) 0.53 and 0.71, Helvetica Neue 0.52 and 0.71, Menlo 0.55
     * and 0.73, Times New Roman 0.45 and 0.66, Courier New 0.42 and 0.57, Comic Neue 0.49 and 0.67,
     * Dancing Script 0.33 and 0.72. At one point size Courier New and Dancing Script's
     * lower case came out a fifth and a third smaller than the default's. Each face is scaled by the
     * geometric mean of the two ratios, so neither its lower case nor its capitals run far from the
     * default's (a script's tall capitals over its small x-height are why x-height alone isn't used).
     * Both metrics grow with the size, so the factor is the same at every Font size the page offers.
     */
    @MainActor
    static func font(_ name: String?, size: CGFloat, bold: Bool, italic: Bool) -> UIFont? {
        guard let name, let first = make(name, size: size, bold: bold, italic: italic) else {
            if let name, told.insert(name).inserted {
                EngineLogBook.note("[subtitles] \(name) text drawn in the system font, none of its fonts here")
            }
            return nil
        }
        let reference = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
        let factor = matchingFactor(first, to: reference)
        let chosen = factor == 1 ? first : (make(name, size: size * factor, bold: bold, italic: italic) ?? first)
        if told.insert(name).inserted {
            EngineLogBook.note(String(format: "[subtitles] %@ text drawn in %@, at %.2f times the size to match the default's",
                                      name, chosen.fontName, factor))
        }
        return chosen
    }

    /// How much larger `font` is drawn to look the size of `reference` (see `font`); 1 when a metric is missing.
    static func matchingFactor(_ font: UIFont, to reference: UIFont) -> CGFloat {
        guard font.xHeight > 0, font.capHeight > 0, reference.xHeight > 0, reference.capHeight > 0 else { return 1 }
        let factor = ((reference.xHeight / font.xHeight) * (reference.capHeight / font.capHeight)).squareRoot()
        return factor.isFinite && factor > 0 ? factor : 1
    }

    @MainActor
    private static func make(_ name: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont? {
        if let bundled = bundledFont(name, size: size, bold: bold, italic: italic) { return bundled }
        guard let set = candidates[name] else { return nil }
        let list = bold && italic ? set.boldItalic : bold ? set.bold : italic ? set.italic : set.regular
        return (list + set.regular).lazy.compactMap { UIFont(name: $0, size: size) }.first
    }

    private static func bundledFont(_ name: String, size: CGFloat, bold: Bool, italic: Bool) -> UIFont? {
        guard let names = bundled[name] else { return nil }
        let file = bold && italic ? names.boldItalic : bold ? names.bold : italic ? names.italic : names.regular
        let found = files[file].map { ($0, file) } ?? files[names.regular].map { ($0, names.regular) }
        guard let (graphics, used) = found else { return nil }
        // The variable file has one face for every weight; bold is its weight axis set.
        var attributes: CTFontDescriptor?
        if bold, used == names.regular, names.bold == names.regular {
            attributes = CTFontDescriptorCreateWithAttributes([
                kCTFontVariationAttribute as String: [NSNumber(value: weightAxis): NSNumber(value: variableBoldWeight)],
            ] as CFDictionary)
        }
        return CTFontCreateWithGraphicsFont(graphics, size, nil, attributes) as UIFont
    }
}
