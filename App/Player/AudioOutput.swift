import AetherHost
import AVFoundation
import Foundation

/**
 * The audio session, set up for Dolby Atmos over HDMI.
 *
 * The category is declared at launch but the session is only activated when
 * a video starts, as AVKit does. Activating it at launch pins the HDMI route
 * to what the link reported then, and with Continuous Audio Connection off
 * that is 2 channels: multichannel PCM (lossless TrueHD and DTS-HD, rendered
 * Atmos beds) then plays downmixed (AetherEngine#24). The engine leaves
 * activation to the host on its native AVPlayer path, which has no
 * AVPlayerViewController here, so the app does it.
 */
enum AudioOutput {
    /// What the engine declares on tvOS: movie playback, long-form audio, multichannel.
    static func declare() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try session.setSupportsMultichannelContent(true)
        } catch {
            NSLog("[audio] category: %@", error.localizedDescription)
        }
        watchRoute()
    }

    private static var watchingRoute = false

    /// A route change is where an HDMI link that came up at 2 channels gets its full width.
    private static func watchRoute() {
        guard !watchingRoute else { return }
        watchingRoute = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { _ in widen() }
    }

    private static let queue = DispatchQueue(label: "audio-session", qos: .userInitiated)

    /**
     * Activates the session off the main thread, as it can block, and asks
     * for every channel the route takes. Calls back on the main thread.
     */
    static func activate(_ done: @escaping () -> Void) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                if session.category != .playback { declare() }
                try session.setActive(true)
            } catch {
                NSLog("[audio] activate: %@", error.localizedDescription)
            }
            widenNow()
            NSLog("[audio] active: %@", routeSummary)
            DispatchQueue.main.async(execute: done)
        }
    }

    /**
     * The video has started playing. With Continuous Audio Connection off the
     * HDMI link idles at 2 channels and only widens once multichannel sound
     * plays, which is after activation and usually after the file has opened;
     * asked again then, multichannel PCM (TrueHD, DTS-HD) plays in full.
     */
    static func playbackStarted() {
        widen()
        for delay in [1.0, 3.0, 6.0] {
            queue.asyncAfter(deadline: .now() + delay) { widenNow() }
        }
        queue.asyncAfter(deadline: .now() + 6.5) { NSLog("[audio] playing: %@", routeSummary) }
    }

    private static func widen() {
        queue.async { widenNow() }
    }

    /// The channels the session's output has now: 2 while the HDMI link idles at stereo.
    static var channelsInUse: Int { AVAudioSession.sharedInstance().outputNumberOfChannels }

    /// The most channels the route takes, which is more than 2 on a multichannel link even while it idles.
    static var channelsAvailable: Int { AVAudioSession.sharedInstance().maximumOutputNumberOfChannels }

    // MARK: Dolby primer

    private static var primer: AVQueuePlayer?
    private static var primerLooper: AVPlayerLooper?
    private static var primerWatch: NSKeyValueObservation?
    /// Bumped by each start and stop, so a stop scheduled for an earlier video doesn't end a later one's.
    private static var primerTurn = 0
    private static var primerBefore = ""
    private static var primerPlayed = false
    /// What the primer last did, for the app menu and the diagnostics. Main thread only.
    static private(set) var lastPrime: String?

    /// The primer is playing (or starting), so a video can wait on the link it widens.
    static var primerPlaying: Bool { primer != nil }

    /// The most the primer plays if the video never shows a frame (a failed or very slow load).
    private static let primerLongest: TimeInterval = 30

    /**
     * The app menu's switch for the primer and the pause and play after it (`AetherPlayer.settleAudio`),
     * off by default. They're for a link that idles at stereo and stays there for decoded multichannel
     * sound (Continuous Audio Connection off, seen with Samsung and Sonos soundbars); elsewhere they
     * only cost a pause a few seconds in. Read as each video loads.
     */
    static var primerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "audio.dolbyPrimer") }
        set { UserDefaults.standard.set(newValue, forKey: "audio.dolbyPrimer") }
    }

    /**
     * With Continuous Audio Connection off, the HDMI link idles at stereo PCM, and sound the
     * Apple TV decodes (TrueHD, DTS-HD, anything shaped) plays downmixed into it, whichever
     * player plays it: asking the session for more channels doesn't widen it. A Dolby bitstream
     * does, and the link stays wide for the PCM that follows. Measured on an Apple TV 4K into a
     * Samsung TV and HW-Q990F on eARC: Infuse played TrueHD as stereo PCM, then as multichannel
     * PCM after a switch to the E-AC-3 track and back, and this app's TrueHD did too from then on.
     * Infuse users with Samsung soundbars report the same workaround.
     *
     * In Infuse the E-AC-3 was still playing when the TrueHD took over. A second of it played
     * before the video loaded didn't widen the link: the load's few seconds of silence let it
     * fall back to stereo. So silent Dolby Digital Plus Atmos plays from the start of every load
     * until the video's own sound has started (`stopPrimer`), and the two overlap. The stream is
     * AetherEngine's (`silent-atmos.mp4`, written bit by bit by its
     * `Scripts/make-silent-atmos.swift`) and decodes to digital silence. Main thread.
     *
     * The overlap widens the link (the soundbar shows Dolby, then PCM), but the video's player set
     * its output up at stereo before that, and keeps it: the soundbar stays at stereo PCM until a
     * pause and play, which sets the output up again on the wide link. So the player stops the
     * primer while the video plays, then pauses and plays the video (`AetherPlayer.settleAudio`).
     */
    static func startPrimer() {
        guard primerEnabled, routeIsHDMI,
              let url = Bundle.main.url(forResource: "silent-atmos", withExtension: "mp4") else { return }
        primerTurn += 1
        let turn = primerTurn
        // The next video while the last one's primer still plays: it keeps playing, for this one.
        if primer == nil {
            primerBefore = routeSummary
            primerPlayed = false
            primerNotes = []
            let player = AVQueuePlayer()
            player.automaticallyWaitsToMinimizeStalling = false
            primer = player
            primerLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            primerWatch = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
                guard player.timeControlStatus == .playing else { return }
                DispatchQueue.main.async { primerPlayed = true }
            }
            player.play()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + primerLongest) {
            if turn == primerTurn { finishPrimer("the video showed no picture in \(Int(primerLongest)) s") }
        }
    }

    /// The video's sound has started (or the video is gone): the primer stops `after` seconds,
    /// so the decoded sound takes over the link while the Dolby still holds it.
    static func stopPrimer(after: TimeInterval) {
        guard primer != nil else { return }
        primerTurn += 1
        let turn = primerTurn
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            if turn == primerTurn { finishPrimer(nil) }
        }
    }

    /// What happened while the primer played, for its line in the app menu once it stops.
    private static var primerNotes: [String] = []

    /// Adds to the primer's line in the app menu: kept until it stops if it still plays.
    static func notePrimer(_ note: String) {
        if primer != nil {
            primerNotes.append(note)
        } else {
            lastPrime = (lastPrime ?? "") + "; " + note
        }
    }

    private static func finishPrimer(_ why: String?) {
        guard let player = primer else { return }
        let error = player.error ?? player.currentItem?.error
        primerWatch?.invalidate()
        primerWatch = nil
        player.pause()
        primerLooper?.disableLooping()
        primerLooper = nil
        player.removeAllItems()
        primer = nil
        var outcome = primerPlayed ? "played" : "never played"
        if let error { outcome += " (\(error.localizedDescription))" }
        if let why { outcome += ", \(why)" }
        for note in primerNotes { outcome += ", \(note)" }
        primerNotes = []
        outcome += "; before: \(primerBefore); after: \(routeSummary)"
        lastPrime = outcome
        NSLog("[audio] Dolby primer: %@", outcome)
    }

    /**
     * Asks for every channel the route takes, if it now takes more than the
     * session has. Never asks for 2 or fewer: a preference of 2, written while
     * the link idles at stereo, holds the route at stereo once the link could
     * take more, which is what downmixed TrueHD with the setting off.
     */
    private static func widenNow() {
        let session = AVAudioSession.sharedInstance()
        let most = session.maximumOutputNumberOfChannels
        // Written only when it changes, so the route change a write causes ends here.
        guard most > 2, session.preferredOutputNumberOfChannels != most else { return }
        do {
            try session.setPreferredOutputNumberOfChannels(most)
            NSLog("[audio] widened: %@", routeSummary)
        } catch {
            NSLog("[audio] widen: %@", error.localizedDescription)
        }
    }

    /// Where the sound goes and how many channels it takes, for the diagnostics.
    static var routeSummary: String {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map { port in
            "\(port.portName) (\(portName(port.portType)), \(port.channels?.count ?? 0) ch)"
        }
        return (ports.isEmpty ? "no output" : ports.joined(separator: ", "))
            + "; \(session.outputNumberOfChannels) of \(session.maximumOutputNumberOfChannels) channels in use"
            + ", \(session.preferredOutputNumberOfChannels) asked"
    }

    /// Every output is HDMI: the only route that carries Dolby MAT, so Atmos, from an Apple TV.
    static var routeIsHDMI: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return !outputs.isEmpty && outputs.allSatisfy { $0.portType == .HDMI }
    }

    private static func portName(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .HDMI: return "HDMI"
        case .airPlay: return "AirPlay"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "Bluetooth"
        default: return type.rawValue
        }
    }
}

