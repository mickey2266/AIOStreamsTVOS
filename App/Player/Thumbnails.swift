import AetherHost
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore

/**
 * Seek-bar thumbnails, answering the page's `player-thumbnail` asks as
 * AIOStreams' desktop and Android apps do: a keyframe's picture for the
 * position, the newest ask wins, the picture in `showingMs` isn't sent again,
 * and each picture is a JPEG the page loads from `/thumbnail/<file>-<ms>.jpg`.
 *
 * AetherEngine's FrameExtractor makes them: a decoder of its own on the file,
 * which seeks to the keyframe at or before a position, tone maps HDR and
 * Dolby Vision to SDR, and backs off while the playing video is short of data.
 * Asks are rounded to the second, so the scrub row's neighbours and repeats
 * come from what was made before. All on the main thread but the decoding.
 */
@MainActor
final class Thumbnails {
    private let send: (Message) -> Void
    private let engine: AetherEngine

    private var url: String?
    private var file = 0
    private var extractor: FrameExtractor?
    /// The newest ask not yet answered, in rounded milliseconds, and the picture showing then.
    private var wanted: (ms: Int64, showing: Int64?)?
    private var working = false
    /// Positions that gave no picture after every try, not tried again for this file.
    private var failed = Set<Int64>()
    /// Tries that gave no picture, by position.
    private var tries: [Int64: Int] = [:]
    /// Whether this file has given a picture yet, when it first gave none, and if it was found to have none.
    private var madeOne = false
    private var firstMiss: CFTimeInterval?
    private var hasNone = false
    private var retry: DispatchWorkItem?
    private var idle: DispatchWorkItem?

    init(engine: AetherEngine, send: @escaping (Message) -> Void) {
        self.engine = engine
        self.send = send
    }

    /// The picture for `positionMs`; without one, only opens the file, so the first ask waits less.
    func want(url: String, headers: [String: String], positionMs: Double?, showingMs: Double?) {
        if url != self.url {
            close()
            guard let address = URL(string: url) else { return }
            self.url = url
            file += 1
            // A live channel's pictures come from what the engine keeps of its rewind window
            // (`liveScrubThumbnail`): a second connection could take the provider's only one from the player.
            if !engine.isLive { extractor = engine.makeFrameExtractor(url: address, httpHeaders: headers) }
        }
        stayOpen()
        guard extractor != nil || engine.isLive else { return }
        guard let positionMs else {
            if let extractor { Task { await extractor.prewarm() } }
            return
        }
        let ms = Int64(max(0, positionMs) / 1000) * 1000
        let showing = showingMs.map { Int64($0.rounded()) }
        if ThumbnailStore.has(path(ms)) {
            wanted = nil
            if ms != showing { answer(ms) }
            return
        }
        if hasNone { return answer(nil) }
        // Not `src: null`: the page takes that for a file with no pictures at all, and stops asking.
        if failed.contains(ms) { return }
        wanted = (ms, showing)
        pump()
    }

    /// The page closed the player.
    func close() {
        idle?.cancel()
        idle = nil
        retry?.cancel()
        retry = nil
        if let extractor { Task { await extractor.shutdown() } }
        extractor = nil
        url = nil
        wanted = nil
        failed = []
        tries = [:]
        madeOne = false
        firstMiss = nil
        hasNone = false
    }

    private func pump() {
        guard !working, let ask = wanted, extractor != nil || engine.isLive else { return }
        wanted = nil
        working = true
        let file = file
        let extractor = extractor, engine = engine
        Task { [weak self] in
            let seconds = Double(ask.ms) / 1000
            let picture: CGImage?
            if let extractor {
                picture = await extractor.thumbnail(at: seconds, maxWidth: Self.width)
            } else {
                picture = await engine.liveScrubThumbnail(atSessionSeconds: seconds, maxWidth: Self.width)
            }
            let jpeg = picture.flatMap { Self.jpeg($0) }
            guard let self else { return }
            self.working = false
            guard file == self.file else { return self.pump() }
            if let jpeg {
                self.madeOne = true
                self.tries[ask.ms] = nil
                ThumbnailStore.keep(self.path(ask.ms), jpeg)
                // A newer ask went past this one; it's kept for when the row comes back to it.
                if self.wanted == nil, ask.ms != ask.showing { self.answer(ask.ms) }
            } else {
                self.missed(ask)
            }
            self.pump()
        }
    }

