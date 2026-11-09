import AetherHost
import Foundation

/**
 * Whether a freeze came from the stream running out or from the picture
 * falling behind with the data in hand, for the app menu's report.
 *
 * - The stream ran out: the buffer AVPlayer holds ahead falls toward nothing,
 *   playback stalls, and the source delivers less than the video plays.
 * - The picture fell behind: the buffer stays full while dropped frames climb.
 *
 * Fed the engine's 1 Hz telemetry; covers one file, from its load.
 */
struct PlaybackHealth {
    /// How far back the recent figures look.
    static let window: TimeInterval = 30

    private struct Sample {
        let at: TimeInterval
        let sourceBytes: Int64
        let dropped: Int?
        /// Only while playing: a pause or a load says nothing about keeping up.
        let buffer: Double?
        let restarts: Int
    }

    /// A stall as the figures stood when it began, so the app menu still has them after the 30 s window moved on.
    struct Stall {
        let at: Date
        /// Where in the video, in seconds.
        let position: Double?
        let verdict: String
        let figures: String
    }

    /// How many stalls the record keeps, newest last.
    static let keptStalls = 5

    private var samples: [Sample] = []
    private(set) var latest: LiveTelemetry?
    /// Times playback stopped to wait for data, after the first picture and outside seeks and reloads.
    private(set) var stalls = 0
    private(set) var lastStallAt: Date?
    private(set) var stallRecord: [Stall] = []

    /// Seconds the file has played for, from the 1 Hz ticks, for an estimate of the frames shown.
    private(set) var playedSeconds: Double = 0
    private var lastTick: TimeInterval?

    mutating func record(_ telemetry: LiveTelemetry, playing: Bool, at now: TimeInterval) {
        // A gap longer than a couple of ticks is the app away or the sampler stopped, not playing.
        if playing, let lastTick { playedSeconds += min(max(0, now - lastTick), 2) }
        lastTick = now
        latest = telemetry
        // A reload starts the session's counters again; figures across it would be nonsense.
        if let last = samples.last, telemetry.demuxerBytesFetched < last.sourceBytes {
            samples.removeAll()
        }
        samples.append(Sample(
            at: now,
            sourceBytes: telemetry.demuxerBytesFetched,
            dropped: telemetry.droppedFrameCount,
            buffer: playing ? telemetry.forwardBufferSeconds : nil,
            restarts: telemetry.producerRestartCount
        ))
        samples.removeAll { now - $0.at > Self.window }
    }

    /// `position` is where in the video it stalled, in seconds; `softwareRoute` is the engine's software
    /// player, which keeps a fixed 96 MB ahead in memory whatever the Cache size.
    mutating func stalled(position: Double?, softwareRoute: Bool) {
        stalls += 1
        let now = Date()
        lastStallAt = now
        let (verdict, figures) = judge(softwareRoute: softwareRoute)
        stallRecord.append(Stall(at: now, position: position, verdict: verdict, figures: figures))
        if stallRecord.count > Self.keptStalls { stallRecord.removeFirst(stallRecord.count - Self.keptStalls) }
    }

    /// Reader restarts over the window.
    private var recentRestarts: Int {
        guard let first = samples.first?.restarts, let last = samples.last?.restarts else { return 0 }
        return max(0, last - first)
    }

