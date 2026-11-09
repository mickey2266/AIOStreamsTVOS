import UIKit

/**
 * Carries the page's `player-*` and `now-playing` messages to the player, and
 * the player's reports back, as AIOStreams' Android PlayerChannel does. All on
 * the main thread.
 */
@MainActor
final class PlayerChannel: PlayerListener {
    private let player: AetherPlayer
    private let send: (Message) -> Void
    private let showVideo: (Bool) -> Void
    private let subtitlesDir: URL
    let nowPlaying: NowPlaying
    /// Seek-bar thumbnails, from a decoder apart from the one playing.
    private let thumbnails: Thumbnails

    private var state: Message = [:]
    private var tracks: [Message] = []
    private var chapters: [Message] = []
    private var heldPosition: Message?
    private var positionSentAt: CFTimeInterval = 0
    private var loaded = false
    private var nextSubtitle = 0

    init(player: AetherPlayer, subtitlesDir: URL, send: @escaping (Message) -> Void, showVideo: @escaping (Bool) -> Void) {
        self.player = player
        self.subtitlesDir = subtitlesDir
        self.send = send
        self.showVideo = showVideo
        nowPlaying = NowPlaying(engine: player.engine, send: send)
        thumbnails = Thumbnails(engine: player.engine, send: send)
        player.listener = self
    }

    /// A file is loaded, playing or paused.
    var playing: Bool { loaded }

    /// A file is loaded and playing, not paused.
    var playingNow: Bool { loaded && state.flag("paused") == false && state.flag("idle") != true }

    /// Waiting for the page's seek from a system seek, to play once it arrives (`playAfterNextSeek`).
    private var resumeWaiting = 0
    private var resumeAsked = false
    /// The page's seek for a system seek comes back within this; the video plays after it anyway.
    private static let resumeWait: TimeInterval = 1.5

