import AetherHost
import AVFoundation
import Combine
import UIKit

/// What the player reports, always on the main thread, in the page's `player-*` terms.
@MainActor
protocol PlayerListener: AnyObject {
    /// Only the fields that changed, in the page's `player-state` terms.
    func playerState(_ state: Message)
    func playerTracks(_ tracks: [Message])
    func playerChapters(_ chapters: [Message])
    /// `start`, `loaded` or `restart`, as mpv's events.
    func playerEvent(_ name: String)
    func playerEnded(reason: String, error: String?, cause: String?, status: Int?)
}

/**
 * AetherEngine playing the page's videos. FFmpeg reads the file, and
 * VideoToolbox and AVPlayer play it, so tvOS does what it does for its own
 * apps: Match Content's HDR10, HLG and Dolby Vision modes, and Dolby Atmos.
 *
 * Atmos, which is what this is set up around:
 * - E-AC-3 with Atmos (JOC), the streaming services' Atmos, is copied into
 *   the stream AVPlayer plays untouched, and tvOS sends it to the receiver as
 *   Dolby MAT. That needs the HDMI route at full width, so the audio session
 *   is activated per video (`AudioOutput`).
 * - TrueHD and DTS-HD can't be bitstreamed by an Apple TV, so they're decoded
 *   to multichannel PCM, up to 7.1, as Infuse does. TrueHD Atmos and DTS:X
 *   play as their 7.1, without objects or heights, unless the page's Object
 *   audio switch is on: then the engine renders them into a 7.1.4 or 9.1.6
 *   bed, the page's Speakers choice.
 * - Anything that shapes the sound (stereo, 5.1) decodes it, which drops the
 *   objects; so does a TV whose ARC takes only stereo.
 *
 * The rest follows what mpv reported, so `PlayerChannel` and the page are unchanged.
 */
@MainActor
final class AetherPlayer {
    let engine: AetherEngine
    private let view: AetherPlayerView
    private let subtitles: SubtitleOverlay
    weak var listener: PlayerListener?

    private var watching = Set<AnyCancellable>()
    private var loading: Task<Void, Never>?
    private var generation = 0
    /// The pause and play of `settleAudio` is under way, so the page isn't told about it.
    private var reopening = false
    /**
     * The video has loaded paused and waits for the HDMI link to widen under the Dolby primer before
     * it plays (`holdForLink`), so its sound is set up on the wide link: the page sees buffering, as
     * during the load, rather than a paused video.
     */
    private var holdingForLink = false

    /// The file loaded or loading, and the one to play after it.
    private(set) var current: LoadRequest?
    private var queued: LoadRequest?
    /// Its end has been reported, so the state the engine reports after it is the next file's.
    private var ended = true

    private var settings = PlayerSettings()
    private var paused = false
    private var volume = 1.0
    private var muted = false
    private var speed = 1.0
    /// Server and user subtitles added to the file, by track id, as the page named them.
    private var addedSubtitles: [Int: String] = [:]
    private var leftWithFile = false
    private var lastBuffered: Double?
    /// The file's buffer, stalls, dropped frames and rates, for the report.
    private var health = PlaybackHealth()
    /// The source connection the file opened with, which a change in the menu leaves as it is.
    private var openedHeld = false
    /// The file is loading, or playing, again as live after AVPlayer gave up on it (`failed`), so it isn't again.
    private var reloadedAsLive = false
    /**
     * The live channel is loading, or playing, again on AVPlayer (`LoadOptions.nativeRemoteHLS`) because the
     * engine's live-ingest reader identified none of its audio (`loaded`), so it isn't again. Seen on an IPTV
     * channel with two AC-3 tracks: "Could not find codec parameters ... unspecified sample rate" with the
     * full 60 s probe, then "error decoding the audio block", and a silent picture, where other players had
     * sound. AVPlayer reads the playlist itself and decodes AC-3; a picture it can't show (HEVC in MPEG-TS)
     * goes back to the ingest reader by the engine's own fallback (`nativeRemoteHLSIngestFallback`).
     */
    private var liveOnAVPlayer = false

    /// A URL for the log: its host and the end of its path, without the query, where tokens go.
    static func shortened(_ url: URL) -> String {
        let path = url.path.split(separator: "/").suffix(2).joined(separator: "/")
        return "\(url.host ?? "?")/…/\(path)"
    }

