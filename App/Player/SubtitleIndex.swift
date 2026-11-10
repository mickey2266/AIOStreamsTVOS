import Foundation

/**
 * When the file's own subtitle lines show, read from its index rather than played: the page's
 * `player-subtitle-index`, and every line of the track an added subtitle is lined up against at once.
 * AIOStreams' desktop and Android apps do the same with `subtitle_timelines` from AIOStreams/media
 * (`container/src/subtitles.rs`, rev 87dee2cc), which this follows for Matroska and for MP4 and MOV.
 * Matroska: muxers list every subtitle frame in the Cues, most with its duration, so a few range
 * requests give the whole file's lines; a PGS track lists the display set that shows each line and the
 * one that clears it. MP4: the sample tables list every subtitle sample, and the gaps between lines
 * as empty ones (text, WebVTT and 3GPP timed text; other formats come back with no lines).
 * A fragmented MP4 has no such tables, and has no index.
 *
 * With every line from the start, the page's match sees the whole file, so it settles in a moment and
 * finds a subtitle timed for another frame rate, whose drift a few minutes of lines hide. The player's
 * own decode gives a picture subtitle's lines only as it plays, with ends it can still change.
 */
enum SubtitleIndex {
    /// One of the file's subtitle tracks, in file order, and when its lines show, in milliseconds.
    /// `codec` is Matroska's codec ID, or the MP4 sample entry's four letters (`tx3g`, `wvtt`).
    struct Timeline {
        let number: UInt64
        let codec: String
        /// Pictures rather than text: Matroska's PGS, VobSub and DVB, MP4's `subp` tracks.
        let isPicture: Bool
        let lines: [(start: Double, end: Double)]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Every subtitle track of a Matroska or MP4 file in file order; a track the index leaves out has no lines.
    static func read(url: URL, headers: [String: String]) async throws -> [Timeline] {
        let reader = RangeReader(url: url, headers: headers)
        let first = try await reader.read(0, Self.head)
        if Array(first.prefix(4)) == [0x1A, 0x45, 0xDF, 0xA3] {
            return try await matroska(reader, head: first)
        }
        return try await mp4Timelines(reader, head: first)
    }

    private static func matroska(_ reader: RangeReader, head: [UInt8]) async throws -> [Timeline] {
        let segment = try await Segment.open(reader, head: head)
        let tracks = segment.tracks.filter { $0.type == TrackType.subtitle }
        guard !tracks.isEmpty else { return [] }
        let cues = try await segment.cues(reader)
        return tracks.map { track in
            var points: [(start: UInt64, duration: UInt64?)] = cues
                .filter { $0.track == track.number }
                .map { (start: segment.ms($0.time), duration: $0.duration.map { segment.ms($0) }) }
            points.sort { $0.start < $1.start }
            var seen = Set<UInt64>()
            points = points.filter { seen.insert($0.start).inserted }
            let lines = track.codec == "S_HDMV/PGS" ? pgsLines(points) : timedLines(points)
            return Timeline(number: track.number, codec: track.codec,
                            isPicture: ["S_HDMV/PGS", "S_VOBSUB", "S_DVBSUB"].contains(track.codec),
                            lines: lines.map { (start: Double($0.0), end: Double($0.1)) })
        }
    }

    // MARK: Lines

    /// How long a line whose index entry has no duration shows, at most, before the next.
    private static let untimedMs: UInt64 = 4_000
    /// A PGS entry this short clears the line before it.
    private static let pgsClearMs: UInt64 = 100
    /// Lines outside these are gaps or silences a PGS labelling took for lines.
    private static let pgsShortestMs: UInt64 = 250
    private static let pgsLongestMs: UInt64 = 12_000
    /// What a labelling pays for an odd line, a line replaced without a clear, and a doubled clear.
    private static let pgsOddLine: UInt32 = 4
    private static let pgsReplaced: UInt32 = 1
    private static let pgsClearedTwice: UInt32 = 3

    static func timedLines(_ points: [(start: UInt64, duration: UInt64?)]) -> [(UInt64, UInt64)] {
        points.enumerated().compactMap { i, point in
            let end: UInt64
            if let duration = point.duration {
                end = point.start + duration
            } else {
                let next = i + 1 < points.count ? points[i + 1].start : UInt64.max
                end = min(point.start + untimedMs, next)
            }
            return end > point.start ? (point.start, end) : nil
        }
    }