    /**
     * No picture, which is mostly for now: the extractor yields while playback is short of data
     * (after it starts, and after each seek, until the buffer has held for 3 s), and an open can
     * fail on the network. Answered `src: null`, the page took the file to have none and asked for
     * nothing more until the setting was turned off and on. So the newest ask is tried again, and
     * the page is told there are none only once the file has given nothing for a while.
     */
    private func missed(_ ask: (ms: Int64, showing: Int64?)) {
        // A live channel has none outside what it keeps yet, which isn't the channel having none.
        if engine.isLive { return }
        let now = CACurrentMediaTime()
        if firstMiss == nil { firstMiss = now }
        let count = (tries[ask.ms] ?? 0) + 1
        tries[ask.ms] = count
        NSLog("[thumbnails] none at %lld ms (try %d)", ask.ms, count)
        if !madeOne, count >= Self.triesBeforeNone, now - (firstMiss ?? now) >= Self.secondsBeforeNone {
            NSLog("[thumbnails] the file gave none for %.0f s; telling the page it has none", now - (firstMiss ?? now))
            hasNone = true
            wanted = nil
            return answer(nil)
        }
        if count >= Self.triesPerPosition, madeOne {
            failed.insert(ask.ms)
            return
        }
        // Only the newest ask is tried again; a newer one already waiting goes first.
        guard wanted == nil else { return }
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wanted == nil, self.extractor != nil, !self.hasNone else { return }
                self.wanted = ask
                self.pump()
            }
        }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retrySeconds, execute: item)
    }

    /// Sends the picture, or with nil, that there's none.
    private func answer(_ ms: Int64?) {
        guard let url else { return }
        var message: Message = ["type": "player-thumbnail", "url": url, "src": NSNull()]
        if let ms {
            message["positionMs"] = Double(ms)
            message["src"] = path(ms)
        }
        send(message)
    }

    private func path(_ ms: Int64) -> String {
        "\(ThumbnailStore.prefix)\(file)-\(ms).jpg"
    }

    /// A decoder holds a connection, so it closes when the page stops asking.
    private func stayOpen() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.working, let extractor = self.extractor else { return }
                self.extractor = nil
                Task { await extractor.shutdown() }
                // The next ask opens it again.
                self.url = nil
            }
        }
        idle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: item)
    }

    /// The picture's width; the page shows it about 224 points wide.
    private static let width = 384
    private static let idleTimeout: TimeInterval = 45
    private static let quality = 0.75
    /// A position given no picture is tried again this long after.
    private static let retrySeconds: TimeInterval = 1
    /// Once the file has given a picture, a position is given up after this many tries.
    private static let triesPerPosition = 5
    /// Until it has, the page is told the file has none after this many tries at one position,
    /// this long after the first gave none: longer than the extractor yields after a seek.
    private static let triesBeforeNone = 8
    private static let secondsBeforeNone: TimeInterval = 10

    private static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

/// The JPEGs the page was sent paths for, the newest 256, as the desktop and Android apps keep.
enum ThumbnailStore {
    static let prefix = "/thumbnail/"
    private static let kept = 256
    private static let lock = NSLock()
    private static var images: [String: Data] = [:]
    private static var order: [String] = []

    static func keep(_ path: String, _ jpeg: Data) {
        lock.lock()
        defer { lock.unlock() }
        if images.updateValue(jpeg, forKey: path) == nil { order.append(path) }
        while order.count > kept { images.removeValue(forKey: order.removeFirst()) }
    }

    /// For the web view's scheme handler.
    static func image(_ path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return images[path]
    }

    static func has(_ path: String) -> Bool {
        image(path) != nil
    }
}
