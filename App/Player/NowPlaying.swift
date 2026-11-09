import AetherHost
import Combine
import MediaPlayer
import UIKit

/**
 * What plays, for the TV's Now Playing screen and Control Center, and the
 * commands they send, which reach the page as `media-key` messages. The page
 * drops a command that repeats a remote press it just handled.
 *
 * AetherEngine owns the Now Playing session bound to its AVPlayer, which
 * publishes the position, rate and length itself; the app gives it the title
 * and artwork and handles the commands on that session. Writing the shared
 * Now Playing info by hand races the engine's player on tvOS 26. On the
 * engine's software route, which has no AVPlayer, the engine answers the
 * transport commands itself and the app adds next and previous.
 */
@MainActor
final class NowPlaying {
    private let send: (Message) -> Void
    private let engine: AetherEngine
    private var item: Message?
    private var artwork: (url: String, image: MPMediaItemArtwork?)?
    /// The session the commands are on, so a new player gets them once.
    private weak var session: MPNowPlayingSession?
    private var sharedCommands = false
    private var watching = Set<AnyCancellable>()
    /// A seek or skip came from the system, such as Siri's "go to 30 minutes", after it went to the page.
    var onSeek: () -> Void = {}

    init(engine: AetherEngine, send: @escaping (Message) -> Void) {
        self.engine = engine
        self.send = send
        // A new AVPlayer, after a load or a reload, may come with a new session.
        engine.$currentAVPlayer
            .sink { [weak self] _ in DispatchQueue.main.async { self?.attach() } }
            .store(in: &watching)
        engine.$softwareNowPlayingActive
            .removeDuplicates()
            .sink { [weak self] active in self?.setSharedCommands(active) }
            .store(in: &watching)
    }

    func setItem(_ item: Message?) {
        self.item = item
        guard let item, item.text("title") != nil else {
            artwork = nil
            engine.setVideoNowPlayingInfo([:])
            return
        }
        if let url = item.text("artwork") { loadArtwork(url) } else { artwork = nil }
        publish()
        attach()
        updateTrackCommands()
    }

    /// The title and artwork; the engine adds the position, rate and length.
    private func publish() {
        guard let item, let title = item.text("title") else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let subtitle = item.text("subtitle") { info[MPMediaItemPropertyArtist] = subtitle }
        if let image = artwork?.image { info[MPMediaItemPropertyArtwork] = image }
        engine.setVideoNowPlayingInfo(info)
    }

    private func loadArtwork(_ url: String) {
        guard artwork?.url != url, let address = URL(string: url) else { return }
        artwork = (url, nil)
        URLSession.shared.dataTask(with: address) { [weak self] data, _, _ in
            // Decoded here, off the main thread, as the system reads it from its own.
            guard let data, let image = UIImage(data: data)?.preparingForDisplay() else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                guard let self, self.artwork?.url == url else { return }
                self.artwork = (url, art)
                self.publish()
            }
        }.resume()
    }

    /// The system calls command handlers on the main thread.
    private func handle(
        _ command: MPRemoteCommand,
        seeks: Bool = false,
        _ key: @escaping @MainActor (MPRemoteCommandEvent) -> Message?
    ) {
        command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let key = key(event) else { return .commandFailed }
                self.send(["type": "media-key", "key": key])
                if seeks { self.onSeek() }
                return .success
            }
        }
    }

    /// The commands on the engine's session, once per session.
    private func attach() {
        guard item != nil, let session = engine.videoNowPlayingSession, session !== self.session else { return }
        self.session = session
        let center = session.remoteCommandCenter
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand,
                        center.changePlaybackPositionCommand, center.skipForwardCommand, center.skipBackwardCommand] {
            command.isEnabled = true
        }
        handle(center.playCommand) { _ in ["action": "play"] }
        handle(center.pauseCommand) { _ in ["action": "pause"] }
        handle(center.togglePlayPauseCommand) { _ in ["action": "toggle"] }
        handle(center.stopCommand) { _ in ["action": "stop"] }
        handle(center.changePlaybackPositionCommand, seeks: true) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return nil }
            return ["action": "seek", "position": event.positionTime * 1000]
        }
        handle(center.skipForwardCommand, seeks: true) { ["action": "skip", "offset": Self.skipMs($0)] }
        handle(center.skipBackwardCommand, seeks: true) { ["action": "skip", "offset": -Self.skipMs($0)] }
        handle(center.nextTrackCommand) { _ in ["action": "next"] }
        handle(center.previousTrackCommand) { _ in ["action": "previous"] }
        updateTrackCommands()
    }

    /// The skip's length in ms: the interval asked for, such as Siri's "skip ahead 2 minutes", or 10 s.
    private static func skipMs(_ event: MPRemoteCommandEvent) -> Double {
        guard let interval = (event as? MPSkipIntervalCommandEvent)?.interval,
              interval.isFinite, interval > 0 else { return 10_000 }
        return interval * 1000
    }

    /// Next and previous, where the page has them for the item.
    private func updateTrackCommands() {
        let next = item?.flag("next") == true
        let previous = item?.flag("previous") == true
        if let center = session?.remoteCommandCenter {
            center.nextTrackCommand.isEnabled = next
            center.previousTrackCommand.isEnabled = previous
        }
        if sharedCommands {
            let shared = MPRemoteCommandCenter.shared()
            shared.nextTrackCommand.isEnabled = next
            shared.previousTrackCommand.isEnabled = previous
        }
    }

    /// While the engine publishes Now Playing for its software route, on the shared centre it uses.
    private func setSharedCommands(_ on: Bool) {
        guard on != sharedCommands else { return }
        sharedCommands = on
        let shared = MPRemoteCommandCenter.shared()
        shared.nextTrackCommand.removeTarget(nil)
        shared.previousTrackCommand.removeTarget(nil)
        guard on else {
            shared.nextTrackCommand.isEnabled = false
            shared.previousTrackCommand.isEnabled = false
            return
        }
        handle(shared.nextTrackCommand) { _ in ["action": "next"] }
        handle(shared.previousTrackCommand) { _ in ["action": "previous"] }
        updateTrackCommands()
    }
}