    /**
     * PGS indexes the display set that shows each line and the one that clears it. Some muxers give
     * the clearing ones a frame's duration; otherwise each entry is labelled one or the other, the
     * labelling with the fewest odd lines and replaced or doubled clears winning.
     */
    static func pgsLines(_ points: [(start: UInt64, duration: UInt64?)]) -> [(UInt64, UInt64)] {
        let clears = points.filter { $0.duration.map { $0 <= pgsClearMs } ?? false }.count
        if clears * 10 >= points.count * 3 {
            return points.compactMap { point in
                guard let duration = point.duration, duration > pgsClearMs else { return nil }
                return (point.start, point.start + duration)
            }
        }
        let t = points.map(\.start)
        let n = t.count
        guard n >= 2 else { return [] }
        func line(_ i: Int) -> UInt32 {
            guard i + 1 < n else { return 0 }
            return (pgsShortestMs...pgsLongestMs).contains(t[i + 1] - t[i]) ? 0 : pgsOddLine
        }
        // The cheapest labelling of entries up to i with entry i showing a line or clearing one, and
        // whether the entry before it showed one.
        var show = [UInt32](repeating: 0, count: n)
        var clear = [UInt32](repeating: 0, count: n)
        var showAfterShow = [Bool](repeating: false, count: n)
        var clearAfterShow = [Bool](repeating: false, count: n)
        show[0] = line(0)
        clear[0] = pgsClearedTwice
        for i in 1..<n {
            let replaced = show[i - 1] + pgsReplaced
            if replaced < clear[i - 1] {
                (show[i], showAfterShow[i]) = (replaced, true)
            } else {
                (show[i], showAfterShow[i]) = (clear[i - 1], false)
            }
            show[i] += line(i)
            let clearedTwice = clear[i - 1] + pgsClearedTwice
            if show[i - 1] <= clearedTwice {
                (clear[i], clearAfterShow[i]) = (show[i - 1], true)
            } else {
                (clear[i], clearAfterShow[i]) = (clearedTwice, false)
            }
        }
        var shows = [Bool](repeating: false, count: n)
        var isShow = show[n - 1] < clear[n - 1]
        for i in stride(from: n - 1, through: 0, by: -1) {
            shows[i] = isShow
            isShow = isShow ? showAfterShow[i] : clearAfterShow[i]
        }
        return (0..<(n - 1)).filter { shows[$0] }.map { (t[$0], t[$0 + 1]) }
    }

    // MARK: MP4