    /**
     * What the figures say about a stall as it begins, from the last 30 s:
     * - the source delivered less than the video plays at, or the buffer was empty: it ran out of data;
     * - a buffer of 5 s or more with frames dropped: the picture fell behind, not the data;
     * - the engine's reader restarted in the window: that alone can stall it.
     * "Source delivered" counts the pauses the engine takes with the buffer full, so it reads low then;
     * a stall comes with the buffer low, when the engine is fetching all the time.
     */
    private func judge(softwareRoute: Bool) -> (verdict: String, figures: String) {
        let covered = Int(span.rounded())
        let buffer = latest?.forwardBufferSeconds
        let video = latest?.instantBitrateMbps
        let source = sourceMbps
        var causes: [String] = []
        if let source, let video, video > 0, source < video * 0.95 {
            causes.append("ran out of data: the source delivered \(Self.mbps(source)) for a \(Self.mbps(video)) video")
        } else if let lowest = lowestBuffer ?? buffer, lowest < 1 {
            causes.append("ran out of data: the buffer ran empty"
                + (source.map { " with the source at \(Self.mbps($0))" } ?? ""))
        } else if let buffer, buffer >= 5, let dropped = recentDropped, dropped > 0 {
            causes.append("the picture fell behind with \(Self.seconds(buffer)) buffered (\(dropped) frames dropped)")
        }
        if recentRestarts > 0 { causes.append("the engine's reader restarted \(recentRestarts)× in the last \(covered) s") }
        if softwareRoute, !causes.isEmpty || buffer.map({ $0 < 15 }) == true {
            causes.append("on the software player, which keeps only 96 MB ahead")
        }
        if causes.isEmpty { causes.append("cause unclear from the figures") }

        var figures: [String] = []
        if let buffer { figures.append("buffer \(Self.seconds(buffer))") }
        if let lowest = lowestBuffer { figures.append("lowest \(Self.seconds(lowest)) while playing") }
        if let source { figures.append("source \(Self.mbps(source))") }
        if let video { figures.append("video \(Self.mbps(video))") }
        if let dropped = recentDropped { figures.append("\(dropped) frames dropped") }
        let shown = figures.isEmpty ? "no figures yet" : figures.joined(separator: ", ") + " over the last \(covered) s"
        return (causes.joined(separator: "; "), shown)
    }

    /// Seconds the recent figures cover.
    var span: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.at - first.at
    }

    /// What the source delivered over the window, its pauses included: below the video's
    /// bitrate for long, and the buffer has to run out.
    var sourceMbps: Double? {
        guard let first = samples.first, let last = samples.last, span >= 5 else { return nil }
        return Double(last.sourceBytes - first.sourceBytes) * 8 / span / 1_000_000
    }

    /// Frames dropped over the window.
    var recentDropped: Int? {
        guard let first = samples.first?.dropped, let last = samples.last?.dropped, span >= 5 else { return nil }
        return max(0, last - first)
    }

    /// The least buffer held ahead while playing, over the window.
    var lowestBuffer: Double? { samples.compactMap(\.buffer).min() }

    var lines: [String] {
        guard let latest else { return ["Playback health: no figures yet"] }
        let covered = Int(span.rounded())
        var lines: [String] = []

        var buffer = "Buffer ahead: " + (latest.forwardBufferSeconds.map { Self.seconds($0) } ?? "unknown")
        if let lowest = lowestBuffer { buffer += ", lowest \(Self.seconds(lowest)) while playing in the last \(covered) s" }
        lines.append(buffer)

        var stallLine = "Stalls waiting for data: \(stalls)"
        if let at = lastStallAt { stallLine += ", last \(Int(Date().timeIntervalSince(at).rounded())) s ago" }
        lines.append(stallLine)

        var dropped = "Dropped frames: " + (latest.droppedFrameCount.map(String.init) ?? "unknown")
        if let recent = recentDropped { dropped += ", \(recent) in the last \(covered) s" }
        lines.append(dropped)

        var rates: [String] = []
        if let played = latest.instantBitrateMbps { rates.append("video plays at \(Self.mbps(played))") }
        if let source = sourceMbps { rates.append("source delivered \(Self.mbps(source)) over the last \(covered) s") }
        // On the AVPlayer route this is the in-app loopback to AVPlayer, not the Wi-Fi.
        if let link = latest.networkThroughputMbps { rates.append("loopback to AVPlayer \(Self.mbps(link))") }
        if !rates.isEmpty { lines.append("Rates: " + rates.joined(separator: ", ")) }

        if let ahead = latest.readerWindowAheadBytes {
            lines.append(String(format: "Read ahead of the demuxer: %.1f MB", Double(ahead) / 1_048_576))
        }
        lines.append("Producer restarts: \(latest.producerRestartCount)")
        lines += stallLines
        return lines
    }

    /// The last stalls of this video, as the figures stood when each began.
    var stallLines: [String] {
        guard !stallRecord.isEmpty else { return [] }
        var lines = ["Last \(stallRecord.count) stalls, newest last:"]
        for stall in stallRecord {
            let time = DateFormatter.localizedString(from: stall.at, dateStyle: .none, timeStyle: .medium)
            let place = stall.position.map { " at \(Self.clock($0)) in the video" } ?? ""
            lines.append("\(time)\(place): \(stall.verdict) (\(stall.figures))")
        }
        return lines
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
    private static func mbps(_ value: Double) -> String { String(format: "%.1f Mbps", value) }
}
