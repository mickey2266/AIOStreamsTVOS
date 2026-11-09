import AetherHost
import UIKit

/**
 * Subtitles over the video, in the page's style. AetherEngine decodes them
 * (text as styled runs, and PGS, DVB and DVD pictures) and leaves the drawing
 * to the app.
 *
 * ASS and SSA tracks go to libass (`AssRenderer`), as mpv drew them, with the
 * file's own styles, unless the page forces its style on them: then they're
 * drawn as plain text in the page's style, like the rest.
 *
 * Cues carry the source's own timestamps, so they're matched against the
 * engine's source clock, less the page's subtitle delay. The page's sizes are
 * mpv's, in units of a 720-line screen, and are scaled to the screen here, so
 * a film's shape doesn't change them; positions are still the picture's.
 */
@MainActor
final class SubtitleOverlay: UIView {
    /// The rectangle the picture fills, in this view's coordinates.
    var videoRect: @MainActor () -> CGRect = { .zero }

    /// Seconds; positive shows them later, as mpv's `sub-delay`.
    var delay: Double = 0 {
        didSet { if delay != oldValue { refresh() } }
    }

    private var cues: [SubtitleCue] = []
    private var time: Double = 0
    private var look: SubtitleLook?
    private var cropped = false
    /// What's drawn now, so a tick that changes nothing draws nothing.
    private var drawn: (ids: [Int], rect: CGRect, bounds: CGRect)?