    /// The `moov` box's body, before or after the media data. Boxes the first read covers cost no request.
    private static func mp4Moov(_ r: RangeReader, head: [UInt8]) async throws -> MP4Bytes {
        var pos: UInt64 = 0
        while true {
            let first: [UInt8]
            if pos + 16 <= UInt64(head.count) {
                first = Array(head[Int(pos)..<Int(pos) + 16])
            } else {
                first = try await r.read(pos, 16)
            }
            guard first.count >= 8 else { throw Failure("MP4 without moov") }
            let box = MP4Bytes(first)
            guard let size32 = box.u32(0) else { throw Failure("MP4 without moov") }
            let kind = String(decoding: first[4..<8].map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
            var size = size32
            if size32 == 1 {
                guard let big = box.u64(8) else { throw Failure("box header") }
                size = big
            } else if size32 == 0 {
                throw Failure("MP4 without moov")
            }
            if pos == 0, kind != "ftyp" { throw Failure("not Matroska or MP4") }
            if kind == "moov" {
                guard size <= UInt64(Int32.max) else { throw Failure("moov of \(size) bytes") }
                let wholeBox: [UInt8]
                if pos + size <= UInt64(head.count) {
                    wholeBox = Array(head[Int(pos)..<Int(pos + size)])
                } else {
                    wholeBox = try await r.read(pos, Int(size))
                }
                guard UInt64(wholeBox.count) == size else { throw Failure("moov cut short") }
                return MP4Bytes(Array(wholeBox.dropFirst(size32 == 1 ? 16 : 8)))
            }
            if kind == "moof" { throw Failure("fragmented MP4") }
            pos += max(size, 8)
        }
    }

    /// Every subtitle track of an MP4 or MOV file, in file order, with the lines its sample tables list.
    private static func mp4Timelines(_ r: RangeReader, head: [UInt8]) async throws -> [Timeline] {
        let moov = try await mp4Moov(r, head: head)
        if moov.child("mvex") != nil { throw Failure("fragmented MP4") }
        let movieScale: UInt64 = {
            guard let mvhd = moov.child("mvhd"), let scale = mvhd.u32(mvhd[0] == 1 ? 20 : 12), scale > 0 else { return 1000 }
            return scale
        }()
        let traks = moov.boxes().filter { $0.kind == "trak" }.map(\.body)
        // Players list chapter titles as chapters, not subtitles.
        var chapters = Set<UInt64>()
        for trak in traks {
            guard let tref = trak.child("tref") else { continue }
            for (kind, ids) in tref.boxes() where kind == "chap" {
                for i in 0..<(ids.count / 4) {
                    if let id = ids.u32(4 * i) { chapters.insert(id) }
                }
            }
        }
        var out: [Timeline] = []
        for trak in traks {
            guard let mdia = trak.child("mdia"), let hdlr = mdia.child("hdlr") else { continue }
            let handler = String(decoding: (8..<12).compactMap { hdlr[$0] }, as: UTF8.self)
            guard ["sbtl", "text", "subt", "subp"].contains(handler) else { continue }
            let number = trak.child("tkhd").flatMap { $0.u32($0[0] == 1 ? 20 : 12) } ?? 0
            if chapters.contains(number) { continue }
            let entry = mdia.path(["minf", "stbl", "stsd"])?.from(8)?.boxes().first?.kind
            // An empty text sample is its two length bytes, an empty WebVTT one its 8-byte vtte box.
            let empty: UInt64? = ["tx3g", "text"].contains(entry ?? "") ? 2 : entry == "wvtt" ? 8 : nil
            let lines = empty.flatMap { sampleLines(trak: trak, mdia: mdia, movieScale: movieScale, empty: $0) } ?? []
            out.append(Timeline(number: number, codec: entry ?? "", isPicture: handler == "subp",
                                lines: lines.map { (start: Double($0.0), end: Double($0.1)) }))
        }
        return out
    }

    /// The samples that hold a line, from the sample tables, with an edit list's delay and start.
    private static func sampleLines(trak: MP4Bytes, mdia: MP4Bytes, movieScale: UInt64,
                                    empty: UInt64) -> [(UInt64, UInt64)]? {
        guard let mdhd = mdia.child("mdhd"), let scale = mdhd.u32(mdhd[0] == 1 ? 20 : 12), scale > 0,
              let stbl = mdia.path(["minf", "stbl"]),
              let stsz = stbl.child("stsz"), let fixed = stsz.u32(4), let count = stsz.u32(8),
              let stts = stbl.child("stts"), let runs = stts.u32(4) else { return nil }
        func size(_ sample: UInt64) -> UInt64? {
            fixed != 0 ? fixed : stsz.u32(12 + 4 * Int(sample))
        }
        // An edit list delays the track by its empty edits and starts it at its first edit's media time.
        var delayMs: UInt64 = 0
        var first: UInt64 = 0
        if let elst = trak.path(["edts", "elst"]) {
            let wide = elst[0] == 1
            let width = wide ? 20 : 12
            guard let edits = elst.u32(4) else { return nil }
            for i in 0..<Int(edits) {
                let at = 8 + width * i
                let length: UInt64
                let media: Int64
                if wide {
                    guard let l = elst.u64(at), let m = elst.u64(at + 8) else { return nil }
                    length = l
                    media = Int64(bitPattern: m)
                } else {
                    guard let l = elst.u32(at), let m = elst.u32(at + 4) else { return nil }
                    length = l
                    media = Int64(Int32(truncatingIfNeeded: m))
                }
                if media >= 0 {
                    first = UInt64(media)
                    break
                }
                delayMs += length * 1000 / movieScale
            }
        }
        func ms(_ time: UInt64) -> UInt64 { delayMs + (time > first ? time - first : 0) * 1000 / scale }
        var lines: [(UInt64, UInt64)] = []
        var sample: UInt64 = 0
        var dts: UInt64 = 0
        for i in 0..<Int(runs) {
            guard let run = stts.u32(8 + 8 * i), let delta = stts.u32(12 + 8 * i) else { return nil }
            var left = run
            while left > 0, sample < count {
                guard let bytes = size(sample) else { return nil }
                if bytes > empty, dts + delta > first { lines.append((ms(dts), ms(dts + delta))) }
                dts += delta
                sample += 1
                left -= 1
            }
        }
        return lines
    }

    // MARK: Matroska

    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let seekHead: UInt32 = 0x114D_9B74
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966
        static let timestampScale: UInt32 = 0x2A_D7B1
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let cluster: UInt32 = 0x1F43_B675
        static let cues: UInt32 = 0x1C53_BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueClusterPosition: UInt32 = 0xF1
        static let cueDuration: UInt32 = 0xB2
    }

