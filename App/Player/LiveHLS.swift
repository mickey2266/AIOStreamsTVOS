import Foundation

/**
 * Whether a video is a live HLS stream. The engine plays live only when it's
 * told (`LoadOptions.isLive`: it doesn't guess from a missing duration), and the
 * page's `player-load` doesn't say. Told nothing, the engine takes a live
 * playlist for a finished one and hands it to AVPlayer as one: no live edge,
 * and no move to its own HLS reader when AVPlayer can't show the picture
 * (HEVC in MPEG-TS, common on IPTV). AVPlayer then gives up on it, and the
 * page shows "the live stream stopped".
 *
 * Only a URL ending in `.m3u8` or `.m3u` is asked (`mayBePlaylist`), so a film
 * or an episode from a debrid service or a server costs no request. The answer
 * is read by its bytes, not its content type, which IPTV servers set to
 * `video/mp2t` or `application/octet-stream` for playlists: one longer than
 * `maxBytes` is dropped at its headers, and anything else after its first
 * `sniffBytes` unless they start a playlist. A media playlist is live without
 * `#EXT-X-ENDLIST`; a master playlist is judged by its first variant.
 */
enum LiveHLS {
    struct Verdict {
        let live: Bool
        /// Why, for the app menu's log.
        let reason: String
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        return URLSession(configuration: config)
    }()

    /// The largest playlist read; a live window is a few kilobytes.
    private static let maxBytes = 2 * 1024 * 1024
    /// How much of an answer is read before it's known not to be a playlist.
    private static let sniffBytes = 1024
    /// AVPlayer's, which the stream's server already takes, where the page names no user agent.
    private static let userAgent = "AppleCoreMedia/1.0.0 (Apple TV; tvOS)"

    private enum Answer {
        case playlist(String, URL)
        case notPlaylist(String)
    }

    /// An address that names an HLS playlist, the only kind the check asks.
    static func mayBePlaylist(_ url: URL) -> Bool {
        ["m3u8", "m3u"].contains(url.pathExtension.lowercased())
    }

    static func check(_ url: URL, headers: [String: String]) async -> Verdict {
        do {
            guard case .playlist(let text, let at) = try await fetch(url, headers: headers) else {
                return Verdict(live: false, reason: "not a playlist")
            }
            if text.contains("#EXT-X-STREAM-INF") {
                guard let variant = firstVariant(text, base: at) else {
                    return Verdict(live: false, reason: "master playlist without a variant")
                }
                guard case .playlist(let media, _) = try await fetch(variant, headers: headers) else {
                    return Verdict(live: false, reason: "master playlist whose first variant isn't a playlist")
                }
                return verdict(media, master: true)
            }
            return verdict(text, master: false)
        } catch {
            return Verdict(live: false, reason: "unread: \(error.localizedDescription)")
        }
    }

    private static func verdict(_ media: String, master: Bool) -> Verdict {
        let kind = master ? "master playlist, first variant" : "media playlist"
        return isLiveMedia(media)
            ? Verdict(live: true, reason: "\(kind) live (no #EXT-X-ENDLIST)")
            : Verdict(live: false, reason: "\(kind) finished")
    }

    /// A media playlist still being written: no end, and not declared VOD.
    static func isLiveMedia(_ text: String) -> Bool {
        text.contains("#EXTINF") && !text.contains("#EXT-X-ENDLIST") && !text.contains("#EXT-X-PLAYLIST-TYPE:VOD")
    }

    /// The URI after the first `#EXT-X-STREAM-INF`, resolved against the playlist's own address.
    static func firstVariant(_ text: String, base: URL) -> URL? {
        var afterStreamInf = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                afterStreamInf = true
            } else if afterStreamInf, !line.isEmpty, !line.hasPrefix("#") {
                return URL(string: line, relativeTo: base)?.absoluteURL
            }
        }
        return nil
    }

    /// Whether the first bytes are a playlist's, past a byte order mark and blank space.
    static func beginsAsPlaylist(_ head: Data) -> Bool {
        var bytes = head[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        bytes = bytes.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        return bytes.starts(with: Array("#EXTM3U".utf8))
    }

    /// The playlist's text and the address it came from (after redirects), or why the answer isn't one.
    private static func fetch(_ url: URL, headers: [String: String]) async throws -> Answer {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let (bytes, response) = try await session.bytes(for: request)
        // The rest of a video's answer is never wanted; cancelling the task closes the request.
        defer { bytes.task.cancel() }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProtocolError("HTTP \(http.statusCode)")
        }
        let type = response.mimeType ?? "no type"
        if response.expectedContentLength > Int64(maxBytes) {
            return .notPlaylist("\(type), \(response.expectedContentLength / 1_000_000) MB")
        }
        var data = Data()
        var checked = false
        for try await byte in bytes {
            data.append(byte)
            if !checked, data.count >= sniffBytes {
                guard beginsAsPlaylist(data) else { return .notPlaylist(type) }
                checked = true
            }
            if data.count > maxBytes { return .notPlaylist("\(type), over \(maxBytes / 1_000_000) MB") }
        }
        guard beginsAsPlaylist(data), let text = String(data: data, encoding: .utf8) else {
            return .notPlaylist(type)
        }
        return .playlist(text, response.url ?? url)
    }
}