/**
 * AetherEngine's log, into the app's log, with its recent audio lines kept
 * for the app menu and the diagnostics: whether Atmos went out as a stream
 * copy, or why not, is only in them.
 */
enum EngineLogBook {
    private static let lock = NSLock()
    private static var audio: [String] = []
    private static let kept = 20
    private static let audioWords = ["atmos", "eac3", "e-ac-3", "joc", "truehd", "dts", "audio", "mat ", "apac", "bridge", "spatial"]
    /// The lines that say which way a video went and why it failed: the probe, the HLS reroutes
    /// (AE#154 and AE#246 to AVPlayer, AE#363 and AE#678 to the engine's live reader) and AVPlayer giving up.
    /// Also an added subtitle that failed: the engine's sidecar fetch and decode (AE#984's whole-body GET
    /// since engine 7.59) says why only here, and the app's own `[subtitles]` lines say what was added.
    private static let loadWords = ["probe failed", "ae#154", "ae#246", "ae#363", "ae#678", "failedtoplaytoend",
                                    "hls playlist body", "[player]", "[subtitles]", "sidecar decode failed", "ae#984",
                                    Self.producerSlowWords]
    /// The engine's AE#850 line only: "pump qos: utility produced at 0.42x real time, below 1.00x, staying
    /// userInitiated for this session". Its everyday `pump qos -> utility` and `-> userInitiated` lines are
    /// the producer relaxing once it's far ahead, a sign it keeps up, and must not count.
    private static let producerSlowWords = "staying userinitiated for this session"
    /// When the engine last said its segment producer ran below real time at its lower priority
    /// (`producerSlowWords`, AE#850): a session too heavy for the Apple TV, such as a 4K
    /// remux with its Atmos objects rendered, which the stall verdict names.
    private static var producerSlowAt: Date?