    private enum TrackType {
        static let subtitle: UInt64 = 17
    }

    /// The first read of a file, which usually covers everything before the first cluster.
    private static let head = 256 * 1024

    private struct Track {
        let number: UInt64
        let type: UInt64
        let codec: String
    }

    private struct CuePoint {
        let time: UInt64
        let track: UInt64
        let duration: UInt64?
    }

    private struct Segment {
        /// File offset that SeekHead and Cues positions count from.
        let dataStart: UInt64
        var scaleNs: UInt64 = 1_000_000
        var tracks: [Track] = []
        var seeks: [(id: UInt32, position: UInt64)] = []

        func position(_ element: UInt32) -> UInt64? {
            seeks.first { $0.id == element }?.position
        }

        func ms(_ ticks: UInt64) -> UInt64 {
            UInt64((Double(ticks) * Double(scaleNs) / 1_000_000).rounded(.down))
        }

        static func open(_ r: RangeReader, head: [UInt8]) async throws -> Segment {
            guard let ebml = header(head, 0), ebml.id == ID.ebml, let ebmlSize = ebml.size else {
                throw Failure("not Matroska")
            }
            var i = ebml.length + Int(ebmlSize)
            guard let segmentHeader = header(head, i), segmentHeader.id == ID.segment else {
                throw Failure("no Matroska segment")
            }
            i += segmentHeader.length
            var segment = Segment(dataStart: UInt64(i))
            var info: [UInt8]?
            var tracks: [UInt8]?
            while let element = header(head, i) {
                guard element.id != ID.cluster, let size = element.size else { break }
                let end = i + element.length + Int(size)
                let body: [UInt8]
                if end <= head.count {
                    body = Array(head[(i + element.length)..<end])
                } else if [ID.info, ID.tracks, ID.seekHead].contains(element.id) {
                    body = try await readElement(r, UInt64(i)).body
                } else {
                    break
                }
                switch element.id {
                case ID.seekHead: segment.seeks += seekEntries(body, dataStart: segment.dataStart)
                case ID.info: info = body
                case ID.tracks: tracks = body
                default: break
                }
                i = end
            }
            // A SeekHead may point at a second one, often at the end of the file.
            for position in segment.seeks.filter({ $0.id == ID.seekHead }).map(\.position) {
                if let more = try? await readElement(r, position), more.id == ID.seekHead {
                    segment.seeks += seekEntries(more.body, dataStart: segment.dataStart)
                }
            }
            if info == nil, let position = segment.position(ID.info) {
                info = try await readElement(r, position).body
            }
            if tracks == nil, let position = segment.position(ID.tracks) {
                tracks = try await readElement(r, position).body
            }
            guard let info else { throw Failure("no segment info") }
            guard let tracks else { throw Failure("no track list") }
            segment.scaleNs = find(info, ID.timestampScale).map(uint) ?? 1_000_000
            segment.tracks = children(tracks).filter { $0.id == ID.trackEntry }.compactMap { entry in
                guard let number = find(entry.body, ID.trackNumber).map(uint),
                      let type = find(entry.body, ID.trackType).map(uint),
                      let codec = find(entry.body, ID.codecID).map(string) else { return nil }
                return Track(number: number, type: type, codec: codec)
            }
            return segment
        }

