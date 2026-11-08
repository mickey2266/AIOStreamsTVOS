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
 * Every URL is asked once, as a channel's link often carries no `.m3u8` (an
 * add-on's or a proxy's address that redirects to the playlist). The answer is
 * read only as far as it takes to tell: a video's is dropped at its headers (a
 * video or audio type, or longer than `maxBytes`), or after its first
 * `sniffBytes` at most, so a file from a debrid service or a server costs one
 * short request. A media playlist is live without `#EXT-X-ENDLIST`; a master
 * playlist is judged by its first variant.
 */
enum LiveHLS {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        return URLSession(configuration: config)
    }()

    /// The largest playlist read; a live window is a few kilobytes.
    private static let maxBytes = 2 * 1024 * 1024
    /// How much of an answer is read before it's known not to be a playlist.
    private static let sniffBytes = 1024

    /// True for a live HLS playlist; false for anything else, and when the answer can't be read.
    static func isLive(_ url: URL, headers: [String: String]) async -> Bool {
        do {
            guard let (text, at) = try await playlist(url, headers: headers) else { return false }
            if text.contains("#EXT-X-STREAM-INF") {
                guard let variant = firstVariant(text, base: at),
                      let (media, _) = try await playlist(variant, headers: headers) else { return false }
                return isLiveMedia(media)
            }
            return isLiveMedia(text)
        } catch {
            NSLog("[player] live check of %@: %@", url.absoluteString, error.localizedDescription)
            return false
        }
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

    /// Whether the response's headers already say it's media rather than a playlist.
    static func isMedia(_ response: URLResponse) -> Bool {
        let type = (response.mimeType ?? "").lowercased()
        if type.contains("mpegurl") { return false }
        if type.hasPrefix("video/") || type.hasPrefix("audio/") { return true }
        return response.expectedContentLength > Int64(maxBytes)
    }

    /// Whether the first bytes are a playlist's, past a byte order mark and blank space.
    static func beginsAsPlaylist(_ head: Data) -> Bool {
        var bytes = head[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        bytes = bytes.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        return bytes.starts(with: Array("#EXTM3U".utf8))
    }

    /// The playlist's text and the address it came from (after redirects), or nil if the answer isn't one.
    private static func playlist(_ url: URL, headers: [String: String]) async throws -> (String, URL)? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        // The rest of a video's answer is never wanted; cancelling the task closes the request.
        defer { bytes.task.cancel() }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProtocolError("HTTP \(http.statusCode)")
        }
        guard !isMedia(response) else { return nil }
        var data = Data()
        var checked = false
        for try await byte in bytes {
            data.append(byte)
            if !checked, data.count >= sniffBytes {
                guard beginsAsPlaylist(data) else { return nil }
                checked = true
            }
            if data.count > maxBytes { return nil }
        }
        guard beginsAsPlaylist(data), let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, response.url ?? url)
    }
}