    /**
     * One connection to the source, read as playback needs it, instead of
     * ranged requests that end when the read-ahead fills and open again as it
     * drains (`LoadOptions.heldSourceConnection`). HTTP/1.1 only. On by
     * default: ranged requests start again at least every 128 MB, every
     * dozen seconds of a remux, each waiting for the source's first byte, and
     * more often once the buffer is full and the read-ahead drains. Set from
     * the app menu, where a choice made before stays; a file opens with the
     * setting it finds, so it applies from the next video.
     */
    static var heldSourceConnection: Bool {
        get { UserDefaults.standard.object(forKey: "player.heldSourceConnection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "player.heldSourceConnection") }
    }

    init(view: AetherPlayerView, subtitles: SubtitleOverlay) throws {
        EngineLogBook.install()
        engine = try AetherEngine()
        self.view = view
        self.subtitles = subtitles
        // The page's controls are the transport, so the app owns Now Playing (`NowPlaying`).
        engine.ownsVideoNowPlayingSession = true
        engine.ownsSoftwareNowPlaying = true
        // The app plays no other sound, so the session goes when playback does; otherwise a
        // receiver can keep repeating the last Atmos frame after the player is gone.
        engine.deactivatesAudioSessionOnStop = true
        engine.bind(view: view)
        subtitles.videoRect = { [weak self] in self?.videoRect() ?? .zero }
        watch()
        let lifecycle = NotificationCenter.default
        observers = [
            lifecycle.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredBackground() }
            },
            lifecycle.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameActive() }
            },
        ]
    }

    private var observers: [NSObjectProtocol] = []

    static var version: String { AetherEngine.version }

    // MARK: Requests

    func load(_ request: LoadRequest) {
        // mpv's `append`: after the file playing, which the page only asks of a player in its own window.
        if request.append, current != nil, !ended {
            queued = request
            return
        }
        start(request)
    }

    /// `asLive`: loaded again as live after AVPlayer gave up on it as a finished video (`failed`).
    /// `onAVPlayer`: a live channel loaded again on AVPlayer, its audio unidentified on the engine's reader (`loaded`).
    private func start(_ request: LoadRequest, asLive: Bool = false, onAVPlayer: Bool = false) {
        guard let url = URL(string: request.url) else { return }
        reloadedAsLive = asLive
        liveOnAVPlayer = onAVPlayer
        if current != nil, !ended {
            keepLastVideo(ending: onAVPlayer ? "loaded again on AVPlayer for its sound"
                : asLive ? "loaded again as live" : "another video took its place")
            // The same channel goes on: the page isn't told it stopped.
            if !onAVPlayer { listener?.playerEnded(reason: "stop", error: nil, cause: nil, status: nil) }
        }
        // The page names the new video once it starts (`now-playing`).
        if !asLive && !onAVPlayer { title = nil }
        generation += 1
        let generation = generation
        current = request
        queued = nil
        ended = false
        addedSubtitles = [:]
        lastBuffered = nil
        // The page asks again for the next file's reference track.
        endLineWatch()
        health = PlaybackHealth()
        subtitles.reset()
        listener?.playerEvent("start")
        // A new file starts with no subtitle, and the page is told so. The engine let go of the last file's
        // with `stop()` already gone, which reports nothing, and a file that picks none never changes it
        // again: the page kept the last channel's track as the one showing, its menu ticked it with nothing
        // on screen, and it never sent a pick it took as made. A pick for this file follows from the engine.
        listener?.playerState(["idle": false, "buffering": true, "positionMs": request.startMs, "subtitle": NSNull()])
        // With the primer, the video loads paused and starts once the link is wide (`holdForLink`).
        holdingForLink = primes
        loading?.cancel()
        // A live stream has to be declared to the engine; it plays from the live edge. A Live TV channel
        // comes declared by the page, which spares it `LiveHLS`'s requests (the master playlist, then its
        // first variant, each on a connection of its own, before the engine asks for them again) and plays
        // a raw MPEG-TS channel, which isn't a playlist, as live too. Anything else that could be a playlist
        // is asked, alongside the audio session's activation rather than after it.
        let declaredLive = asLive || onAVPlayer || request.live
        let checks = !declaredLive && !request.isTrailer && LiveHLS.mayBePlaylist(url)
        loading = Task { [weak self] in
            async let checked: LiveHLS.Verdict? = checks ? LiveHLS.check(url, headers: request.headers) : nil
            await withCheckedContinuation { done in AudioOutput.activate { done.resume() } }
            guard let self, generation == self.generation else { return }
            // Silent Dolby through the load, until the video's sound has started, so decoded
            // multichannel sound isn't downmixed into a stereo link (Continuous Audio Connection off).
            // A trailer goes without: it's a couple of minutes long and nearly always stereo.
            if request.isTrailer {
                AudioOutput.stopPrimer(after: 0)
            } else {
                AudioOutput.startPrimer()
            }
            var live = declaredLive
            if let verdict = await checked {
                guard generation == self.generation else { return }
                live = verdict.live
                EngineLogBook.note("[player] live check: \(verdict.reason) (\(Self.shortened(url)))")
            } else if request.live, !asLive {
                EngineLogBook.note("[player] live: the page says so (\(Self.shortened(url)))")
            }
            guard generation == self.generation else { return }
            if asLive { EngineLogBook.note("[player] loading again as live (\(Self.shortened(url)))") }
            if onAVPlayer { EngineLogBook.note("[player] loading the live channel again on AVPlayer (\(Self.shortened(url)))") }
            do {
                try await self.engine.load(
                    url: url,
                    startPosition: !live && request.startMs > 0 ? request.startMs / 1000 : nil,
                    options: self.options(for: request, live: live)
                )
                guard generation == self.generation else { return }
                self.loaded(request)
            } catch is CancellationError {
                // Another load took its place.
            } catch {
                guard generation == self.generation else { return }
                self.failed(error.localizedDescription)
            }
        }
    }

    /// How the file plays: mostly the page's sound settings, read for Atmos (see the type's notes).
    private func options(for request: LoadRequest, live: Bool) -> LoadOptions {
        var options = LoadOptions()
        options.httpHeaders = request.headers
        // The engine takes a live playlist onto its own HLS reader, which puts the headers on every playlist
        // and segment request: a `.m3u8` at once, any other address once it answers with a playlist (AE#363).
        // Without this it plays the playlist in AVPlayer as a finished one.
        options.isLive = live
        // Loaded again for its sound (`liveOnAVPlayer`): AVPlayer reads the live playlist itself.
        if live && liveOnAVPlayer { options.nativeRemoteHLS = true }
        // The open's probe budget stays the engine's (60 s of the stream). A 5 s cap on live opens left an
        // IPTV channel's AC-3 tracks unidentified ("Could not find codec parameters ... unspecified sample
        // rate"): the session played the picture with no sound, which other players had (Nov 2026).
        // Held for the link, it plays from `releaseHold` instead.
        options.autoplay = !paused && !holdingForLink
        options.preferredAudioLanguages = request.audioLanguages
        // Matching tracks are confirmed as Atmos in the background, for the track names and the statistics.
        // The engine would skip the pass on a held source connection (the default here), which it reads
        // as an origin that refuses a second request. This app holds it for throughput, and debrid and
        // Jellyfin sources take a second request, so the pass runs on its own handle either way.
        options.confirmAtmos = true
        options.confirmsAtmosOnHeldSourceConnection = true
        if let manager = view.window?.avDisplayManager {
            options.matchContentEnabled = manager.isDisplayCriteriaMatchingEnabled
        }
        // TrueHD, DTS and DTS-HD can't leave an Apple TV as a bitstream, so they're decoded and reach
        // the receiver as multichannel PCM, up to 7.1, as Infuse plays them: TrueHD Atmos and DTS:X
        // as their 7.1, without the objects and heights, unless the page's Object audio switch is on
        // (below). A TV's plain ARC takes only stereo PCM, so a soundbar behind one gets stereo;
        // `.surroundCompat` would give it Dolby Digital Plus 5.1 instead, lossy, with 7.1 folded into
        // 5.1, which is why it isn't used. E-AC-3 and AC-3 are copied on the AVPlayer route either way.
        options.audioBridgeMode = .lossless
        // The page's Object audio switch, off by default: the engine renders TrueHD Atmos objects and
        // DTS:X heights into the page's Speakers layout, 7.1.4 (the default) or 9.1.6, the two DTS:X
        // renders into. tvOS sends it to the receiver as 12 or 16 channels of PCM inside Dolby MAT, so
        // the receiver shows Atmos, and fits it to the speakers it has. Only on
        // tvOS 26 and later, at 48 kHz, and not with any shaping (stereo, 5.1, dialogue boost, night
        // mode); the rest keeps the 7.1 above. With it on, the engine's automatic audio pick also
        // prefers a TrueHD Atmos or DTS:X track over another format in the same language. On the
        // engine's software player (AV1, VP9, interlaced H.264, Hardware decoding off) an E-AC-3 Atmos
        // track used to go to tvOS's renderer compressed, which played nothing (de850fa); since engine
        // 7.59 (AE#995) tvOS's own Atmos decoder renders it into the speaker bed, as TrueHD Atmos is.
        // Only with the page's Audio channels on Automatic, the one setting the page shows the switch
        // under: 7.1 is a limit too, and plays their 7.1; Stereo and 5.1 shape the sound, which the
        // engine would put ahead of the render anyway.
        if settings.objectAudio && settings.audioChannels == "auto" {
            options.objectAudioRendering = .render(settings.objectAudioLayout)
        }
        options.audioShaping = shaping
        options.audioDelaySeconds = settings.audioDelayMs / 1000
        if !settings.hardwareDecoding { options.preferredDecodePath = .software }
        // Dolby Vision plays as its HDR10 / HLG base layer, HDR10+ metadata included, on a TV without Dolby
        // Vision always and on a Dolby Vision TV when the page's Dolby Vision switch is off: no Profile 7 ->
        // 8.1 RPU conversion and no Dolby Vision in the container, so AVPlayer composes nothing per frame.
        // Profile 5 has no base layer and keeps Dolby Vision either way.
        if !settings.dolbyVision || !AetherEngine.displayCapabilities.supportsDolbyVision {
            options.dolbyVisionHandling = .baseLayerOnly
        }
        // The page's Cache size: the engine buffers ahead until the cache holds that much, and keeps what
        // played behind it in the same space, so a seek back is at once. The window is the engine's
        // whole-source opt-in, bounded by those bytes (`PrefetchDiskBudget`) rather than a count of
        // segments, as the file's bitrate isn't known before it opens. It stays at least 10 segments
        // (~40 s) ahead whatever the size, and a quarter of the free space caps it.
        // Automatic buffers 10 minutes ahead, which a remux needs to ride out a slow stretch of the
        // source: about 6 GB at 80 Mbit/s. The engine's own automatic (~40 s ahead) is a few hundred
        // MB of a remux, gone in one hiccup. The bytes are left to the engine's quarter of the free
        // space, so a fuller Apple TV buffers less than 10 minutes rather than filling up. The
        // engine's software player keeps its packets in memory on tvOS, 96 MB ahead and 128 MB
        // behind, and neither changes anything there.
        // Live can't be read ahead of the broadcast, so it keeps the engine's own live window (nothing set).
        if live {
        } else if settings.cacheMb > 0 {
            options.forwardBufferSegments = Self.cacheWindowSegments
            options.sessionCacheByteBudget = settings.cacheMb * 1_000_000
        } else {
            options.forwardBufferSegments = Self.automaticWindowSegments
            // Without a budget, a window of 150 or fewer keeps the engine's 2 GiB cap, under 4 minutes
            // of a remux. Asking for more than any Apple TV holds leaves only the quarter-of-free-space
            // cap; 1 TiB rather than Int.max, so nothing the engine adds to it can overflow.
            options.sessionCacheByteBudget = 1 << 40
        }
        options.heldSourceConnection = Self.heldSourceConnection
        openedHeld = options.heldSourceConnection
        // ASS and SSA cues come as their event lines, for libass (`SubtitleOverlay`); other formats are unaffected.
        options.preserveASSMarkup = true
        // A text subtitle rendition AVPlayer can show itself, for the picture-in-picture window, where the
        // app's overlay can't go. Selected only while the window shows (`setPictureInPicture`).
        options.prepareNativeSubtitles = true
        return options
    }

    /// The engine's largest forward window (about 3 hours of 4 s segments): with a Cache size set, the
    /// bytes bound the buffer, not this.
    private static let cacheWindowSegments = 2700
    /// Automatic's forward window: 10 minutes of the engine's 4 s segments.
    private static let automaticWindowSegments = 150

    /// The page's channel limit, dialogue boost and night mode. Shaping needs the decoded sound, so any of them
    /// costs passthrough and Atmos; 7.1 and Automatic with no boost and night mode off shape nothing.
    private var shaping: AudioShaping {
        let maxChannels: Int?
        switch settings.audioChannels {
        case "stereo": maxChannels = 2
        case "5.1": maxChannels = 6
        default: maxChannels = nil
        }
        return AudioShaping(
            maxChannels: maxChannels,
            dialogueGainDB: settings.dialogueBoost,
            compressor: settings.nightMode ? .night : nil
        )
    }

    private func loaded(_ request: LoadRequest) {
        // A live channel whose audio the engine's live-ingest reader identified none of plays silent there
        // (`liveOnAVPlayer`): once more on AVPlayer, before the page hears it loaded.
        let audio = engine.audioTracks
        if engine.isLive, !liveOnAVPlayer, engine.videoRoute != .remoteBypass,
           !audio.isEmpty, audio.allSatisfy({ $0.channels <= 0 }) {
            let codecs = Set(audio.map(\.codec)).sorted().joined(separator: ", ")
            EngineLogBook.note("[player] live audio unidentified on the engine's reader (\(audio.count) tracks, \(codecs), 0 channels)")
            start(request, onAVPlayer: true)
            return
        }
        // Whether a channel that starts frozen was loaded paused by the app or stopped on its own.
        if engine.isLive {
            EngineLogBook.note("[player] live channel loaded on \(liveOnAVPlayer ? "AVPlayer" : "\(engine.videoRoute)"), "
                + "\(paused ? "paused, as the page last asked" : "playing"), engine \(engine.state)")
        }
        if paused { engine.pause() }
        if speed != 1 { engine.setRate(Float(speed)) }
        applyVolume()
        // The fonts the file carries for its ASS subtitles, before a track is picked; libass needs them for the
        // signs and typesetting. Read once the file has opened, so a track picked during the load starts over.
        subtitles.setFonts(engine.fontAttachments)
        pickSubtitle(request)
        reportTracks()
        reportChapters()
        if engine.duration > 0 { listener?.playerState(["durationMs": engine.duration * 1000]) }
        listener?.playerEvent("loaded")
        if holdingForLink { holdForLink() }
        if engine.isLive { nudgeFrozenLiveStart() }
    }

    /**
     * A live channel can start frozen on its first picture and play, with sound, after a pause and play.
     * The app does that pause and play itself, once, `frozenStartWait` after the load, unless the page
     * has paused it: on AVPlayer (`liveOnAVPlayer`) always, as its clock may move while the picture holds;
     * on the engine's own reader when the clock hasn't moved. A channel there froze too (Nov 9 report:
     * software decode, joined at a keyframe, its clock armed at the join and still there, 0.0 Mbps from
     * the source since), so the nudge isn't AVPlayer's alone. The engine's `play()` also takes a live
     * playhead behind the window to it, which a pause and play by hand did.
     *
     * The first try (7fda951) went to the live edge and played, and only when the clock had moved under
     * half a second: it didn't unfreeze the channel. Likely reasons, from the engine's code: on AVPlayer's
     * own playlist reading the edge seek returns early when the engine has no live window, `play()` on an
     * AVPlayer already at rate 1 changes nothing, and the clock may move while the picture holds. A
     * pause and play is what the viewer does, and the log lines keep how far the clock moved.
     */
    private func nudgeFrozenLiveStart() {
        let generation = generation
        let startedAt = engine.clock.currentTime
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.frozenStartWait * 1_000_000_000))
            guard let self, generation == self.generation, self.current != nil, !self.ended,
                  !self.paused, !self.holdingForLink, !self.reopening else { return }
            let moved = self.engine.clock.currentTime - startedAt
            let route = self.liveOnAVPlayer ? "AVPlayer" : "\(self.engine.videoRoute)"
            // The engine's own reader moves its clock only as it plays, so a moving one is playing.
            guard self.liveOnAVPlayer || moved < Self.frozenMoveSeconds else { return }
            EngineLogBook.note(String(format: "[player] the live channel on %@ moved %.1f s in %.0f s (%@, %@); pausing and playing it once",
                                      route, moved, Self.frozenStartWait, "\(self.engine.state)",
                                      self.engine.isBuffering ? "buffering" : "not buffering"))
            // Hidden from the page, as `settleAudio`'s pause and play is.
            self.reopening = true
            self.engine.pause()
            try? await Task.sleep(nanoseconds: UInt64(Self.frozenPauseSeconds * 1_000_000_000))
            guard generation == self.generation, self.current != nil, !self.ended else {
                self.reopening = false
                return
            }
            // Paused from the page meanwhile: it stays paused, and the page already knows.
            if !self.paused { self.engine.play() }
            // The play's own state change arrives after this call.
            DispatchQueue.main.async { self.reopening = false }
            guard !self.paused else { return }
            let resumedAt = self.engine.clock.currentTime
            try? await Task.sleep(nanoseconds: UInt64(Self.frozenStartWait * 1_000_000_000))
            guard generation == self.generation, self.current != nil, !self.ended else { return }
            EngineLogBook.note(String(format: "[player] after the pause and play, the live channel moved %.1f s in %.0f s",
                                      self.engine.clock.currentTime - resumedAt, Self.frozenStartWait))
        }
    }

    /// How long a live channel plays after its load before the app pauses and plays it.
    private static let frozenStartWait: TimeInterval = 3
    /// The pause between, about a viewer's press and press again.
    private static let frozenPauseSeconds: TimeInterval = 0.5
    /// Less than this in `frozenStartWait`, on the engine's own reader, and the channel hasn't started.
    private static let frozenMoveSeconds: TimeInterval = 0.5

    /**
     * How long the start is held for the soundbar to take the Dolby and widen the link, and how often
     * the session is looked at meanwhile. The session has read 2 channels on a wide link too (the
     * README's measurements), so the hold is usually all of this: an early start is for a route that
     * does report its width. On trial, like the pause and play after it.
     */
    private static let holdLongest: TimeInterval = 3
    private static let holdLook: TimeInterval = 0.25

    /// Sound the Apple TV decodes into more than 2 channels of PCM, which a stereo link downmixes.
    private var decodedChannels: Int? {
        guard let audio = activeAudio else { return nil }
        let decoded = engine.audioDelivery == .decoded
            || (engine.audioDelivery == .bridged && engine.loadedAudioIsLossless)
        var sent = audio.channels
        if let limit = shaping.maxChannels { sent = min(sent, limit) }
        return decoded && sent > 2 ? sent : nil
    }

    /**
     * The video has loaded paused, the Dolby primer playing since before the load. Sound the Apple TV
     * decodes into more than 2 channels waits `holdLongest`, the page still showing buffering, for the
     * soundbar to take the Dolby and widen the link (sooner if the session's output says it has more
     * than 2 channels); then the video plays while the Dolby still does, so its sound is set up on the
     * wide link rather than at the stereo it found. Everything else plays at once. The pause and play
     * after the Dolby (`settleAudio`) stays as the fallback until the soundbar shows it isn't needed.
     */
    private func holdForLink() {
        guard let sent = decodedChannels, AudioOutput.routeIsHDMI, AudioOutput.primerPlaying else {
            return releaseHold(note: nil)
        }
        let generation = generation
        let began = ProcessInfo.processInfo.systemUptime
        func look() {
            guard generation == self.generation, holdingForLink, current != nil, !ended else { return }
            let waited = ProcessInfo.processInfo.systemUptime - began
            let inUse = AudioOutput.channelsInUse
            let held = String(format: "%.1f", waited)
            if inUse > 2 {
                releaseHold(note: "held the start \(held) s, until the link had \(inUse) ch (\(sent) ch track)")
            } else if waited >= Self.holdLongest {
                releaseHold(note: "held the start \(held) s under the Dolby; the session read \(inUse) ch of "
                    + "\(AudioOutput.channelsAvailable) (\(sent) ch track)")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdLook) { look() }
            }
        }
        look()
    }

    /// Ends the hold: the video plays (unless the page paused it meanwhile), and its first picture counts.
    private func releaseHold(note: String?) {
        guard holdingForLink else { return }
        holdingForLink = false
        if let note { AudioOutput.notePrimer(note) }
        if !paused { engine.play() }
        if engine.hasFirstFrameReadyForDisplay { firstFrameShown() }
    }

    /// The video shows its first picture and plays: the page stops showing buffering.
    private func firstFrameShown() {
        // The HDMI link widens from its idle stereo once sound plays (Continuous Audio Connection off).
        AudioOutput.playbackStarted()
        // The video's own sound plays alongside the Dolby, then alone, then is paused and played if the
        // link is still at stereo.
        settleAudio(after: 3)
        listener?.playerState(["buffering": false, "paused": paused])
        listener?.playerEvent("restart")
    }

    private func failed(_ error: String) {
        guard !ended else { return }
        keepLastVideo(ending: "failed: \(error)")
        ended = true
        // An HLS playlist the live check took for a finished video, which AVPlayer then gave up on, as it
        // does on a live one it's told is finished: once more as live, before the page hears of it.
        // A finished HLS that knows its length failed for its own reasons, and goes to the page.
        if !reloadedAsLive, !engine.isLive, engine.videoRoute == .remoteBypass, !(engine.duration > 0),
           let request = current, !request.isTrailer {
            EngineLogBook.note("[player] AVPlayer gave up on the HLS as a finished video: \(error)")
            start(request, asLive: true)
            return
        }
        let info = engine.errorInfo
        var status: Int?
        if let code = info?.underlyingCode, (400..<600).contains(code),
           info?.kind == .sourceRefused || info?.kind == .sourceRateLimited || info?.kind == .sourceOpenFailed {
            status = code
        }
        NSLog("[player] failed: %@ (%@)", error, info.map { "\($0.kind.rawValue)" } ?? "no kind")
        holdingForLink = false
        AudioOutput.stopPrimer(after: 0)
        listener?.playerEnded(reason: "error", error: error, cause: info?.message, status: status)
        listener?.playerState(["idle": true, "buffering": false])
    }

    func stop() {
        generation += 1
        holdingForLink = false
        loading?.cancel()
        loading = nil
        queued = nil
        let wasPlaying = current != nil && !ended
        if wasPlaying { keepLastVideo(ending: "stopped") }
        endLineWatch()
        current = nil
        ended = true
        engine.stop()
        AudioOutput.stopPrimer(after: 0)
        subtitles.reset()
        if wasPlaying { listener?.playerEnded(reason: "stop", error: nil, cause: nil, status: nil) }
        listener?.playerState(["idle": true, "buffering": false, "seeking": false])
    }

    func change(_ change: Change) {
        if let paused = change.paused {
            self.paused = paused
            // Held for the link, play waits for `releaseHold`, which reads `paused`.
            if current != nil, !holdingForLink {
                if paused { engine.pause() } else { engine.play() }
            }
            listener?.playerState(["paused": paused])
        }
        if let volume = change.volume { self.volume = volume }
        if let muted = change.muted { self.muted = muted }
        if change.volume != nil || change.muted != nil {
            applyVolume()
            listener?.playerState(["volume": self.volume, "muted": self.muted])
        }
        if let speed = change.speed {
            self.speed = speed
            engine.setRate(Float(speed))
            listener?.playerState(["speed": Double(min(Float(speed), engine.maxSupportedRate))])
        }
        if case .track(let id)? = change.audio, let index = Int(id) {
            // A switch to a decoded track rebuilds the sound; the Dolby holds the link over the change.
            if primes { AudioOutput.startPrimer() }
            engine.selectAudioTrack(index: index)
            settleAudio(after: 6)
        }
        if let subtitle = change.subtitle {
            switch subtitle {
            case .track(let id): if let index = Int(id) { engine.selectSubtitleTrack(index: index) }
            case .off: engine.clearSubtitle()
            }
        }
        if let delay = change.subtitleDelayMs { subtitles.delay = delay / 1000 }
    }

    func seek(_ positionMs: Double) {
        guard current != nil else { return }
        let seconds = max(0, positionMs / 1000)
        Task { [weak self] in await self?.engine.seek(to: seconds) }
    }

    /// From the server, or a file the user added, shown in place of track `replace`.
    func addSubtitle(_ url: URL, title: String?, language: String?, replace: Int?, pageURL: String?) {
        guard current != nil else { return }
        if let replace, replace >= AetherEngine.externalSubtitleTrackIDBase {
            engine.removeExternalSubtitleTrack(id: replace)
            addedSubtitles[replace] = nil
        }
        let format = ["srt", "ass", "ssa", "vtt", "sup"].first { url.pathExtension.lowercased() == $0 }
        // What was added, for the app menu's report beside the engine's `sidecar decode failed` if it fails.
        EngineLogBook.note("[subtitles] adding \(url.isFileURL ? "a file the user added" : Self.shortened(url)) as \(format ?? "an unnamed format")")
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url,
            name: title.flatMap { $0.isEmpty ? nil : $0 },
            language: language.flatMap { $0.isEmpty ? nil : $0 },
            formatHint: format
        ))
        if let pageURL { addedSubtitles[track.id] = pageURL }
        engine.selectSubtitleTrack(index: track.id)
        reportTracks()
    }

    func setStyle(_ style: Style) {
        switch style.fit {
        case .fit: engine.videoGravity = .resizeAspect
        case .crop: engine.videoGravity = .resizeAspectFill
        case .stretch: engine.videoGravity = .resize
        }
        subtitles.setStyle(style)
    }

    func setSettings(_ next: PlayerSettings) {
        let old = settings
        settings = next
        guard current != nil, !ended else { return }
        // The rest is read at the next load.
        if next.audioDelayMs != old.audioDelayMs { engine.setAudioDelay(next.audioDelayMs / 1000) }
        if next.audioChannels != old.audioChannels || next.dialogueBoost != old.dialogueBoost
            || next.nightMode != old.nightMode {
            engine.setAudioShaping(shaping)
        }
    }

    private func applyVolume() {
        engine.volume = muted ? 0 : Float(min(1, max(0, volume)))
    }

    // MARK: Subtitle choice

    /**
     * The page's subtitle mode, as mpv's options for it pick: `default` the
     * first preferred language, else the file's default track, else forced
     * ones in the audio's language; `always` falls back to any track; `smart`
     * shows only forced ones when the audio is already in a preferred language;
     * `forced` only forced ones; `none` none.
     */
    private func pickSubtitle(_ request: LoadRequest) {
        let tracks = engine.subtitleTracks.filter { !$0.isExternal }
        let audioLanguage = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }?.language
        let wanted = request.subtitleLanguages
        func speaks(_ track: TrackInfo, _ code: String?) -> Bool {
            guard let code, let language = track.language else { return false }
            return Self.sameLanguage(language, code)
        }
        func preferred() -> TrackInfo? {
            for code in wanted {
                if let track = tracks.first(where: { speaks($0, code) && !$0.isForced }) ?? tracks.first(where: { speaks($0, code) }) {
                    return track
                }
            }
            return nil
        }
        let forced = tracks.first { $0.isForced && speaks($0, audioLanguage) } ?? tracks.first { $0.isForced && $0.language == nil }
        var pick: TrackInfo?
        switch request.subtitleMode {
        case .none:
            pick = nil
        case .forced:
            pick = forced ?? tracks.first { $0.isForced }
        case .always:
            pick = preferred() ?? tracks.first { $0.isDefault } ?? tracks.first
        case .smart:
            let audioWanted = wanted.contains { code in audioLanguage.map { Self.sameLanguage($0, code) } ?? false }
            pick = audioWanted ? forced : preferred() ?? forced
        case .default:
            pick = preferred() ?? tracks.first { $0.isDefault && !$0.isForced } ?? forced
        }
        if let pick {
            if engine.activeSubtitleTrackIndex != pick.id { engine.selectSubtitleTrack(index: pick.id) }
        } else if engine.activeSubtitleTrackIndex != nil {
            engine.clearSubtitle()
        }
    }

    /// `en` and `eng`, or `pt` and `pt-BR`, as mpv matches them.
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        if a == b { return true }
        let baseA = a.split(separator: "-").first.map(String.init) ?? a
        let baseB = b.split(separator: "-").first.map(String.init) ?? b
        if baseA == baseB { return true }
        let short = baseA.count < baseB.count ? baseA : baseB
        let long = baseA.count < baseB.count ? baseB : baseA
        return short.count == 2 && long.count == 3 && (Self.twoToThree[short] ?? []).contains(long)
    }

    /// The ISO 639-1 codes whose ISO 639-2 forms don't start with them, and the common ones that do.
    private static let twoToThree: [String: Set<String>] = [
        "en": ["eng"], "es": ["spa"], "fr": ["fre", "fra"], "de": ["ger", "deu"], "it": ["ita"],
        "pt": ["por"], "nl": ["dut", "nld"], "sv": ["swe"], "no": ["nor", "nob", "nno"], "da": ["dan"],
        "fi": ["fin"], "pl": ["pol"], "cs": ["cze", "ces"], "sk": ["slo", "slk"], "hu": ["hun"],
        "ro": ["rum", "ron"], "el": ["gre", "ell"], "tr": ["tur"], "ru": ["rus"], "uk": ["ukr"],
        "ja": ["jpn"], "ko": ["kor"], "zh": ["chi", "zho"], "ar": ["ara"], "he": ["heb"], "hi": ["hin"],
        "th": ["tha"], "vi": ["vie"], "id": ["ind"], "ms": ["may", "msa"], "fa": ["per", "fas"],
        "bg": ["bul"], "hr": ["hrv"], "sr": ["srp"], "sl": ["slv"], "et": ["est"], "lv": ["lav"],
        "lt": ["lit"], "is": ["ice", "isl"], "ca": ["cat"], "eu": ["baq", "eus"], "gl": ["glg"],
        "cy": ["wel", "cym"], "ga": ["gle"], "sq": ["alb", "sqi"], "mk": ["mac", "mkd"], "hy": ["arm", "hye"],
        "ka": ["geo", "kat"], "ta": ["tam"], "te": ["tel"], "bn": ["ben"], "ur": ["urd"], "tl": ["tgl"], "fil": ["fil"],
    ]

    // MARK: Reports

    private func watch() {
        engine.$state
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &watching)
        engine.$isBuffering
            .removeDuplicates()
            .sink { [weak self] buffering in
                // Held for the link, the page goes on seeing the load's buffering.
                guard let self, self.current != nil, !self.ended, !self.holdingForLink else { return }
                self.listener?.playerState(["buffering": buffering])
                // Waiting for data mid-play; a seek, a load and a track switch's reload wait too, by design.
                if buffering, self.engine.hasFirstFrameReadyForDisplay, !self.engine.isSeeking,
                   self.engine.state == .playing || self.engine.state == .paused {
                    self.health.stalled(position: self.engine.clock.currentTime,
                                        softwareRoute: self.engine.videoRoute == .software,
                                        producerSlow: EngineLogBook.producerSlow(since: self.health.startedAt),
                                        objectAudio: self.engine.liveTelemetry?.objectAudio != nil)
                    if let stall = self.health.stallRecord.last {
                        let time = DateFormatter.localizedString(from: stall.at, dateStyle: .none, timeStyle: .medium)
                        let name = self.title ?? self.current.flatMap { URL(string: $0.url)?.lastPathComponent } ?? "?"
                        EngineLogBook.noteStall("\(time), \(name): \(stall.verdict) (\(stall.figures))")
                    }
                }
            }
            .store(in: &watching)
        engine.diagnostics.$liveTelemetry
            .compactMap { $0 }
            .sink { [weak self] telemetry in
                guard let self, self.current != nil, !self.ended else { return }
                let playing = self.engine.state == .playing && !self.engine.isBuffering
                self.health.record(telemetry, playing: playing, at: ProcessInfo.processInfo.systemUptime)
            }
            .store(in: &watching)
        engine.$isSeeking
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] seeking in
                guard let self, self.current != nil, !self.ended else { return }
                self.listener?.playerState(["seeking": seeking])
                // mpv's playback-restart: playing again after a seek.
                if !seeking { self.listener?.playerEvent("restart") }
            }
            .store(in: &watching)
        engine.$hasFirstFrameReadyForDisplay
            .removeDuplicates()
            .sink { [weak self] ready in
                // Held for the link, the first picture counts once the video plays (`releaseHold`).
                guard let self, ready, self.current != nil, !self.ended, !self.holdingForLink else { return }
                self.firstFrameShown()
            }
            .store(in: &watching)
        engine.$duration
            .removeDuplicates()
            .sink { [weak self] duration in
                guard let self, self.current != nil, !self.ended, duration > 0 else { return }
                self.listener?.playerState(["durationMs": duration * 1000])
            }
            .store(in: &watching)
        engine.clock.$currentTime
            .sink { [weak self] seconds in self?.positionChanged(seconds) }
            .store(in: &watching)
        engine.clock.$sourceTime
            .sink { [weak self] seconds in self?.subtitles.setTime(seconds) }
            .store(in: &watching)
        engine.$subtitleCues
            .sink { [weak self] cues in self?.subtitles.setCues(cues) }
            .store(in: &watching)
        // Whether the track's cues are ASS event lines, and the header libass styles them with: an
        // embedded track's from the container, a file's from its own decode.
        Publishers.CombineLatest3(engine.$activeSubtitleTrackIndex, engine.$sidecarASSHeader, engine.$subtitleTracks)
            .sink { [weak self] index, sidecarHeader, tracks in
                let track = index.flatMap { id in tracks.first { $0.id == id } }
                let isASS = track.map { ["ass", "ssa"].contains($0.codec.lowercased()) } ?? false
                let header = track.flatMap { $0.isExternal ? sidecarHeader : $0.assHeader }
                self?.subtitles.setASSTrack(id: index, raw: isASS || header != nil, header: header)
            }
            .store(in: &watching)
        Publishers.CombineLatest(engine.$audioTracks, engine.$subtitleTracks)
            .dropFirst()
            .sink { [weak self] _, _ in
                // The values arrive before the engine stores them; read them once it has.
                DispatchQueue.main.async { self?.reportTracks() }
            }
            .store(in: &watching)
        engine.$activeAudioTrackIndex
            .removeDuplicates()
            .sink { [weak self] index in
                guard let self, self.current != nil else { return }
                self.listener?.playerState(["audio": nullable(index.map(String.init))])
                DispatchQueue.main.async { self.reportPassthrough() }
            }
            .store(in: &watching)
        engine.$activeSubtitleTrackIndex
            .removeDuplicates()
            .sink { [weak self] index in
                guard let self, self.current != nil else { return }
                self.listener?.playerState(["subtitle": nullable(index.map(String.init))])
            }
            .store(in: &watching)
        engine.$audioDelivery
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reportPassthrough() } }
            .store(in: &watching)
        engine.$mediaChapters
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reportChapters() } }
            .store(in: &watching)
        // The picture's rectangle moves with the route and the video's size.
        Publishers.Merge3(
            engine.$videoRoute.map { _ in () },
            engine.$softwareDisplaySize.map { _ in () },
            engine.$hasFirstFrameReadyForDisplay.map { _ in () }
        )
        .sink { [weak self] in DispatchQueue.main.async { self?.subtitles.setNeedsLayout() } }
        .store(in: &watching)
    }

    /// How long after the Dolby stops `settleAudio` pauses the video, and for how long: 5 s and 1 s, as
    /// measured to work. 2 s and 0.3 s left the soundbar at stereo PCM until a second pause and play by hand.
    private static let reopenAfterPrimer: TimeInterval = 5
    private static let reopenPause: TimeInterval = 1

    /// The file gets the Dolby primer and `settleAudio`'s pause and play: everything but a trailer, while
    /// the app menu's switch for them is on (`AudioOutput.primerEnabled`, off by default).
    private var primes: Bool { current?.isTrailer != true && AudioOutput.primerEnabled }

    /**
     * Ends the Dolby primer `after` seconds from now, then, for sound the Apple TV decodes over more
     * than 2 channels, pauses and plays the video once the soundbar has settled on its PCM.
     *
     * The Dolby widens the HDMI link, but the video's player set its sound output up at stereo
     * before that and keeps it until a pause and play. Measured on the soundbar, all with
     * Continuous Audio Connection off:
     * - The Dolby stopping while the TrueHD played on, then a pause and play by hand some seconds
     *   later: stereo PCM, then multichannel PCM. Twice, on two builds.
     * - A pause and play just as the Dolby stopped: the link was silent for half a second and fell
     *   back to stereo, and no later pause and play brought it back.
     * - A pause and play while the Dolby still played: stereo PCM after the Dolby stopped, and
     *   multichannel PCM after a pause and play by hand.
     * So the Dolby stops while the video plays, and the pause comes `reopenAfterPrimer` later.
     * Hidden from the page.
     */
    private func settleAudio(after delay: TimeInterval) {
        AudioOutput.stopPrimer(after: delay)
        guard primes else { return }
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.reopenAfterPrimer) { [weak self] in
            guard let self, generation == self.generation, self.current != nil, !self.ended,
                  !self.paused, !self.reopening, self.engine.state == .playing,
                  let audio = self.activeAudio else { return }
            let decoded = self.engine.audioDelivery == .decoded
                || (self.engine.audioDelivery == .bridged && self.engine.loadedAudioIsLossless)
            var sent = audio.channels
            if let limit = self.shaping.maxChannels { sent = min(sent, limit) }
            guard decoded, sent > 2 else { return }
            // Always, whatever the session reads: it read 32 channels just after the Dolby stopped with
            // the video's sound still downmixed to 2, so its count can't skip this.
            self.reopening = true
            self.engine.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reopenPause) { [weak self] in
                guard let self else { return }
                guard generation == self.generation, self.current != nil, !self.ended else {
                    self.reopening = false
                    return
                }
                // Paused from the page meanwhile: it stays paused, and the page already knows.
                if !self.paused { self.engine.play() }
                AudioOutput.notePrimer("paused and played the video \(Int(Self.reopenAfterPrimer)) s later, "
                    + "\(audio.channels) ch \(audio.codec)")
                // The play's own state change arrives after this call.
                DispatchQueue.main.async { self.reopening = false }
            }
        }
    }

    private func stateChanged(_ state: PlaybackState) {
        guard current != nil, !ended else { return }
        // Loaded paused for the link: buffering to the page, not paused.
        if holdingForLink, case .paused = state { return }
        // `settleAudio`'s own pause and play.
        if reopening {
            switch state {
            case .paused, .playing: return
            default: break
            }
        }
        switch state {
        case .playing:
            listener?.playerState(["paused": false])
        case .paused:
            listener?.playerState(["paused": true])
        case .ended:
            keepLastVideo(ending: "played to the end")
            ended = true
            listener?.playerEnded(reason: "eof", error: nil, cause: nil, status: nil)
            if let next = queued {
                start(next)
            } else {
                listener?.playerState(["idle": true])
            }
        case .error(let message):
            failed(message)
        case .idle, .loading, .seeking:
            break
        }
    }

    private func positionChanged(_ seconds: Double) {
        guard current != nil, !ended, engine.state != .loading else { return }
        var state: Message = ["positionMs": seconds * 1000]
        let ahead = engine.clock.bufferedPosition
        if ahead != lastBuffered {
            lastBuffered = ahead
            state["buffered"] = ahead > seconds ? [["startMs": seconds * 1000, "endMs": ahead * 1000]] : []
        }
        listener?.playerState(state)
    }

    // MARK: Reference lines

    /// The file's own subtitle track the page is lining an added one up against, decoded beside the one
    /// shown and never drawn, and the lines already handed over.
    private var watchedTrack: Int?
    private var sentLines = Set<String>()
    private var lineWatch: AnyCancellable?
    private var indexWatch: Task<Void, Never>?
    /// The file's subtitle index, read once per file (`SubtitleIndex`); nil inside for a file without one.
    private var fileIndex: (url: String, timelines: Task<[SubtitleIndex.Timeline]?, Never>)?

    /**
     * The page's `player-subtitle-index`: when each of the file's own subtitles' lines show, by the
     * engine's track id, from the file's index; nil without one. The index lists the subtitles in file
     * order, the engine's ids are FFmpeg's stream indexes, also in file order, so the two pair up
     * when they count the same tracks of the same kinds, as the desktop app pairs them with mpv's.
     */
    func subtitleIndex() async -> [Int: [(start: Double, end: Double)]]? {
        guard let request = current, let url = URL(string: request.url) else { return nil }
        if fileIndex?.url != request.url {
            let headers = request.headers
            fileIndex = (request.url, Task {
                do {
                    let timelines = try await SubtitleIndex.read(url: url, headers: headers)
                    EngineLogBook.note("[sync] the file's index lists \(timelines.count) subtitle tracks: "
                        + timelines.map { "\($0.codec) \($0.lines.count) lines" }.joined(separator: ", "))
                    return timelines
                } catch {
                    EngineLogBook.note("[sync] no index of the file's subtitles: \(error)")
                    return nil
                }
            })
        }
        guard let timelines = await fileIndex?.timelines.value, !timelines.isEmpty,
              current?.url == request.url else { return nil }
        // The engine's tracks come with its read of the file's header, which may still be going on.
        var own = ownSubtitleTracks()
        for _ in 0..<20 where own.isEmpty && current?.url == request.url {
            try? await Task.sleep(nanoseconds: 250_000_000)
            own = ownSubtitleTracks()
        }
        guard own.count == timelines.count,
              zip(own, timelines).allSatisfy({ Self.isPictureCodec($0.codec) == $1.isPicture }) else {
            EngineLogBook.note("[sync] the file's index doesn't pair with the player's subtitles: index "
                + timelines.map(\.codec).joined(separator: ", ") + "; player "
                + own.map { "\($0.id) \($0.codec)" }.joined(separator: ", "))
            return nil
        }
        return Dictionary(uniqueKeysWithValues: zip(own, timelines).map { ($0.id, $1.lines) })
    }

    private func ownSubtitleTracks() -> [TrackInfo] {
        engine.subtitleTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }
    }

    /**
     * The page's `player-subtitle-lines`: the times of `id`'s lines, for its automatic subtitle sync,
     * which compares them with an added subtitle's. All at once from the file's index where it has
     * one; otherwise, and for a text track also, as the engine decodes the track on its second
     * subtitle channel, so what's on screen is untouched. Nil, or a track that isn't the file's own,
     * stops.
     */
    func watchLines(track id: String?, onLines: @escaping ([Message]) -> Void) {
        endLineWatch()
        guard let id else { return }
        // Each step in the app menu's log, so a sync that never settles shows where it stopped.
        guard current != nil, !ended else {
            return EngineLogBook.note("[sync] the page asked for track \(id)'s lines with nothing playing")
        }
        guard let index = Int(id),
              let track = engine.subtitleTracks.first(where: { $0.id == index && !$0.isExternal }) else {
            return EngineLogBook.note("[sync] the page asked for track \(id)'s lines, which isn't one of the file's own")
        }
        watchedTrack = index
        let pictures = Self.isPictureCodec(track.codec)
        /*
         * Every line from the file's index at once where it has one, as AIOStreams' desktop and Android
         * apps send them: the page's match then has the whole file and settles in a moment, a subtitle
         * timed for another frame rate included, whose drift a few minutes of lines hide. A text track's
         * lines then come from the engine's decode as well, for any the index leaves out; a picture
         * track's come from the index alone, as its decoded ends can still change after it shows.
         */
        indexWatch = Task { [weak self] in
            let indexed = await self?.subtitleIndex()?[index]
            guard let self, !Task.isCancelled, self.watchedTrack == index else { return }
            if let indexed, indexed.count >= Self.fewestIndexedLines {
                EngineLogBook.note(String(format: "[sync] %d lines of track %d from the file's index sent to the page, %.1f s to %.1f s",
                                          indexed.count, index, (indexed.first?.start ?? 0) / 1000, (indexed.last?.end ?? 0) / 1000))
                onLines(indexed.map { line -> Message in ["startMs": line.start, "endMs": line.end] })
                if pictures { return }
            }
            EngineLogBook.note("[sync] reading track \(index)'s lines (\(track.codec), \(track.language ?? "no language")) for the page's subtitle sync")
            self.watchDecoded(index: index, pictures: pictures, onLines: onLines)
        }
    }

    /// Fewer lines in the index than this and it isn't the track's: the decode gives them instead.
    private static let fewestIndexedLines = 10

    /// The lines of the file's own track `index` as the engine's second subtitle channel decodes them.
    private func watchDecoded(index: Int, pictures: Bool, onLines: @escaping ([Message]) -> Void) {
        engine.selectSecondarySubtitleTrack(index: index)
        var reported = 0
        var long = 0
        var skipped = 0
        var lastPlayhead: Double?
        /*
         * A picture subtitle (PGS, DVD, DVB) has no end of its own. The engine publishes each with an
         * open placeholder end (49.7 days) and closes it later from the next packet on its stream, and
         * that end can still shorten after a later picture shows: the engine withholds an end it can't
         * vouch for yet, takes an upper bound across a stretch it hasn't read, and leaves a second
         * picture of the same display set open. The page keeps the first end it gets for a line and
         * drops any longer than 12 s, so taking each picture as soon as a later one came lost those
         * lines or stretched them into the gap after, and the match never came out sure of itself.
         * A picture goes once the playhead has passed its end, as the engine has read past it by
         * then, one line for all the pictures of a display set. A text line's end is its own from
         * the first.
         */
        lineWatch = engine.$secondarySubtitleCues
            .combineLatest(engine.clock.$sourceTime)
            .sink { [weak self] cues, playhead in
                guard let self, self.watchedTrack == index else { return }
                // A jump: pictures behind the new position may be closed at the landing rather than
                // their own end, so the ones not sent yet stay out.
                let jumped = lastPlayhead.map { abs(playhead - $0) > Self.lineJumpSeconds } ?? false
                lastPlayhead = playhead
                var lines: [(start: Double, end: Double)] = []
                if pictures {
                    // A display set's pictures share its start; the line ends with the last of them.
                    var ends: [Double: Double] = [:]
                    for cue in cues where cue.endTime > cue.startTime {
                        let open = cue.endTime - cue.startTime >= Self.openEndedSeconds
                        ends[cue.startTime] = max(ends[cue.startTime] ?? 0, open ? .infinity : cue.endTime)
                    }
                    for (start, end) in ends where start < playhead {
                        let key = "\(start)"
                        if jumped {
                            if self.sentLines.insert(key).inserted { skipped += 1 }
                            continue
                        }
                        guard end <= playhead, self.sentLines.insert(key).inserted else { continue }
                        lines.append((start, end))
                    }
                } else {
                    for cue in cues where cue.endTime > cue.startTime
                        && cue.endTime - cue.startTime < Self.openEndedSeconds {
                        // Cues come again as the decoded window moves; each line goes once.
                        guard self.sentLines.insert("\(cue.startTime)|\(cue.endTime)").inserted else { continue }
                        lines.append((cue.startTime, cue.endTime))
                    }
                }
                guard !lines.isEmpty else { return }
                long += lines.filter { $0.end - $0.start > Self.longestLineSeconds }.count
                // The first lines, then at 30 and 60, where the page tries a match (30 lines over a minute, 60 to
                // stand alone), then every hundred.
                let count = self.sentLines.count - skipped
                if reported == 0 || (reported < 30 && count >= 30) || (reported < 60 && count >= 60)
                    || count / 100 > reported / 100 {
                    reported = count
                    EngineLogBook.note(String(format: "[sync] %d lines of track %d sent to the page, from %.1f s to %.1f s (playing at %.1f s); %d longer than 12 s, %d left out at jumps",
                                              reported, index, lines.map(\.start).min() ?? 0, lines.map(\.end).max() ?? 0,
                                              playhead, long, skipped))
                }
                onLines(lines.sorted { $0.start < $1.start }.map { line -> Message in
                    ["startMs": line.start * 1000, "endMs": line.end * 1000]
                })
            }
    }

    /// The engine's open end for a line whose end hasn't come, an hour being past any authored one.
    private static let openEndedSeconds: Double = 3600
    /// The page's longest line; longer ones it takes for signs or songs and leaves out of the match.
    private static let longestLineSeconds: Double = 12
    /// A playhead move between two of the clock's ticks that only a seek makes.
    private static let lineJumpSeconds: Double = 3

    private func endLineWatch() {
        indexWatch?.cancel()
        indexWatch = nil
        lineWatch = nil
        sentLines = []
        guard watchedTrack != nil else { return }
        watchedTrack = nil
        engine.clearSecondarySubtitle()
    }

    private func reportTracks() {
        guard current != nil else { return }
        let tracks = engine.audioTracks.map { track($0, type: "audio") }
            + engine.subtitleTracks.map { track($0, type: "subtitle") }
        listener?.playerTracks(tracks)
    }

    private func track(_ track: TrackInfo, type: String) -> Message {
        var entry: Message = [
            "id": String(track.id),
            "type": type,
            "default": track.isDefault,
            "forced": track.isForced,
            "hearingImpaired": track.isHearingImpaired,
            "visualImpaired": track.isVisualImpaired,
            "external": track.isExternal,
        ]
        // An added file's title as the page named it: the page finds the file's text and its retimed copy by it.
        var title = track.isExternal ? track.name : track.name.trimmingCharacters(in: .whitespaces)
        // The page tells commentary from the title alone, so a file's commentary flag says so there, or the
        // page took the track for the main one and could pick it by default.
        if track.isCommentary, !title.localizedCaseInsensitiveContains("commentary") {
            title = title.isEmpty ? "Commentary" : "\(title) · Commentary"
        }
        if type == "audio" {
            // So the track list says which one carries Atmos, as the file's own names often don't.
            let profile = track.profile ?? ""
            let atmos = track.isAtmos || profile.localizedCaseInsensitiveContains("atmos")
            let dtsx = track.isDTSX || profile.localizedCaseInsensitiveContains("DTS:X")
            if atmos, !title.localizedCaseInsensitiveContains("atmos") {
                title = title.isEmpty ? "Dolby Atmos" : "\(title) · Dolby Atmos"
            } else if dtsx, !title.localizedCaseInsensitiveContains("DTS:X") {
                title = title.isEmpty ? "DTS:X" : "\(title) · DTS:X"
            }
        }
        if !title.isEmpty { entry["title"] = title }
        // No language rather than ISO 639's "none" codes, as the Android app leaves them out: the page takes two
        // "und" tracks for the same language, and one without a language for no language.
        if let language = track.language, !language.isEmpty,
           !Self.noLanguages.contains(language.lowercased()) { entry["language"] = language }
        if !track.codec.isEmpty { entry["codec"] = Self.pageCodec(track.codec) }
        if let url = addedSubtitles[track.id] { entry["url"] = url }
        return entry
    }

    /**
     * A codec as the page names it: FFmpeg's codec descriptor names, as the desktop and Android apps report
     * them. The engine's `TrackInfo.codec` is libavcodec's decoder name, the same for text subtitles but not
     * for picture ones, so the page took a PGS track (`pgssub`) for no subtitle it could match an added one
     * against, and its automatic subtitle sync never started on a Blu-ray remux.
     */
    static func pageCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "pgssub": return "hdmv_pgs_subtitle"
        case "dvdsub": return "dvd_subtitle"
        case "dvbsub": return "dvb_subtitle"
        // Audio the same way, as the Android app names them: DTS of every kind is "dts" there.
        case "dca": return "dts"
        case "mp3float": return "mp3"
        default: return codec
        }
    }

    /// A picture subtitle, by the engine's decoder name or FFmpeg's descriptor name.
    static func isPictureCodec(_ codec: String) -> Bool {
        ["pgssub", "dvdsub", "dvbsub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"].contains(codec.lowercased())
    }

    /// ISO 639 codes for no language: undetermined, no linguistic content, uncoded, multiple.
    private static let noLanguages: Set<String> = ["und", "zxx", "mis", "mul"]

    private func reportChapters() {
        guard current != nil else { return }
        let chapters: [Message] = engine.mediaChapters.map { chapter in
            var entry: Message = ["startMs": chapter.startSeconds * 1000]
            if !chapter.name.isEmpty { entry["title"] = chapter.name }
            return entry
        }
        listener?.playerChapters(chapters)
    }

    /// The audio track playing, if any.
    var activeAudio: TrackInfo? {
        engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
    }

    /// The receiver gets the Dolby bitstream itself: what the page shows as passthrough.
    var bitstreaming: Bool {
        engine.audioDelivery == .streamCopy && ["ac3", "eac3"].contains(activeAudio?.codec ?? "")
    }

    private func reportPassthrough() {
        guard current != nil, !ended else { return }
        listener?.playerState(["passthrough": bitstreaming])
    }

    // MARK: The picture

    /// Where the picture is drawn, in the video view's coordinates, which the overlay shares.
    private func videoRect() -> CGRect {
        let bounds = view.bounds
        if engine.videoRoute != .software, let layer = engine.nativePlayerLayer {
            let rect = layer.videoRect
            if rect.width > 0, rect.height > 0 { return rect }
        }
        var size = engine.softwareDisplaySize ?? .zero
        if size.width <= 0 || size.height <= 0 {
            size = CGSize(width: Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio,
                          height: Double(engine.sourceVideoHeight))
        }
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        switch engine.videoGravity {
        case .resize:
            return bounds
        case .resizeAspectFill:
            let scale = max(bounds.width / size.width, bounds.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        default:
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        }
    }

    // MARK: Picture in picture

    /// The background began with the picture-in-picture window showing, and it hasn't closed out there.
    private var heldByWindow = false

    /**
     * The window shows or has gone (`PictureInPicture`). The engine keeps the
     * session through the background while it shows, and AVPlayer draws the
     * text subtitles in it from the engine's native rendition.
     */
    func setPictureInPicture(_ on: Bool) {
        engine.pictureInPictureActive = on
        // Off at once; on only once the window shows (`showSubtitlesInWindow`), as picking the
        // rendition makes AVPlayer fetch it, which held up the window's start.
        if !on { engine.setNativeSubtitleRendering(false) }
        // Closed out in the background: the engine lets the video go, so it's opened again on the way back.
        if !on, UIApplication.shared.applicationState == .background { heldByWindow = false }
    }

    /// The window shows: AVPlayer draws the text subtitles in it from the engine's native rendition.
    func showSubtitlesInWindow() {
        guard engine.pictureInPictureActive else { return }
        engine.setNativeSubtitleRendering(true)
    }

    // MARK: Background

    /**
     * tvOS gives the decoder back when the app leaves the screen, so the
     * engine lets the video go then (it would otherwise wedge tvOS's media
     * server across a long suspension), and it's opened again here, paused
     * where it was, as the app paused it on leaving.
     */
    private func enteredBackground() {
        leftWithFile = current != nil && !ended
        heldByWindow = engine.pictureInPictureActive
    }

    private func becameActive() {
        guard leftWithFile else { return }
        leftWithFile = false
        // The picture-in-picture window kept the session running the whole time.
        if heldByWindow {
            heldByWindow = false
            return
        }
        guard current != nil, !ended else { return }
        let generation = generation
        Task { [weak self] in
            await withCheckedContinuation { done in AudioOutput.activate { done.resume() } }
            guard let self, generation == self.generation else { return }
            // The link has likely gone back to stereo while the app was away.
            if self.primes { AudioOutput.startPrimer() }
            do {
                // It keeps the options and the transport, so a paused video comes back paused.
                try await self.engine.reloadAtCurrentPosition()
                guard generation == self.generation else { return }
                if self.paused { self.engine.pause() } else { self.engine.play() }
                self.settleAudio(after: 3)
            } catch is CancellationError {
            } catch {
                guard generation == self.generation else { return }
                self.failed(error.localizedDescription)
            }
        }
    }

    // MARK: Statistics

    /**
     * The numbers the page's statistics show, in the shape the Android app's
     * ExoPlayer sends them: the page then writes the readout, Atmos
     * passthrough included. `cpuMs` and `atMs` give it the app's CPU use.
     */
    func stats() -> Message {
        // The page's readout names the engine from this, where it writes ExoPlayer otherwise (patches/web/0009).
        var stats: Message = ["engine": "AetherEngine \(Self.version)"]
        if let codec = engine.sourceVideoCodecName {
            stats["videoMime"] = Self.videoMimes[codec] ?? "video/\(codec)"
            stats["width"] = Int(engine.sourceVideoWidth)
            stats["height"] = Int(engine.sourceVideoHeight)
            if let fps = engine.sourceVideoFrameRate { stats["frameRate"] = fps }
            if engine.sourceVideoBitrate > 0 { stats["videoBitrate"] = engine.sourceVideoBitrate }
            switch engine.sourceVideoFormat {
            case .hdr10, .hdr10Plus, .dolbyVision:
                stats["colorTransfer"] = 6
                stats["colorSpace"] = 6
            case .hlg:
                stats["colorTransfer"] = 7
                stats["colorSpace"] = 6
            case .sdr:
                break
            }
            if let decoder = engine.activeVideoDecoder { stats["videoDecoder"] = decoder }
            var route = "\(Self.routeName(engine.videoRoute)), \(Self.formatName(engine.videoFormat))"
            if let profile = engine.sourceDVProfile { route = "Dolby Vision profile \(profile) as " + route }
            stats["dolbyVisionRoute"] = route
        }
        // What the TV can show, as Android lists its display's HDR types. tvOS reports no HDR10+ capability,
        // so HDR10+ is listed while it's the mode playing. Dolby Vision profiles are the Apple TV's decoder's:
        // every Apple TV 4K decodes profiles 5 and 8 itself, whatever the TV.
        let display = AetherEngine.displayCapabilities
        var hdrTypes: [Int] = []
        if display.supportsDolbyVision { hdrTypes.append(1) }
        if display.supportsHDR10 { hdrTypes.append(2) }
        if display.supportsHLG { hdrTypes.append(3) }
        if let playing = Self.hdrType(engine.videoFormat), !hdrTypes.contains(playing) { hdrTypes.append(playing) }
        stats["hdrTypes"] = hdrTypes.sorted()
        stats["dolbyVisionProfiles"] = [5, 8]
        if let audio = activeAudio {
            stats["audioMime"] = Self.audioMime(audio)
            stats["channels"] = audio.channels
            if audio.sampleRate > 0 { stats["sampleRate"] = audio.sampleRate }
            if audio.bitrate > 0 { stats["audioBitrate"] = audio.bitrate }
            let object = engine.liveTelemetry?.objectAudio
            var decoder = engine.activeAudioDecoder ?? Self.deliveryName(engine.audioDelivery)
            if let object {
                decoder += " · \(object.layout.rawValue) bed, \(object.activeObjects) of \(object.objects) objects"
                    + (object.heightChannels > 0 ? ", \(object.heightChannels) height channels" : "")
            }
            stats["audioDecoder"] = decoder
            if bitstreaming {
                stats["outputMime"] = Self.audioMime(audio)
                stats["outputChannels"] = audio.channels
            } else if let object {
                stats["outputMime"] = "audio/raw"
                stats["outputChannels"] = object.layout.speakers.count
            } else if engine.audioDelivery == .decoded || (engine.audioDelivery == .bridged && engine.loadedAudioIsLossless) {
                stats["outputMime"] = "audio/raw"
                // The channels sent: the track's, less any the page's channel setting folds away. The audio
                // session's channel counts say nothing about the sound over HDMI: 2 of 32 with Continuous Audio
                // Connection on or off, while a TrueHD 7.1 channel check plays every speaker.
                var sent = audio.channels
                if let limit = shaping.maxChannels { sent = min(sent, limit) }
                stats["outputChannels"] = max(1, sent)
            }
        }
        if let telemetry = engine.liveTelemetry {
            if let ahead = telemetry.forwardBufferSeconds { stats["bufferedMs"] = ahead * 1000 }
            if let dropped = telemetry.droppedFrameCount {
                stats["droppedFrames"] = dropped
                // AVPlayer counts the frames it drops, not those it shows: the shown are estimated from the
                // time played at the file's frame rate, less the dropped, for the page's Frames line.
                if let fps = engine.sourceVideoFrameRate, fps > 0, health.playedSeconds > 0 {
                    stats["renderedFrames"] = max(0, Int((health.playedSeconds * fps).rounded()) - dropped)
                }
            }
        }
        return ["type": "player-stats", "stats": stats, "cpuMs": Self.cpuMs, "atMs": Date().timeIntervalSince1970 * 1000]
    }

    /// The title the page shows for the video, from its Now Playing item, to name it in the last video's report.
    var title: String?

    /// The report of the last video, as it stood when it stopped, ended or failed, until the app quits.
    private(set) var lastVideo: [String]?

    private func keepLastVideo(ending: String) {
        guard let request = current else { return }
        let file = URL(string: request.url).map { $0.lastPathComponent.removingPercentEncoding ?? $0.lastPathComponent }
        let name = title ?? file ?? "?"
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let position = engine.clock.currentTime
        let at = position > 0 ? String(format: " at %d:%02d:%02d", Int(position) / 3600, Int(position) / 60 % 60, Int(position) % 60) : ""
        lastVideo = ["Last video: \(name), \(ending)\(at), \(time)"] + videoReport
    }

    /// What the app menu and the diagnostics say about the video and its sound.
    var report: [String] {
        guard current != nil, !ended else {
            var lines = ["Player: AetherEngine \(Self.version), nothing playing", "Audio output: \(AudioOutput.routeSummary)"]
            if let lastVideo { lines += [""] + lastVideo }
            return lines
        }
        return videoReport
    }

    /// The video's own lines, while it's loaded.
    private var videoReport: [String] {
        var lines = [
            "Player: AetherEngine \(Self.version), \(Self.routeName(engine.videoRoute))",
            "Video: \(engine.sourceVideoCodecName ?? "?") \(engine.sourceVideoWidth)×\(engine.sourceVideoHeight)"
                + (engine.sourceVideoFrameRate.map { String(format: " %.3f fps", $0) } ?? "")
                + ", \(Self.formatName(engine.sourceVideoFormat))"
                + (engine.sourceDVProfile.map { " (profile \($0))" } ?? "")
                + " → shown as \(Self.formatName(engine.videoFormat))",
            "Video decoder: \(engine.activeVideoDecoder ?? "none")",
        ]
        if let audio = activeAudio {
            lines.append("Audio track: \(audio.codec) \(audio.channels) ch"
                + (audio.profile.map { ", \($0)" } ?? "")
                + (audio.isAtmos ? ", Atmos (JOC) confirmed" : ""))
        } else {
            lines.append("Audio track: none")
        }
        lines.append("Audio delivery: \(Self.deliveryName(engine.audioDelivery)); \(engine.activeAudioDecoder ?? "no decoder")")
        if let object = engine.liveTelemetry?.objectAudio {
            lines.append("Object audio: \(object.layout.rawValue) bed, \(object.activeObjects) of \(object.objects) objects active, "
                + "\(object.elevatedObjects) overhead, \(object.heightChannels) height channels")
        }
        lines.append("Audio shaping: \(engine.audioShapingState.rawValue)")
        lines.append("Audio output: \(AudioOutput.routeSummary)")
        if !AudioOutput.primerEnabled {
            lines.append("Dolby primer: off (app menu)")
        } else if let prime = AudioOutput.lastPrime {
            lines.append("Dolby primer: \(prime)")
        }
        if !AudioOutput.routeIsHDMI { lines.append("Atmos needs the HDMI output; this route can't carry Dolby MAT") }
        var connection = "Source connection: " + (openedHeld ? "held (one connection)" : "ranged requests")
        if openedHeld != Self.heldSourceConnection { connection += "; the next video opens with the other" }
        lines.append(connection)
        if EngineLogBook.producerSlow(since: health.startedAt) {
            let objects = engine.liveTelemetry?.objectAudio != nil
            lines.append("Segment producer: below real time at its lower priority this video, so the engine keeps it at "
                + "the higher one (AE#850); a session this heavy may only just keep up, and the buffer grows slowly"
                + (objects ? ". Object audio is the likely weight: turning it off drops the object render, and the APAC "
                    + "encode where the engine uses one rather than PCM" : ""))
        }
        lines += health.lines
        return lines
    }

    private static let videoMimes = [
        "hevc": "video/hevc", "h264": "video/avc", "av1": "video/av01", "vp9": "video/x-vnd.on2.vp9",
        "vp8": "video/x-vnd.on2.vp8", "mpeg2video": "video/mpeg2", "vc1": "video/wvc1",
    ]

    /// The mode the TV shows the video in, as Android's display HDR types, which the page names.
    private static func hdrType(_ format: VideoFormat) -> Int? {
        switch format {
        case .dolbyVision: return 1
        case .hdr10: return 2
        case .hlg: return 3
        case .hdr10Plus: return 4
        case .sdr: return nil
        }
    }

    private static func audioMime(_ track: TrackInfo) -> String {
        let profile = track.profile ?? ""
        switch track.codec {
        case "eac3": return track.isAtmos ? "audio/eac3-joc" : "audio/eac3"
        case "ac3": return "audio/ac3"
        case "truehd", "mlp": return "audio/true-hd"
        // The engine names DTS by libavcodec's decoder, "dca" ("dca 2 ch, DTS-HD MA" in the app menu).
        case "dts", "dca":
            if track.isDTSX || profile.contains("DTS:X") { return "audio/vnd.dts.uhd;profile=p2" }
            return profile.contains("HD") ? "audio/vnd.dts.hd" : "audio/vnd.dts"
        case "aac": return "audio/mp4a-latm"
        case "flac": return "audio/flac"
        case "opus": return "audio/opus"
        case "ac4": return "audio/ac4"
        default: return track.codec.hasPrefix("pcm") ? "audio/raw" : "audio/\(track.codec)"
        }
    }

    static func routeName(_ route: VideoRoute) -> String {
        switch route {
        case .remoteBypass: return "AVPlayer on the stream's own HLS"
        case .loopback: return "AVPlayer (FFmpeg remux)"
        case .software: return "software decode"
        case .audio: return "audio only"
        case .none: return "no route"
        }
    }

    static func formatName(_ format: VideoFormat) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    static func deliveryName(_ delivery: AudioDelivery) -> String {
        switch delivery {
        case .streamCopy: return "bitstream, copied untouched"
        case .bridged: return "re-encoded by the audio bridge"
        case .decoded: return "decoded to PCM"
        case .playerManaged: return "AVPlayer's own"
        case .noAudioInSource: return "the file has no sound"
        case .droppedNoPipeline: return "dropped: no way to play this track"
        case .none: return "none"
        }
    }

    /// The app's CPU time, user and system.
    private static var cpuMs: Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func ms(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }
}

private extension AetherEngine {
    /// The audio bridge delivers FLAC or 24-bit PCM ("→ FLAC bridge", "→ PCM bridge"), which reach the
    /// receiver as PCM.
    var loadedAudioIsLossless: Bool {
        guard let pipeline = activeAudioDecoder else { return false }
        return pipeline.localizedCaseInsensitiveContains("flac") || pipeline.localizedCaseInsensitiveContains("PCM bridge")
    }
}