        /// Every cue of every track, in file order.
        func cues(_ r: RangeReader) async throws -> [CuePoint] {
            guard let at = position(ID.cues) else { throw Failure("no Cues in the SeekHead") }
            let cues = try await readElement(r, at)
            guard cues.id == ID.cues else { throw Failure("the SeekHead's Cues position holds something else") }
            var out: [CuePoint] = []
            for point in children(cues.body) where point.id == ID.cuePoint {
                let time = find(point.body, ID.cueTime).map(uint) ?? 0
                for spot in children(point.body) where spot.id == ID.cueTrackPositions {
                    guard let track = find(spot.body, ID.cueTrack).map(uint),
                          find(spot.body, ID.cueClusterPosition) != nil else { continue }
                    out.append(CuePoint(time: time, track: track,
                                        duration: find(spot.body, ID.cueDuration).map(uint)))
                }
            }
            return out
        }
    }

    private static func seekEntries(_ body: [UInt8], dataStart: UInt64) -> [(id: UInt32, position: UInt64)] {
        children(body).filter { $0.id == ID.seek }.compactMap { seek in
            guard let id = find(seek.body, ID.seekID).map(uint),
                  let position = find(seek.body, ID.seekPosition).map(uint) else { return nil }
            return (UInt32(truncatingIfNeeded: id), dataStart + position)
        }
    }

    private static func readElement(_ r: RangeReader, _ position: UInt64) async throws -> (id: UInt32, body: [UInt8]) {
        let head = try await r.read(position, 64 * 1024)
        guard let element = header(head, 0) else { throw Failure("no element header at \(position)") }
        guard let size = element.size else { throw Failure("an element of unknown size at \(position)") }
        let total = element.length + Int(size)
        if total <= head.count { return (element.id, Array(head[element.length..<total])) }
        var body = Array(head[element.length...])
        let rest = try await r.read(position + UInt64(head.count), total - head.count)
        guard rest.count == total - head.count else { throw Failure("the file ended inside an element at \(position)") }
        body += rest
        return (element.id, body)
    }

    // MARK: EBML

    /// An EBML variable-length integer at `i`, with its length marker for an element ID.
    private static func vint(_ b: [UInt8], _ i: Int, keepMarker: Bool) -> (value: UInt64, length: Int)? {
        guard i >= 0, i < b.count, b[i] != 0 else { return nil }
        let length = b[i].leadingZeroBitCount + 1
        guard i + length <= b.count else { return nil }
        var value = UInt64(keepMarker ? b[i] : b[i] & (0xFF >> length))
        for k in 1..<length {
            value = value << 8 | UInt64(b[i + k])
        }
        return (value, length)
    }

    /// An element's ID, header length and size, nil for an unknown size.
    private static func header(_ b: [UInt8], _ i: Int) -> (id: UInt32, length: Int, size: UInt64?)? {
        guard let id = vint(b, i, keepMarker: true), id.length <= 4,
              let size = vint(b, i + id.length, keepMarker: false) else { return nil }
        let unknown = size.value == (UInt64(1) << (7 * UInt64(size.length))) - 1
        // Past any real file, so a size that large is a misread.
        if !unknown, size.value > UInt64(1) << 40 { return nil }
        return (UInt32(id.value), id.length + size.length, unknown ? nil : size.value)
    }

    private static func children(_ body: [UInt8]) -> [(id: UInt32, body: [UInt8])] {
        var out: [(id: UInt32, body: [UInt8])] = []
        var i = 0
        while let element = header(body, i), let size = element.size {
            let start = i + element.length
            let end = start + Int(size)
            guard end <= body.count else { break }
            out.append((element.id, Array(body[start..<end])))
            i = end
        }
        return out
    }

    private static func find(_ body: [UInt8], _ id: UInt32) -> [UInt8]? {
        children(body).first { $0.id == id }?.body
    }

