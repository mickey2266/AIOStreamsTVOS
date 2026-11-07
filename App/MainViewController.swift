import AetherHost
import UIKit

/**
 * AetherEngine's video beneath, its subtitles over it, the web app over both,
 * and the bridge between them. The web side follows the working
 * aiostreams-tvos project: a WKWebView loaded at runtime, given the whole
 * screen, focused so the page's focus ring shows, and the remote taken at the
 * window and handed to the page as keys.
 */
final class MainViewController: UIViewController, RemoteReceiver {
    private let videoView = AetherPlayerView(frame: .zero)
    private let subtitleView = SubtitleOverlay(frame: .zero)
    private var web: AIOWebView?
    private let status = UILabel()
    private var engine: AetherPlayer?
    private var player: PlayerChannel?
    private var pip: PictureInPicture?
    private let input = RemoteInput()
    private let storage = WebStorage()
    /// The page has said hello, so it takes Back.
    private var connected = false
    /// `aiostreams://` links, held until the page listens for them.
    private var links: [String] = []
    private var linksReady = false
    /// A held key's repeat the page hasn't finished with.
    private var repeatInFlight = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AppFolders.create()

        for pane in [videoView, subtitleView] as [UIView] {
            pane.frame = view.bounds
            pane.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pane.isHidden = true
            pane.isUserInteractionEnabled = false
            view.addSubview(pane)
        }
        videoView.backgroundColor = .black

        status.frame = view.bounds.insetBy(dx: 160, dy: 160)
        status.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        status.textColor = UIColor(white: 0.85, alpha: 1)
        status.font = .systemFont(ofSize: 36, weight: .medium)
        status.textAlignment = .center
        status.numberOfLines = 0