    /// The selected track, so a switch between two with the same header still starts over.
    private var assTrackID: Int?
    /// The track's cues are raw ASS event lines (`ReadOrder,Layer,Style,...,Text`).
    private var rawASS = false
    /// The ASS track's header, which libass needs to draw it.
    private var assHeader: String?
    private lazy var ass = AssRenderer()
    private var assLoaded = false
    private let assView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        assView.isHidden = true
        addSubview(assView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    func setCues(_ cues: [SubtitleCue]) {
        self.cues = cues
        if assLoaded { ass.add(Self.events(cues)) }
        refresh()
    }

    func setTime(_ seconds: Double) {
        time = seconds
        refresh()
    }

    func setStyle(_ style: Style) {
        look = style.subtitles
        cropped = style.fit == .crop
        updateASS()
        redraw()
    }

    /**
     * The selected track, as far as drawing goes: `raw` when the engine hands
     * its events over as ASS event lines, and the header that styles them.
     */
    func setASSTrack(id: Int?, raw: Bool, header: String?) {
        guard id != assTrackID || raw != rawASS || header != assHeader else { return }
        assTrackID = id
        rawASS = raw
        assHeader = header
        // Another track's events and styles: start over.
        if assLoaded {
            assLoaded = false
            ass.unload()
        }
        updateASS()
        redraw()
    }

    /// The playing file's attached fonts, for libass. A new set starts the track over with them.
    func setFonts(_ fonts: [FontAttachment]) {
        guard ass.setFonts(fonts), assLoaded else { return }
        assLoaded = false
        updateASS()
        redraw()
    }

    func reset() {
        cues = []
        time = 0
        setASSTrack(id: nil, raw: false, header: nil)
        redraw()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    /// libass draws when the track is ASS with its header, and the page leaves the file its styles.
    private var drawsWithLibass: Bool {
        rawASS && assHeader != nil && look?.forceStyle != true
    }

    /// Loads or drops the libass track to match what should draw it.
    private func updateASS() {
        if drawsWithLibass, let assHeader {
            guard !assLoaded else { return }
            assLoaded = true
            ass.load(header: assHeader)
            ass.add(Self.events(cues))
        } else if assLoaded {
            assLoaded = false
            ass.unload()
        }
        assView.image = nil
        assView.isHidden = true
        clearText()
        drawn = nil
    }

    /// Removes the cues drawn as views, leaving libass's picture.
    private func clearText() {
        subviews.forEach { if $0 !== assView { $0.removeFromSuperview() } }
    }

    /// Draws again even if the same cues show, as after a style change.
    private func redraw() {
        drawn = nil
        refresh()
    }

    private func refresh() {
        if assLoaded {
            renderASS()
            return
        }
        let at = time - delay
        let active = cues
            .filter { $0.startTime <= at && at < $0.endTime }
            .sorted { $0.startTime < $1.startTime }
        let rect = videoRect()
        let ids = active.map(\.id)
        if let drawn, drawn.ids == ids, drawn.rect == rect, drawn.bounds == bounds { return }
        drawn = (ids, rect, bounds)
        clearText()
        guard !active.isEmpty, rect.width > 0, rect.height > 0 else { return }

        var stacks: [Int: CGFloat] = [:]
        for cue in active {
            switch cue.body {
            case .image(let image):
                place(image, in: rect)
            case .text(let raw):
                // An ASS track drawn in the page's style: its event lines, as plain text.
                let text = rawASS ? Self.plainText(fromASSEvents: raw) : raw
                guard !text.isEmpty else { continue }
                placeText(attributed([SubtitleRun(text: text)]), cue.placement, in: rect, stacks: &stacks)
            case .richText(let runs):
                placeText(attributed(runs.map { SubtitleRun($0) }), cue.placement, in: rect, stacks: &stacks)
            }
        }
    }

    // MARK: libass

    /**
     * libass draws over the whole view, with the picture's edges as its
     * margins, so a script's positions land on the picture and, cropped, its
     * dialogue stays on the screen. Pixels at the screen's scale, up to 2.
     */
    private func renderASS() {
        let picture = videoRect()
        guard picture.width > 0, picture.height > 0, bounds.width > 0, bounds.height > 0 else {
            assView.isHidden = true
            return
        }
        let scale = min(2, max(1, traitCollection.displayScale))
        func pixels(_ value: CGFloat) -> Int32 { Int32((value * scale).rounded()) }
        let layout = AssRenderer.Layout(
            frameWidth: pixels(bounds.width),
            frameHeight: pixels(bounds.height),
            top: pixels(picture.minY - bounds.minY),
            bottom: pixels(bounds.maxY - picture.maxY),
            left: pixels(picture.minX - bounds.minX),
            right: pixels(bounds.maxX - picture.maxX),
            useMargins: cropped,
            // 20% under the file's sizes, which read large on a TV, and the text's own 10% on top.
            fontScale: (look?.scale ?? 1) * 0.8 * Double(Self.textScale),
            // The page's Height, and its lift above the controls while they show, as for text. libass takes
            // 0 to 100 up from the bottom; below the usual place stays at it, as libass moves only up.
            linePosition: min(100, max(0, 100 - (look?.position ?? 100)))
        )
        let milliseconds = Int64(((time - delay) * 1000).rounded())
        ass.render(at: milliseconds, layout: layout) { [weak self] output in
            self?.show(output, scale: scale)
        }
    }

    private func show(_ output: AssRenderer.Output, scale: CGFloat) {
        guard assLoaded else { return }
        switch output {
        case .unchanged:
            break
        case .empty:
            assView.image = nil
            assView.isHidden = true
        case .frame(let image, let rect):
            assView.image = UIImage(cgImage: image, scale: scale, orientation: .up)
            assView.frame = CGRect(
                x: bounds.minX + rect.minX / scale,
                y: bounds.minY + rect.minY / scale,
                width: rect.width / scale,
                height: rect.height / scale
            )
            assView.isHidden = false
        }
    }

    /// The text cues' event lines, for libass.
    private static func events(_ cues: [SubtitleCue]) -> [SubtitleCueEvent] {
        cues.compactMap { cue in
            guard case .text(let text) = cue.body else { return nil }
            return SubtitleCueEvent(text: text, start: cue.startTime, end: cue.endTime)
        }
    }

    /**
     * The words of ASS event lines (`ReadOrder,Layer,Style,Name,MarginL,
     * MarginR,MarginV,Effect,Text`), one line each: override blocks dropped,
     * `\N` and `\n` as line breaks, `\h` as a space. Drawings (`\p1` and up)
     * aren't words, so their lines go.
     */
    static func plainText(fromASSEvents raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> String? in
            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, Int(fields[0]) != nil else {
                return line.trimmingCharacters(in: .whitespaces)
            }
            let body = fields[8]
            if body.range(of: #"\\p[1-9]"#, options: .regularExpression) != nil { return nil }
            var text = ""
            var depth = 0
            for character in body {
                if character == "{" {
                    depth += 1
                } else if character == "}", depth > 0 {
                    depth -= 1
                } else if depth == 0 {
                    text.append(character)
                }
            }
            text = text
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        .joined(separator: "\n")
    }

    // MARK: Pictures

    /**
     * A picture's position is a fraction of the source's canvas, which is laid
     * over the picture width-aligned and centred, so a cue lands where the disc
     * put it, the black bars included. Without a canvas, it's the picture.
     */
    private func place(_ image: SubtitleImage, in rect: CGRect) {
        var canvas = rect
        if image.canvasSize.width > 0, image.canvasSize.height > 0 {
            let scale = rect.width / image.canvasSize.width
            let height = image.canvasSize.height * scale
            canvas = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
        let view = UIImageView(image: UIImage(cgImage: image.cgImage))
        view.contentMode = .scaleToFill
        let placed = CGRect(
            x: canvas.minX + image.position.minX * canvas.width,
            y: canvas.minY + image.position.minY * canvas.height,
            width: image.position.width * canvas.width,
            height: image.position.height * canvas.height
        )
        view.frame = Self.scaled(placed, by: Self.pictureScale * CGFloat(look?.scale ?? 1), in: canvas)
        addSubview(view)
    }

    /// Pictures at the page's Normal size: 20% under the disc's own, which reads large on a TV.
    /// The page's subtitle size (Small to Huge, also stepped from the player's controls) scales from there.
    private static let pictureScale: CGFloat = 0.8

    /**
     * A picture resized about the edge it belongs to, so it stays where the disc put it: one in the
     * canvas's lower half keeps its bottom edge, one in the upper half its top, and each keeps its
     * centre across. Kept inside the canvas when it grows.
     */
    static func scaled(_ rect: CGRect, by factor: CGFloat, in canvas: CGRect) -> CGRect {
        guard factor > 0, factor != 1 else { return rect }
        let width = rect.width * factor
        let height = rect.height * factor
        var x = rect.midX - width / 2
        var y = rect.midY >= canvas.midY ? rect.maxY - height : rect.minY
        if width <= canvas.width { x = min(max(x, canvas.minX), canvas.maxX - width) }
        if height <= canvas.height { y = min(max(y, canvas.minY), canvas.maxY - height) }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Text

    /// A run of text, from a plain cue or one of a styled cue's runs.
    private struct SubtitleRun {
        var text: String
        var color: SubtitleColor?
        var bold = false
        var italic = false
        var underline = false
        var strike = false

        init(text: String) {
            self.text = text
        }

        init(_ run: SubtitleTextRun) {
            text = run.text
            color = run.color
            bold = run.isBold
            italic = run.isItalic
            underline = run.isUnderlined
            strike = run.isStruckThrough
        }
    }

    /// Sizes at sub-scale 1, in units of a 720-line screen: 36 units is 5% of the screen's height,
    /// the size the page's own player draws its subtitles at (`scale * 5vh`); the text here is
    /// `textScale` of that, as it reads large on a TV. The margin is mpv's.
    private static let fontUnits: CGFloat = 36 * textScale
    /// Text subtitles, plain and ASS alike, against the page's sizes: 10% under them.
    private static let textScale: CGFloat = 0.9
    private static let marginUnits: CGFloat = 22

    /// One unit of a 720-line screen. Sized to the screen, not the picture, as mpv's `sub-scale-by-window`
    /// does, so a 2.39:1 film's letterbox doesn't make its subtitles smaller than a 16:9 episode's.
    private var unit: CGFloat { bounds.height / 720 }

    /**
     * A cue's text, drawn as two layers the way libass draws it: the outline
     * behind, and the fill on top of it. The `back` layer is the glyphs filled
     * and stroked in the outline colour; a stroke straddles the glyph edge, so
     * the fill laid over it hides the inner half and leaves the outline outside
     * the letters, at full letter width. Nil when there's no outline.
     */
    private struct CueText {
        var front: NSAttributedString
        var back: NSAttributedString?
    }

    private func attributed(_ runs: [SubtitleRun]) -> CueText {
        let look = look
        let size = max(12, Self.fontUnits * CGFloat(look?.scale ?? 1) * unit)
        let fill = look.flatMap { Self.parseColor($0.color) } ?? .white
        let outlineColor = look.flatMap { Self.parseColor($0.outlineColor) } ?? .black
        let outline = CGFloat(look?.outlineSize ?? 1.65) * unit
        let shadowSize = CGFloat(look?.shadowSize ?? 0) * unit
        let forced = look?.forceStyle == true

        var shadow: NSShadow?
        if shadowSize > 0 {
            let made = NSShadow()
            made.shadowColor = outlineColor
            made.shadowOffset = CGSize(width: shadowSize, height: shadowSize)
            made.shadowBlurRadius = 0
            shadow = made
        }

        let text = NSMutableAttributedString()
        let back = NSMutableAttributedString()
        for run in runs {
            var traits: UIFontDescriptor.SymbolicTraits = []
            // The page's style, when forced, decides the weight too: a cue's own bold made some tracks
            // heavier and larger-looking than the rest at the same size.
            if (run.bold && !forced) || look?.bold == true { traits.insert(.traitBold) }
            if run.italic && !forced { traits.insert(.traitItalic) }
            var font: UIFont
            if let chosen = SubtitleFonts.font(
                look?.font, size: size, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic)
            ) {
                font = chosen
            } else {
                font = UIFont.systemFont(ofSize: size, weight: traits.contains(.traitBold) ? .bold : .medium)
                if traits.contains(.traitItalic), let italic = font.fontDescriptor.withSymbolicTraits(traits) {
                    font = UIFont(descriptor: italic, size: size)
                }
            }
            // The cue's own colour, unless the page's style overrides the file's.
            var color = fill
            if !forced, let own = run.color { color = Self.uiColor(own) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if run.underline && !forced { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strike && !forced { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if outline > 0 {
                // The outline layer: filled and stroked in the outline colour. A negative width
                // fills and strokes; the stroke straddles the edge, so it's twice the outline.
                // The shadow goes here, so it's cast by the outlined shape once.
                var outlined = attributes
                outlined[.foregroundColor] = outlineColor
                outlined[.strokeColor] = outlineColor
                outlined[.strokeWidth] = -min(30, 2 * outline / size * 100)
                if let shadow { outlined[.shadow] = shadow }
                back.append(NSAttributedString(string: run.text, attributes: outlined))
            } else if let shadow {
                attributes[.shadow] = shadow
            }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return CueText(front: text, back: outline > 0 ? back : nil)
    }

    /**
     * Bottom-aligned cues stack upwards from the page's position, top-aligned
     * ones down from the top, as libass does. ASS placement: `\an` 7–9 top,
     * 4–6 middle, 1–3 bottom; 1, 4 and 7 left, 3, 6 and 9 right.
     */
    private func placeText(
        _ cue: CueText, _ placement: SubtitleTextPlacement?, in picture: CGRect,
        stacks: inout [Int: CGFloat]
    ) {
        let text = cue.front
        guard text.length > 0 else { return }
        // Cropped, the picture runs off the screen; the text stays on it.
        let rect = cropped ? picture.intersection(bounds) : picture
        let margin = Self.marginUnits * unit
        let alignment = placement?.alignment ?? 2
        let row = (alignment - 1) / 3  // 0 bottom, 1 middle, 2 top
        let column = (alignment - 1) % 3  // 0 left, 1 centre, 2 right

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = column == 0 ? .left : column == 2 ? .right : .center
        paragraph.lineBreakMode = .byWordWrapping
        func makeLabel(_ text: NSAttributedString) -> UILabel {
            let aligned = NSMutableAttributedString(attributedString: text)
            aligned.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: aligned.length))
            let label = UILabel()
            label.numberOfLines = 0
            label.attributedText = aligned
            return label
        }
        // Both layers hold the same glyphs in the same font, so they wrap and measure alike.
        let label = makeLabel(text)
        let outlineLabel = cue.back.map(makeLabel)
        let maxWidth = rect.width - 2 * margin
        var size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        size.width = min(size.width, maxWidth)

        let box = UIView()
        let pad: CGFloat = look?.box == true ? 0.25 * Self.fontUnits * CGFloat(look?.scale ?? 1) * unit : 0
        if look?.box == true, let back = look.flatMap({ Self.parseColor($0.backColor) }) {
            box.backgroundColor = back
            box.layer.cornerRadius = pad / 2
        }
        let boxSize = CGSize(width: size.width + 2 * pad, height: size.height + pad)

        var origin = CGPoint.zero
        switch column {
        case 0: origin.x = rect.minX + margin
        case 2: origin.x = rect.maxX - margin - boxSize.width
        default: origin.x = rect.midX - boxSize.width / 2
        }
        if let anchor = placement?.position {
            // An explicit `\pos`, as a fraction of the picture, at the point the alignment names.
            let point = CGPoint(x: picture.minX + anchor.x * picture.width, y: picture.minY + anchor.y * picture.height)
            origin.x = point.x - CGFloat(column) / 2 * boxSize.width
            origin.y = point.y - CGFloat(2 - row) / 2 * boxSize.height
        } else {
            switch row {
            case 2:
                let top = stacks[alignment] ?? rect.minY + margin
                origin.y = top
                stacks[alignment] = top + boxSize.height
            case 1:
                origin.y = rect.midY - boxSize.height / 2
            default:
                let position = CGFloat(look?.position ?? 100) / 100
                let bottom = stacks[alignment] ?? min(rect.maxY, picture.minY + picture.height * position) - margin
                origin.y = bottom - boxSize.height
                stacks[alignment] = origin.y
            }
        }
        box.frame = CGRect(origin: origin, size: boxSize)
        let labelFrame = CGRect(x: pad, y: pad / 2, width: size.width, height: size.height)
        if let outlineLabel {
            outlineLabel.frame = labelFrame
            box.addSubview(outlineLabel)
        }
        label.frame = labelFrame
        box.addSubview(label)
        addSubview(box)
    }

    /// `#AARRGGBB` or `#RRGGBB`, as mpv reads them.
    private static func parseColor(_ text: String) -> UIColor? {
        guard text.hasPrefix("#"), let value = UInt64(text.dropFirst(), radix: 16) else { return nil }
        let hex = text.count - 1
        let alpha = hex == 8 ? CGFloat((value >> 24) & 0xff) / 255 : 1
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: alpha
        )
    }

    private static func uiColor(_ color: SubtitleColor) -> UIColor {
        UIColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }
}