    private static func uint(_ b: [UInt8]) -> UInt64 {
        b.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func string(_ b: [UInt8]) -> String {
        String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Range requests on the file, a few and small: past these the page goes without the index.
private final class RangeReader {
    private let url: URL
    private let headers: [String: String]
    private var requests = 0
    private var bytes = 0
    private let deadline = Date().addingTimeInterval(7)

    private static let maxRequests = 16
    private static let maxBytes = 24 << 20
    private static let timeout: TimeInterval = 4

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    /// Up to `length` bytes from `offset`, fewer at the end of the file.
    func read(_ offset: UInt64, _ length: Int) async throws -> [UInt8] {
        guard length > 0 else { return [] }
        requests += 1
        guard requests <= Self.maxRequests else { throw SubtitleIndex.Failure("more than \(Self.maxRequests) requests") }
        guard bytes + length <= Self.maxBytes else { throw SubtitleIndex.Failure("more than \(Self.maxBytes >> 20) MB") }
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { throw SubtitleIndex.Failure("out of time") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: min(Self.timeout, left))
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        let data = try await RangeFetch(limit: length, deadline: left).run(request)
        bytes += data.count
        return [UInt8](data)
    }
}

/**
 * One range request that stops at `limit` bytes, and at once on an answer that isn't a range: a
 * server that ignores the Range header would otherwise send the whole file.
 */
private final class RangeFetch: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private let deadline: TimeInterval
    private var data = Data()
    private var done: CheckedContinuation<Data, Error>?
    private let lock = NSLock()

    init(limit: Int, deadline: TimeInterval) {
        self.limit = limit
        self.deadline = deadline
    }

    func run(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = deadline
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            done = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = done
        done = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 206 else {
            completionHandler(.cancel)
            // 416: the range starts past the end of the file.
            finish(status == 416 ? .success(Data()) : .failure(SubtitleIndex.Failure("HTTP \(status) to a range request")))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        data.append(chunk)
        if data.count >= limit {
            dataTask.cancel()
            finish(.success(data.prefix(limit)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error.map { .failure($0) } ?? .success(data))
    }
}

/**
 * A stretch of an MP4's bytes that its boxes are read from without copying them: a box's body is the
 * same array with a narrower range. Offsets are from the start of the stretch.
 */
private struct MP4Bytes {
    let bytes: [UInt8]
    let range: Range<Int>

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        range = 0..<bytes.count
    }

    private init(_ bytes: [UInt8], _ range: Range<Int>) {
        self.bytes = bytes
        self.range = range
    }

    var count: Int { range.count }

    subscript(index: Int) -> UInt8? {
        index >= 0 && index < count ? bytes[range.lowerBound + index] : nil
    }

    func u16(_ i: Int) -> UInt64? { number(i, 2) }
    func u32(_ i: Int) -> UInt64? { number(i, 4) }
    func u64(_ i: Int) -> UInt64? { number(i, 8) }

    private func number(_ i: Int, _ width: Int) -> UInt64? {
        guard i >= 0, i + width <= count else { return nil }
        let start = range.lowerBound + i
        return (0..<width).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[start + $1]) }
    }

    /// The bytes from `i` on.
    func from(_ i: Int) -> MP4Bytes? {
        guard i >= 0, i <= count else { return nil }
        return MP4Bytes(bytes, (range.lowerBound + i)..<range.upperBound)
    }

    /// Each box in the stretch, by its four-letter kind, in order.
    func boxes() -> [(kind: String, body: MP4Bytes)] {
        var out: [(kind: String, body: MP4Bytes)] = []
        var i = 0
        while i + 8 <= count, let size32 = u32(i) {
            let start = range.lowerBound + i
            let kind = String(decoding: bytes[(start + 4)..<(start + 8)].map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
            var head = 8
            var size = size32
            if size32 == 1 {
                guard let big = u64(i + 8) else { break }
                head = 16
                size = big
            } else if size32 == 0 {
                size = UInt64(count - i)
            }
            guard size >= UInt64(head), size <= UInt64(count - i) else { break }
            let end = i + Int(size)
            out.append((kind, MP4Bytes(bytes, (start + head)..<(range.lowerBound + end))))
            i = end
        }
        return out
    }

    func child(_ kind: String) -> MP4Bytes? {
        boxes().first { $0.kind == kind }?.body
    }

    func path(_ kinds: [String]) -> MP4Bytes? {
        kinds.reduce(self as MP4Bytes?) { $0?.child($1) }
    }
}