    /// The producer ran below real time since `date`.
    static func producerSlow(since date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return producerSlowAt.map { $0 >= date } ?? false
    }

    /**
     * The engine's subtitle reader and drain, kept apart from the audio and loading lines, which the
     * memprobe and the spatial bridge's bed levels fill every 30 s: a pick that showed nothing for
     * minutes said only what the app saw, not why. Its forward reader (`#151 forward prefetch`
     * started, re-anchored, holding, yielded, failed), each drain outcome (`#357 subtitle-delivery`:
     * packets found, cues, held), how far the track is read (`#250 subtitle-resolution`), and the pick.
     */
    private static let subtitleWords = ["#151 forward prefetch", "#357 subtitle-delivery", "#250 subtitle-resolution",
                                        "packet-store drainer", "subtitle drain", "#416", "#100 ", "[subtitles]"]
    private static var subtitles: [String] = []
    private static let keptSubtitles = 30

    /**
     * The upscaling stage's lines, kept apart for the same reason: the route it took or why not (`[Upscale]
     * taken:` / `not taken (...)`), its timing per stage against the frame budget, and a dropped MetalFX or a
     * disable. They said nothing in the audio and loading lines, which the memprobe fills every 30 s.
     */
    private static let upscaleWords = ["[upscale]", "[player] upscaling"]
    private static var upscaling: [String] = []
    private static let keptUpscaling = 40

