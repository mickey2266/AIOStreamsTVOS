import Foundation

/**
 * When the file's own subtitle lines show, read from its index rather than played: the page's
 * `player-subtitle-index`, and every line of the track an added subtitle is lined up against at once.
 * AIOStreams' desktop and Android apps do the same with `subtitle_timelines` from AIOStreams/media
 * (`container/src/subtitles.rs`, rev 87dee2cc), which this follows for Matroska: muxers list every
 * subtitle frame in the Cues, most with its duration, so a few range requests give the whole file's
 * lines. A PGS track lists the display set that shows each line and the one that clears it.
 *
 * With every line from the start, the page's match sees the whole file, so it settles in a moment and
 * finds a subtitle timed for another frame rate, whose drift a few minutes of lines hide. The player's
 * own decode gives a picture subtitle's lines only as it plays, with ends it can still change.
 */
enum SubtitleIndex {
    /// One of the file's subtitle tracks, in file order, and when its lines show, in milliseconds.
    struct Timeline {
        let number: UInt64
        let codec: String
        let lines: [(start: Double, end: Double)]

        /// Matroska's picture subtitles.
        var isPicture: Bool { ["S_HDMV/PGS", "S_VOBSUB", "S_DVBSUB"].contains(codec) }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Every subtitle track of a Matroska file in file order; a track the index leaves out has no lines.
    static func read(url: URL, headers: [String: String]) async throws -> [Timeline] {
        let reader = RangeReader(url: url, headers: headers)
        let segment = try await Segment.open(reader)
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

        static func open(_ r: RangeReader) async throws -> Segment {
            let head = try await r.read(0, SubtitleIndex.head)
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