    /// Plays once the page's next seek arrives, or after `resumeWait` without one: a seek from Siri, which
    /// the page turns into its own seek and sends back, lands playing.
    func playAfterNextSeek() {
        resumeWaiting += 1
        resumeAsked = true
        let asked = resumeWaiting
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeWait) { [weak self] in
            guard let self, self.resumeAsked, asked == self.resumeWaiting else { return }
            self.resume()
        }
    }

    private func resume() {
        resumeAsked = false
        guard loaded else { return }
        player.change(Change(paused: false))
    }


    /// The page closed the player, so a picture-in-picture window has nothing left to show.
    var onStopped: () -> Void = {}

    /// A video started, loaded or came back from a seek, which can make picture in picture possible.
    var onPlayerEvent: () -> Void = {}

    func change(_ change: Change) {
        player.change(change)
    }

    /// False for a message that isn't the player's.
    func handle(_ type: String, _ message: Message) -> Bool {
        do {
            switch type {
            case "player-load":
                let request = try PlayerProtocol.load(message)
                loaded = true
                showVideo(true)
                player.load(request)
            case "player-stop":
                loaded = false
                onStopped()
                player.stop()
                thumbnails.close()
                updateIdleTimer()
            case "player-set":
                player.change(try PlayerProtocol.change(message))
            case "player-seek":
                if let at = message.number("positionMs") {
                    player.seek(at)
                    if resumeAsked { resume() }
                }
            case "player-subtitle-add":
                let url = message.text("url") ?? ""
                guard PlayerProtocol.isWebURL(url), let address = URL(string: url) else {
                    throw ProtocolError("only http(s) subtitles load")
                }
                player.addSubtitle(
                    address,
                    title: message.text("title"),
                    language: message.text("language"),
                    replace: message.number("replace").map { Int($0) },
                    pageURL: url
                )
            case "player-style":
                player.setStyle(try PlayerProtocol.style(message))
            case "player-settings":
                player.setSettings(PlayerProtocol.settings(message))
            case "player-sync":
                send(stateMessage(state))
                send(["type": "player-tracks", "tracks": tracks])
                send(["type": "player-chapters", "chapters": chapters])
            case "player-stats":
                // The page writes the readout from these, as it does for the Android app's ExoPlayer.
                send(player.stats())
            case "subtitle-file":
                try addSubtitleFile(message)
            case "now-playing":
                let item = message.object("item")
                nowPlaying.setItem(item)
                // Kept when the page clears it as the video closes, to name the last video's report.
                if let title = item?.text("title") {
                    let subtitle = item?.text("subtitle").map { " · \($0)" } ?? ""
                    player.title = title + subtitle
                }
                if item == nil { showVideo(false) }
            case "player-thumbnail":
                let url = message.text("url") ?? ""
                guard PlayerProtocol.isWebURL(url) else { throw ProtocolError("only http(s) files have thumbnails") }
                thumbnails.want(
                    url: url,
                    headers: try PlayerProtocol.headers(message["headers"]),
                    positionMs: message.number("positionMs"),
                    showingMs: message.number("showingMs")
                )
            // No subtitle index here: the page goes without it.
            case "player-subtitle-index":
                send(["type": "player-subtitle-index", "tracks": NSNull()])
            // The file's own track's line times, for the page's automatic subtitle sync; no track stops.
            case "player-subtitle-lines":
                let track = message.text("track")
                player.watchLines(track: track) { [weak self] lines in
                    guard let track else { return }
                    self?.send(["type": "player-subtitle-lines", "track": track, "lines": lines])
                }
            case "player-stats-overlay", "player-skips",
                 "player-controls", "player-retry", "player-unqueue":
                break
            default:
                return false
            }
        } catch let error as ProtocolError {
            reject(error.message)
        } catch {
            reject(error.localizedDescription)
        }
        return true
    }

    // MARK: PlayerListener

    func playerState(_ update: Message) {
        state.merge(update) { _, new in new }
        updateIdleTimer()
        var rest = update
        let position = rest.removeValue(forKey: "positionMs")
        let buffered = rest.removeValue(forKey: "buffered")
        if !rest.isEmpty { send(stateMessage(rest)) }
        guard position != nil || buffered != nil else { return }
        // Positions come several times a second, so they go out at most every 250 ms.
        var held = heldPosition ?? [:]
        if let position { held["positionMs"] = position }
        if let buffered { held["buffered"] = buffered }
        let wait = Self.throttle - (CACurrentMediaTime() - positionSentAt)
        if wait <= 0 { return sendPosition(held) }
        if heldPosition == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                if let held = self?.heldPosition { self?.sendPosition(held) }
            }
        }
        heldPosition = held
    }

    func playerTracks(_ tracks: [Message]) {
        self.tracks = tracks
        send(["type": "player-tracks", "tracks": tracks])
    }

    func playerChapters(_ chapters: [Message]) {
        self.chapters = chapters
        send(["type": "player-chapters", "chapters": chapters])
    }

    func playerEvent(_ name: String) {
        send(["type": "player-event", "name": name])
        onPlayerEvent()
    }

    func playerEnded(reason: String, error: String?, cause: String?, status: Int?) {
        var message: Message = ["type": "player-ended", "reason": reason, "error": nullable(error)]
        if let cause { message["cause"] = cause }
        if let status { message["status"] = status }
        send(message)
    }

    // MARK: Private

    private static let throttle: CFTimeInterval = 0.25
    private static let subtitleTypes: Set<String> = ["srt", "vtt", "ass", "ssa", "sup"]
    private static let maxSubtitleBytes = 10 << 20

    private func sendPosition(_ position: Message) {
        heldPosition = nil
        positionSentAt = CACurrentMediaTime()
        send(stateMessage(position))
    }

    private func stateMessage(_ fields: Message) -> Message {
        var message = fields
        message["type"] = "player-state"
        return message
    }

    /// Keeps the screen saver off while a video plays.
    private func updateIdleTimer() {
        let playing = playingNow
        if UIApplication.shared.isIdleTimerDisabled != playing {
            UIApplication.shared.isIdleTimerDisabled = playing
        }
    }

    /// The page names no path for the player to open, so the file is written here first.
    private func addSubtitleFile(_ message: Message) throws {
        guard let name = message.text("name") else { throw ProtocolError("subtitle file without a name") }
        let ext = (name as NSString).pathExtension.lowercased()
        guard Self.subtitleTypes.contains(ext) else { throw ProtocolError("\(name) is not a subtitle file the player reads") }
        guard let data = Data(base64Encoded: message.text("data") ?? "", options: .ignoreUnknownCharacters) else {
            throw ProtocolError("\(name) could not be read")
        }
        guard data.count <= Self.maxSubtitleBytes else { throw ProtocolError("\(name) is too big") }
        try FileManager.default.createDirectory(at: subtitlesDir, withIntermediateDirectories: true)
        nextSubtitle += 1
        let file = subtitlesDir.appendingPathComponent("\(nextSubtitle).\(ext)")
        try data.write(to: file)
        player.addSubtitle(file, title: String(name.prefix(200)), language: nil, replace: nil, pageURL: nil)
    }

    private func reject(_ message: String) {
        NSLog("[player] refused: %@", message)
        send(["type": "error", "message": message])
    }
}