    /// Every 30 s, so they'd fill the audio lines on their own; they say nothing a stall needs.
    private static let noiseWords = ["bed levels"]

    /// The engine calls the handler from its own threads, so this keeps no main-thread state.
    static func install() {
        EngineLog.handler = { line in
            NSLog("[aether] %@", line)
            let lower = line.lowercased()
            if lower.contains(producerSlowWords) {
                lock.lock()
                producerSlowAt = Date()
                lock.unlock()
            }
            if upscaleWords.contains(where: { lower.contains($0) }) { keepUpscaling(line) }
            if subtitleWords.contains(where: { lower.contains($0) }) {
                keepSubtitle(line)
            } else if lower.contains("memprobe"), let tail = line.range(of: "subCues=") {
                // The subtitle half of the memprobe (cues, the video reader's window and the forward
                // reader's, `pref…` and `prefetch=`), which the 400 characters kept below cut off.
                keepSubtitle("[AetherEngine] memprobe " + line[tail.lowerBound...])
            }
            guard !noiseWords.contains(where: { lower.contains($0) }),
                  audioWords.contains(where: { lower.contains($0) })
                    || loadWords.contains(where: { lower.contains($0) }) else { return }
            keep(line)
        }
    }

    /// The app's own line, beside the engine's, for the app menu; its subtitle lines with the engine's.
    static func note(_ line: String) {
        NSLog("%@", line)
        if line.hasPrefix("[player] upscaling") { keepUpscaling(line) }
        if line.hasPrefix("[subtitles]") { keepSubtitle(line) } else { keep(line) }
    }

    /**
     * What the Siri Remote's arrows did: each press, whether it was sent, held back or dropped (and why), the
     * swipes' steps, and what the page did with Up. An ignored Up said nothing anywhere before. Stamped with
     * the uptime in ms, as the order and the gaps are the question. Not sent to NSLog: a swipe makes many.
     */
    private static var remoteLines: [String] = []
    private static let keptRemote = 60

    static func remote(_ line: String) {
        let ms = Int((ProcessInfo.processInfo.systemUptime * 1000).truncatingRemainder(dividingBy: 1_000_000))
        lock.lock()
        remoteLines.append("\(ms) \(line.prefix(300))")
        if remoteLines.count > keptRemote { remoteLines.removeFirst(remoteLines.count - keptRemote) }
        lock.unlock()
    }

    static var recentRemote: [String] {
        lock.lock()
        defer { lock.unlock() }
        return remoteLines
    }

    private static func keepUpscaling(_ line: String) {
        lock.lock()
        upscaling.append(String(line.prefix(500)))
        if upscaling.count > keptUpscaling { upscaling.removeFirst(upscaling.count - keptUpscaling) }
        lock.unlock()
    }

    static var recentUpscaling: [String] {
        lock.lock()
        defer { lock.unlock() }
        return upscaling
    }

    private static func keepSubtitle(_ line: String) {
        lock.lock()
        subtitles.append(String(line.prefix(500)))
        if subtitles.count > keptSubtitles { subtitles.removeFirst(subtitles.count - keptSubtitles) }
        lock.unlock()
    }

    static var recentSubtitles: [String] {
        lock.lock()
        defer { lock.unlock() }
        return subtitles
    }

    /// Stalls across videos, apart from the audio and loading lines so those can't push them out.
    private static var stalls: [String] = []
    private static let keptStalls = 10

    /// A stall's line, with the video it was in, kept until the app quits.
    static func noteStall(_ line: String) {
        NSLog("[player] stall: %@", line)
        lock.lock()
        stalls.append(String(line.prefix(600)))
        if stalls.count > keptStalls { stalls.removeFirst(stalls.count - keptStalls) }
        lock.unlock()
    }

    static var recentStalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stalls
    }

    private static func keep(_ line: String) {
        lock.lock()
        audio.append(String(line.prefix(400)))
        if audio.count > kept { audio.removeFirst(audio.count - kept) }
        lock.unlock()
    }

    static var recentAudio: [String] {
        lock.lock()
        defer { lock.unlock() }
        return audio
    }
}