        guard let root = WebApp.root else {
            view.addSubview(status)
            return showStatus("The web app is missing from this build. Run scripts/fetch-web.sh, then build again.")
        }
        let web = AIOWebView(frame: view.bounds, scheme: WebApp.scheme, root: root)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        view.addSubview(status)
        self.web = web
        guard web.available else {
            return showStatus("This version of tvOS has no web engine the app can use.")
        }
        web.userAgent = Identity.userAgent
        web.onMessage = { [weak self] in self?.receive($0) }
        web.onLoadFinished = { [weak self] in
            self?.status.isHidden = true
            self?.web?.focusPage()
        }
        web.onLoadFailed = { [weak self] error in
            self?.connected = false
            self?.showStatus("The page couldn't load.\n\(error)\n\nHold Play/Pause for options.")
        }
        web.onProcessEnded = { [weak self] url, reason in
            self?.pageEnded(at: url, reason: reason)
        }
        web.onResponsiveness = { [weak self] responsive in
            MemoryLog.pageResponsive(responsive, playing: self?.player?.playing == true)
        }
        MemoryLog.webMB = { [weak web] in
            guard let mb = web?.webProcessMB, mb >= 0 else { return nil }
            return mb
        }
        MemoryLog.gpuMB = { [weak web] in
            guard let mb = web?.gpuProcessMB, mb >= 0 else { return nil }
            return mb
        }
        MemoryLog.startSampling()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue.
            MainActor.assumeIsolated {
                MemoryLog.warning(playing: self?.player?.playing == true)
                // tvOS is short of memory, and the page's process is the most likely to be ended: its
                // artwork near the screen only, until it's scrolled back to.
                self?.callTV("trim()")
            }
        }
        web.onOpenURL = { [weak self] in self?.open($0) }
        web.onServed = { path, status, _ in
            if status != 200 { NSLog("[web] %ld for %@", status, path) }
        }
        web.thumbnailAtPath = { ThumbnailStore.image($0) }

        startPlayer()
        setUpInput()
        loadPage()
    }

    /**
     * Cancels tvOS's safe area for the whole screen: the page lays out edge to
     * edge and keeps its own margins, as on Android TV.
     */
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let safe = view.safeAreaInsets
        let added = additionalSafeAreaInsets
        let cancel = UIEdgeInsets(
            top: -(safe.top - added.top), left: -(safe.left - added.left),
            bottom: -(safe.bottom - added.bottom), right: -(safe.right - added.right)
        )
        if added != cancel { additionalSafeAreaInsets = cancel }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        web?.focusPage()
    }

    // MARK: Page

    /**
     * The bridge script carries the app's copy of the page's storage, so it's made fresh for each load,
     * a reload after the page's process ended included. `url` is where the page was, if it's one of the app's.
     */
    private func loadPage(at url: URL? = nil) {
        guard let web else { return }
        connected = false
        linksReady = false
        showStatus("Loading AIOStreams…")
        web.setStartScript(BridgeScript.make(
            version: "\(Identity.version)-tvos",
            device: Identity.device,
            deviceId: Identity.deviceId,
            storage: storage.json,
            pageScrolls: BridgeScript.pageScrolls
        ))
        let ours = url.flatMap { $0.scheme?.lowercased() == WebApp.scheme ? $0 : nil }
        // `loadURL:` in Objective-C; Swift names it `load(_:)`.
        web.load(ours ?? WebApp.startURL)
    }

    /// When the page's process last ended, newest last, to tell a page that ends again as it loads.
    private var pageEnds: [Date] = []
    /// An end this soon after the last one counts as the page failing as it loads.
    private static let quickEnd: TimeInterval = 30

    /**
     * The page's process ended. It loads again where it was; ended again within `quickEnd`, it
     * loads at the start, as the page it was on may be what takes it to its limit as it loads (a
     * Jetsam report showed 13 ends in 26 s). A third quick end in a row stops reloading, and the
     * app menu's Reload starts it again.
     */
    private func pageEnded(at url: URL?, reason: AIOPageEnd) {
        let now = Date()
        pageEnds = pageEnds.filter { now.timeIntervalSince($0) < 10 * Self.quickEnd } + [now]
        var quick = 0
        for (earlier, later) in zip(pageEnds.dropLast(), pageEnds.dropFirst()).reversed() {
            guard later.timeIntervalSince(earlier) < Self.quickEnd else { break }
            quick += 1
        }
        let place = url.map { u in
            u.path + (u.query.map { "?\($0)" } ?? "") + (u.fragment.map { "#\($0)" } ?? "")
        }
        MemoryLog.pageEnded(playing: player?.playing == true, reason: reason, at: place)
        let cause = reason.rawValue == 0 ? "ran out of memory" : "stopped (\(MemoryLog.cause(reason)))"
        switch quick {
        case 0:
            loadPage(at: url)
            flashStatus("The page \(cause) and reloaded.")
        case 1:
            loadPage()
            flashStatus("The page \(cause) again as it loaded, so it started over at home.")
        default:
            pageEnds = []
            showStatus("The page \(cause) again as it loaded, even at home, so it wasn't reloaded.\n\n"
                + "Hold Play/Pause for options, then Reload.")
        }
    }

    private func showStatus(_ text: String) {
        status.text = text
        status.isHidden = false
    }

    /// A notice that clears itself.
    private func flashStatus(_ text: String) {
        showStatus(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.status.text == text { self?.status.isHidden = true }
        }
    }

    private func sendToPage(_ message: Message) {
        guard let json = JSON.string(message) else { return }
        web?.evaluateJavaScript("window.__aioReceive&&window.__aioReceive(\(json))")
    }

    /// What the page was last told about the player's picture-in-picture button.
    private var pipButtonShown = false

    /// Shown while a video plays on the engine's AVPlayer and the page's Picture-in-picture setting is on.
    private func updatePipButton() {
        let offered = pip?.offered == true
        guard offered != pipButtonShown else { return }
        pipButtonShown = offered
        callTV("pip(\(offered))")
    }

    private func callTV(_ call: String) {
        web?.evaluateJavaScript("window.__aioTV&&window.__aioTV.\(call)")
    }

    private func jsString(_ text: String) -> String {
        JSON.string([text]).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    // MARK: Player

    private func startPlayer() {
        do {
            let engine = try AetherPlayer(view: videoView, subtitles: subtitleView)
            self.engine = engine
            // Match Content's HDR10, HLG, Dolby Vision and frame rate are the engine's own to ask tvOS for.
            let player = PlayerChannel(
                player: engine,
                subtitlesDir: AppFolders.subtitles,
                send: { [weak self] message in self?.sendToPage(message) },
                showVideo: { [weak self] shown in
                    self?.videoView.isHidden = !shown
                    self?.subtitleView.isHidden = !shown
                }
            )
            self.player = player
            let pip = PictureInPicture(player: engine, channel: player, send: { [weak self] in self?.sendToPage($0) })
            pip.failed = { [weak self] in self?.flashStatus($0) }
            pip.window = { [weak self] in self?.view.window }
            pip.ended = { [weak self] in
                self?.web?.focusPage()
                self?.updatePipButton()
            }
            player.onStopped = { [weak pip] in pip?.stop() }
            // The engine's AVPlayer layer is there once a video has loaded.
            player.onPlayerEvent = { [weak self] in self?.updatePipButton() }
            self.pip = pip
        } catch {
            NSLog("[app] AetherEngine did not start: %@", String(describing: error))
        }
    }

    // MARK: Remote

    var takesRemote: Bool { presentedViewController == nil && web?.available == true }

    func remotePress(_ press: UIPress) {
        input.press(press)
    }

    func remoteTouches(_ touches: Set<UITouch>) {
        input.touches(touches)
    }

    func ownsPress(_ press: UIPress) -> Bool {
        input.owns(press)
    }

    /// Anything the app opens over the page (the search keyboard, the app menu, alerts) takes the
    /// remote from it: a held arrow stops repeating into the page underneath first.
    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool,
                          completion: (() -> Void)? = nil) {
        input.interrupt()
        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    private func setUpInput() {
        input.keyDown = { [weak self] key, repeated in
            guard let self else { return }
            let call = "window.__aioTV&&window.__aioTV.down(\(self.jsString(key)),\(repeated))"
            guard repeated else {
                self.web?.evaluateJavaScript(call)
                return
            }
            // A held key repeats at the page's pace: while the page is still on the last repeat (laying out
            // a new row, say), the next is dropped rather than queued, so focus doesn't run on in a burst.
            guard !self.repeatInFlight, let web = self.web else { return }
            self.repeatInFlight = true
            web.evaluateJavaScript(call) { [weak self] in self?.repeatInFlight = false }
        }
        input.keyUp = { [weak self] key in
            guard let self else { return }
            self.callTV("up(\(self.jsString(key)))")
        }
        input.back = { [weak self] in
            guard let self else { return }
            if self.connected { self.sendToPage(["type": "back"]) } else { self.leaveApp() }
        }
        input.menu = { [weak self] in self?.showAppMenu() }
    }

    private func leaveApp() {
        player?.change(Change(paused: true))
        suspendApp()
    }

    // MARK: The app's own screens

    /// With how the video and its sound play, to see why HDR or Atmos doesn't reach the TV.
    private func showAppMenu() {
        guard presentedViewController == nil else { return }
        // In steps: as one expression, the compiler gives up type-checking it.
        var lines: [String] = ["App \(Identity.version) · web app \(WebApp.commit) · \(storage.keyCount) saved keys", ""]
        // First, so the swipes just made are on screen as the menu opens.
        lines += input.report
        lines.append("")
        lines += AppAnswers.videoLines(player: engine, window: view.window)
        lines.append("")
        lines += MemoryLog.report
        lines.append("")
        lines += PictureInPicture.report
        lines.append("")
        lines += TopShelf.report
        let held = AetherPlayer.heldSourceConnection
        let priming = AudioOutput.primerEnabled
        let scrolls = BridgeScript.pageScrolls
        let menu = AppMenu(title: "AIOStreams", text: lines.joined(separator: "\n"), actions: [
            AppMenu.Action(title: "Play a test video…", destructive: false) { [weak self] in self?.askTestVideo() },
            AppMenu.Action(title: "Reload", destructive: false) { [weak self] in self?.loadPage() },
            AppMenu.Action(
                title: scrolls ? "Slide the page as one layer" : "Slide the page by scrolling", destructive: false
            ) { [weak self] in
                BridgeScript.pageScrolls = !scrolls
                self?.loadPage()
                self?.flashStatus(scrolls
                    ? "The page slides up and down as one layer, as it did"
                    : "The page slides up and down by scrolling")
            },
            AppMenu.Action(title: held ? "Use ranged source requests" : "Hold one source connection", destructive: false) {
                [weak self] in
                AetherPlayer.heldSourceConnection = !held
                self?.flashStatus(held
                    ? "Ranged source requests from the next video"
                    : "One held source connection from the next video")
            },
            AppMenu.Action(title: priming ? "Turn the Dolby primer off" : "Turn the Dolby primer on", destructive: false) {
                [weak self] in
                AudioOutput.primerEnabled = !priming
                self?.flashStatus(priming
                    ? "Dolby primer off from the next video"
                    : "Dolby primer on from the next video: for surround that plays as stereo")
            },
            AppMenu.Action(title: "Reset the app's data", destructive: true) { [weak self] in self?.confirmReset() },
            AppMenu.Action(title: "Close", destructive: false) {},
        ])
        // However it closed: an action, Close or Menu.
        menu.closed = { [weak self] in self?.web?.focusPage() }
        present(menu, animated: true)
    }

    private func confirmReset() {
        let confirm = UIAlertController(
            title: "Reset the app's data?",
            message: "This signs you out and forgets your servers and settings on this Apple TV.",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.storage.clear()
            self.web?.removeAllWebData { [weak self] in self?.loadPage() }
        })
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(confirm, animated: true)
    }

    /**
     * tvOS has no keyboard for a web page, so a field the page asks for opens
     * the system's, with dictation. Most fields get the search keyboard over
     * the page, typing straight into the field; passwords and PINs get the
     * alert, which keeps them hidden and sends a PIN's form on Done.
     */
    private func showKeyboard(_ message: Message) {
        guard presentedViewController == nil else { return }
        if message.flag("secure") == true || message.flag("numeric") == true { return showKeyboardAlert(message) }
        let keyboard = SearchKeyboard(
            text: message.text("value") ?? "",
            prompt: message.text("label") ?? "",
            keyboardType: message.flag("email") == true ? .emailAddress : message.flag("url") == true ? .URL : .default,
            onChange: { [weak self] text in
                guard let self else { return }
                self.callTV("input(\(self.jsString(text)))")
            },
            onClose: { [weak self] submit in
                guard let self else { return }
                self.keyboard = nil
                self.callTV("done(\(submit))")
                self.web?.focusPage()
            }
        )
        self.keyboard = keyboard
        present(keyboard.controller, animated: true)
    }

    /// The keyboard open over the page, kept until it closes.
    private var keyboard: SearchKeyboard?

    private func showKeyboardAlert(_ message: Message) {
        let label = message.text("label") ?? ""
        let alert = UIAlertController(title: label.isEmpty ? "Enter text" : label, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = message.text("value") ?? ""
            field.isSecureTextEntry = message.flag("secure") == true
            if message.flag("email") == true { field.keyboardType = .emailAddress }
            if message.flag("url") == true { field.keyboardType = .URL }
            // A PIN gets the digits-only keyboard.
            if message.flag("numeric") == true { field.keyboardType = .numberPad }
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let text = alert?.textFields?.first?.text ?? ""
            // A PIN is the last thing its form asks for, so Done sends it.
            let submit = message.flag("numeric") == true
            self.callTV("type(\(self.jsString(text)),\(submit))")
            self.web?.focusPage()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(alert, animated: true) { [weak alert] in
            // Straight to the keyboard rather than the alert's field.
            alert?.textFields?.first?.becomeFirstResponder()
        }
    }

    // MARK: Links

    /// A link out of the page: an `aiostreams://` link for the page, or another app's, such as a player's.
    private func open(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "aiostreams" { return receiveLink(url.absoluteString) }
        // A TV has no browser for a web link.
        if scheme == "http" || scheme == "https" { return }
        UIApplication.shared.open(url) { [weak self] opened in
            guard !opened else { return }
            self?.flashStatus("Couldn't open the player. Check that the app for \(scheme):// links is installed.")
        }
    }

    /// From the system, or a link in the page.
    func receiveLink(_ url: String) {
        guard url.lowercased().hasPrefix("aiostreams://") else { return }
        links.append(url)
        sendLinks()
    }

    private func sendLinks() {
        while linksReady, !links.isEmpty {
            sendToPage(["type": "link", "url": links.removeFirst()])
        }
    }

    // MARK: Messages

    private func receive(_ message: Message) {
        guard let type = message.text("type") else { return }
        if player?.handle(type, message) == true {
            // A load, a stop or a new item may show or hide the player's picture-in-picture button.
            updatePipButton()
            return
        }
        switch type {
        case "hello":
            connected = true
            status.isHidden = true
            web?.focusPage()
            pipButtonShown = false
            updatePipButton()
        case "tvos-pip":
            // The player's picture-in-picture button, which the bridge script adds.
            pip?.start()
        case "app-info":
            sendToPage(AppAnswers.appInfo())
        case "player-engine":
            // The page asks for its engine choice; this app has only AetherEngine. Like the Android app's
            // ExoPlayer, it plays on the system's decoders and has no mpv options, so the page treats it as
            // that: it hides mpv's settings and asks for ExoPlayer-style statistics (`player-stats`).
            sendToPage(["type": "player-engine", "name": "exoplayer"])
        case "fullscreen":
            sendToPage(["type": "fullscreen", "value": true])
        case "levels":
            sendToPage(["type": "levels", "volume": 1.0, "brightness": 1.0])
        case "links-ready":
            linksReady = true
            sendLinks()
        case "exit":
            leaveApp()
        case "tvos-storage":
            storage.apply(message)
        case "watch-next":
            // Continue Watching and Next Up, for the Top Shelf.
            TopShelf.publish(message)
        case "tvos-keyboard":
            showKeyboard(message)
        case "mpv-config", "mpv-config-save":
            sendToPage(["type": "mpv-config", "text": MPVConfig.text])
        case "diagnostics":
            sendToPage(AppAnswers.diagnostics(
                player: engine, window: view.window,
                web: message.text("web"), server: message.text("server")
            ))
        case "licenses":
            sendToPage(AppAnswers.licenses)
        case "crash-report":
            sendToPage(["type": "crash-report"])
        case "update-check", "update-apply":
            sendToPage(AppAnswers.updateState)
        case "youtube-resolve":
            // A trailer: its stream, for the player. Without one the page opens the link, which the YouTube app takes.
            let request = message.text("request") ?? ""
            YouTube.resolve(message.text("id") ?? "") { [weak self] url in
                self?.sendToPage(["type": "youtube-resolved", "request": request, "url": nullable(url)])
            }
        case "voice-search":
            // Dictation is on the keyboard's microphone; the page doesn't offer its own here.
            sendToPage(["type": "voice-result", "text": NSNull(), "error": "failed"])
        case "web-error":
            NSLog("[page] %@", message.text("message") ?? "")
        case "tvos-page-stats":
            MemoryLog.pageStats(message)
        case "tvos-slide":
            // How the page drew the slide after an Up or Down, in the remote log beside the key.
            let n = { (name: String) in Int(message.number(name) ?? 0) }
            input.notePage("\(message.text("key") ?? "?") slide: \(n("frames")) frames in \(n("ms")) ms, "
                + "longest gap \(n("longest")) ms, \(n("slow")) slow; \(n("nodes")) elements added, "
                + "\(n("images")) pictures loaded")
        default:
            // Downloads, keyboard completions and the like have no Apple TV part.
            break
        }
    }

    // MARK: Test video

    /// A video from a URL typed in the app menu plays in the page's own player, with its controls
    /// (`patches/web/0006-test-video-page.patch`), reached by an `aiostreams://test-video` link.
    private static let testURLKey = "debug.testVideoURL"

    private func askTestVideo() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Play a test video",
            message: "An http(s) link to a video file or an HLS playlist. It plays in the page's player, with its controls and settings; Back stops it.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = UserDefaults.standard.string(forKey: Self.testURLKey) ?? ""
            field.placeholder = "https://…"
            field.keyboardType = .URL
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Play", style: .default) { [weak self, weak alert] _ in
            let text = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self?.startTestVideo(text)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.web?.focusPage()
        })
        present(alert, animated: true) { [weak alert] in
            alert?.textFields?.first?.becomeFirstResponder()
        }
    }

    private func startTestVideo(_ url: String) {
        guard PlayerProtocol.isWebURL(url) else {
            web?.focusPage()
            return flashStatus("That isn't an http(s) link.")
        }
        // The page opens it once it's loaded and listening for links; one with a video open closes that first.
        guard connected else {
            web?.focusPage()
            return flashStatus("The page hasn't loaded yet.")
        }
        UserDefaults.standard.set(url, forKey: Self.testURLKey)
        // The link's value is decoded once by the page, so everything but unreserved characters is escaped.
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let value = url.addingPercentEncoding(withAllowedCharacters: unreserved) ?? url
        receiveLink("aiostreams://test-video?url=\(value)")
        web?.focusPage()
    }

    // MARK: App state

    func appWillResignActive() {
        storage.save()
        input.stopRepeating()
        // Presses down now end out of the app's sight.
        input.forgetPresses()
        pip?.appWillResignActive()
        // The picture-in-picture window keeps playing over the Home screen.
        if pip?.active != true { player?.change(Change(paused: true)) }
    }

    func appDidEnterBackground() {
        pip?.appDidEnterBackground()
    }

    /// The player opens a video again that tvOS made it let go of in the background (`AetherPlayer`);
    /// a picture-in-picture window comes back into the app.
    func appDidBecomeActive() {
        pip?.appDidBecomeActive()
        web?.focusPage()
    }
}
