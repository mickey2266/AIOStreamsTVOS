import Foundation

/**
 * Whether a video is a live HLS stream. The engine plays live only when it's
 * told (`LoadOptions.isLive`: it doesn't guess from a missing duration), and the
 * page's `player-load` doesn't say. Told nothing, the engine takes a live
 * playlist for a finished one and hands it to AVPlayer as one: no live edge,
 * and no move to its own HLS reader when AVPlayer can't show the picture
 * (HEVC in MPEG-TS, common on IPTV).
 *
 * Only a URL ending in `.m3u8` or `.m3u` is read, so a file from a debrid
 * service or a server costs no request. A media playlist is live without
 * `#EXT-X-ENDLIST`; a master playlist is judged by its first variant.
 */
enum LiveHLS {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        return URLSession(configuration: config)
    }()

    /// The largest playlist read; a live window is a few kilobytes.
    private static let maxBytes = 2 * 1024 * 1024

    static func mayBePlaylist(_ url: URL) -> Bool {
        ["m3u8", "m3u"].contains(url.pathExtension.lowercased())
    }

    /// True for a live HLS playlist; false for anything else, and when the playlist can't be read.
    static func isLive(_ url: URL, headers: [String: String]) async -> Bool {
        guard mayBePlaylist(url) else { return false }
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

    /// The playlist's text and the address it came from (after redirects), or nil if it isn't one.
    private static func playlist(_ url: URL, headers: [String: String]) async throws -> (String, URL)? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProtocolError("HTTP \(http.statusCode)")
        }
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        guard trimmed.hasPrefix("#EXTM3U") else { return nil }
        return (text, response.url ?? url)
    }
}
