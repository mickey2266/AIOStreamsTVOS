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

    /// The font for the page's name at a size and style, or nil when neither the app nor the device has one.
    @MainActor
    static func font(_ name: String?, size: CGFloat, bold: Bool, italic: Bool) -> UIFont? {
        guard let name else { return nil }
        var chosen = bundledFont(name, size: size, bold: bold, italic: italic)
        if chosen == nil, let set = candidates[name] {
            let list = bold && italic ? set.boldItalic : bold ? set.bold : italic ? set.italic : set.regular
            chosen = (list + set.regular).lazy.compactMap { UIFont(name: $0, size: size) }.first
        }
        if told.insert(name).inserted {
            EngineLogBook.note("[subtitles] \(name) text drawn in \(chosen?.fontName ?? "the system font, none of its fonts here")")
        }
        return chosen
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
