import os
import UIKit

/// Who the app is to the page and to Jellyfin servers.
enum Identity {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    /// Kept by the app, since the page's storage may be cleared with the caches.
    static let deviceId: String = {
        let key = "aiostreams.deviceId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static let device = UIDevice.current.name.isEmpty ? "Apple TV" : UIDevice.current.name

    /// Ends in "iPad" so the web app offers the iOS players (Infuse, VLC) for external playback.
    static var userAgent: String {
        let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPad; CPU OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) AIOStreamsTV/\(version)"
    }
}

/// The app's folders. tvOS keeps only caches on disk, which it may clear when space runs low.
enum AppFolders {
    static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    static let subtitles = caches.appendingPathComponent("subtitles", isDirectory: true)

    static func create() {
        try? FileManager.default.createDirectory(at: subtitles, withIntermediateDirectories: true)
        // mpv's folders, from before the app played with AetherEngine.
        for old in ["mpv", "shaders"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(old, isDirectory: true))
        }
    }
}

/**
 * What the page's mpv.conf editor shows. The page offers it while its engine
 * setting says mpv, but this app plays with AetherEngine, which has no
 * config file, so saving changes nothing.
 */
enum MPVConfig {
    static let text = """
    # This app plays with AetherEngine, not mpv, so options here do nothing.
    # Sound and subtitle settings are under Settings → Playback.

    """
}

/**
 * When the page's web process ended and what memory looked like then, to see
 * whether it runs out while browsing or while a video plays. The web process
 * is WebKit's own; its size comes from WebKit (`AIOWebView.webProcessMB`),
 * sampled every few seconds, as it's gone by the time it has ended.
 */
@MainActor
enum MemoryLog {
    private(set) static var lines: [String] = []
    private(set) static var pageEnds = 0

    /// The page's web process in MB, or nil where WebKit doesn't say.
    static var webMB: () -> Int? = { nil }
    /// WebKit's graphics process in MB, which holds the page's decoded pictures and layers; nil where WebKit doesn't say.
    static var gpuMB: () -> Int? = { nil }
    /// How the last `webMB` and `gpuMB` got their figures, or why they got none.
    static var routes: () -> (page: String?, gpu: String?) = { (nil, nil) }
    private static var loggedRoutes: String?
    private static var lastWebMB: Int?
    private static var peakWebMB: Int?
    private static var lastGpuMB: Int?
    private static var peakGpuMB: Int?
    private static var sampler: Timer?

    /// Samples the web process from now on, for its size before it ends and its largest.
    static func startSampling() {
        guard sampler == nil else { return }
        sampler = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { sample() }
        }
    }

    private static func sample() {
        if let mb = webMB() {
            lastWebMB = mb
            peakWebMB = max(peakWebMB ?? 0, mb)
        }
        if let mb = gpuMB() {
            lastGpuMB = mb
            peakGpuMB = max(peakGpuMB ?? 0, mb)
        }
        // Logged when it changes, not every 5 s.
        let text = routeText
        if text != loggedRoutes {
            loggedRoutes = text
            NSLog("[memory] %@", text)
        }
    }

    private static var routeText: String {
        let (page, gpu) = routes()
        return "Page memory from: \(page ?? "not asked yet"); WebKit graphics memory from: \(gpu ?? "not asked yet")"
    }

    /// This app's own memory, as tvOS counts it against the app's limit.
    static var appMB: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : nil
    }

    /// What the app may still take before tvOS ends it.
    static var leftMB: Int { Int(os_proc_available_memory() >> 20) }

    static var now: String {
        let page = webMB().map { "page \($0) MB, " } ?? ""
        let gpu = gpuMB().map { "WebKit graphics \($0) MB, " } ?? ""
        return page + gpu + "app \(appMB.map { "\($0) MB" } ?? "?"), \(leftMB) MB left"
    }

    /// What ended the page's web process, from WebKit's reason (`AIOPageEnd`).
    static func cause(_ reason: AIOPageEnd) -> String {
        switch reason.rawValue {
        case 0: return "out of memory"
        case 1: return "too much processor time"
        case 2: return "closed by WebKit"
        // tvOS killing it for memory comes through as this too, as WebKit only sees its process die.
        case 3: return "crashed or ran out of memory"
        case 4: return "WebKit's graphics process crashing repeatedly"
        default: return "no reason given"
        }
    }

    /// When WebKit last said the page's process stopped answering, while it still hasn't.
    private static var unresponsiveSince: Date?

    /// The page's own count of what it holds, from its last `tvos-page-stats`, and the largest picture total seen.
    private static var lastStats: String?
    private static var peakPictureMB: Int?

    /// A `tvos-page-stats` message: the pictures, canvases and elements the page holds, every 5 s.
    static func pageStats(_ message: Message) {
        func int(_ name: String) -> Int { Int(message.number(name) ?? 0) }
        let pictureMB = int("pictureMB")
        peakPictureMB = max(peakPictureMB ?? 0, pictureMB)
        var text = "pictures \(pictureMB) MB in \(int("pictures"))"
        text += " (artwork \(int("artworkMB")) MB in \(int("artwork")), \(int("released")) released"
        if let largest = message.text("largest"), !largest.isEmpty { text += ", largest \(largest)" }
        text += ")"
        if int("canvases") > 0 { text += ", canvases \(int("canvasMB")) MB in \(int("canvases"))" }
        if int("videos") > 0 { text += ", \(int("videos")) videos" }
        text += ", \(int("cards")) cards, \(int("elements")) elements"
        lastStats = text
    }

    /// WebKit's word that the page's process stopped answering it, or answers again.
    static func pageResponsive(_ responsive: Bool, playing: Bool) {
        let doing = playing ? "with a video loaded" : "while browsing"
        if !responsive {
            guard unresponsiveSince == nil else { return }
            unresponsiveSince = Date()
            note("page stopped responding \(doing)")
        } else if let since = unresponsiveSince {
            unresponsiveSince = nil
            note("page responding again after \(seconds(since)) \(doing)")
        }
    }

    private static func seconds(_ since: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(since))
    }

    /// `path` is where the page was, such as `/discover`, so the log names the page that ended.
    static func pageEnded(playing: Bool, reason: AIOPageEnd, at path: String?) {
        pageEnds += 1
        // Whether it was hung as it ended tells a hang from a crash or a memory kill.
        var before = unresponsiveSince.map { "; not responding for \(seconds($0)) before" }
            ?? "; responding up to the end"
        unresponsiveSince = nil
        var sizes = lastWebMB.map { "page \($0) MB" } ?? ""
        if let gpu = lastGpuMB { sizes += (sizes.isEmpty ? "" : ", ") + "WebKit graphics \(gpu) MB" }
        if !sizes.isEmpty { before += "; \(sizes) at most 5 s before" }
        if let stats = lastStats { before += "; the page held \(stats) at most 5 s before" }
        lastWebMB = nil
        lastGpuMB = nil
        lastStats = nil
        let page = path.map { " on \($0)" } ?? ""
        note("page's web process ended (\(cause(reason)))\(page) \(playing ? "with a video loaded" : "while browsing")\(before)")
    }

    static func warning(playing: Bool) {
        note("memory warning \(playing ? "with a video loaded" : "while browsing")")
    }

    private static func note(_ what: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "\(time): \(what); \(now)"
        NSLog("[memory] %@", line)
        lines.append(line)
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
    }

    /// For the app menu and the diagnostics.
    static var report: [String] {
        var peak = peakWebMB.map { ", the page at most \($0) MB" } ?? ""
        if let gpu = peakGpuMB { peak += ", WebKit graphics at most \(gpu) MB" }
        if let pictures = peakPictureMB { peak += ", the page's pictures at most \(pictures) MB" }
        var head = ["Memory: \(now); the page reloaded \(pageEnds) times since launch\(peak)", routeText]
        if let stats = lastStats { head.append("The page now holds \(stats)") }
        return head + lines
    }
}

/// Answers to the page's requests about the app itself.
@MainActor
enum AppAnswers {
    static func appInfo() -> Message {
        [
            "type": "app-info",
            // About shows it as the "tvOS app" (patches/web/0010).
            "app": Identity.version,
            "platform": "android",
            "mpv": NSNull(),
            "ffmpeg": "FFmpeg in AetherEngine \(AetherPlayer.version)",
            "player": "AetherEngine \(AetherPlayer.version)",
            "ac3Encoder": false,
        ]
    }

    /// How the video and its sound play, what the TV does with them, and the engine's latest audio lines.
    static func videoLines(player: AetherPlayer?, window: UIWindow?) -> [String] {
        let matching = window.map { $0.avDisplayManager.isDisplayCriteriaMatchingEnabled ? "on" : "off" } ?? "unknown"
        var lines = player?.report ?? ["Player: not started"]
        lines.append("Match Content: \(matching)")
        let stalls = EngineLogBook.recentStalls
        if !stalls.isEmpty {
            lines.append("")
            lines.append("Last \(stalls.count) stalls across videos, newest last:")
            lines += stalls
        }
        let audio = EngineLogBook.recentAudio
        if !audio.isEmpty {
            lines.append("")
            lines.append("Engine's audio and loading log, newest last:")
            lines += audio
        }
        return lines
    }

    static func diagnostics(player: AetherPlayer?, window: UIWindow?, web: String?, server: String?) -> Message {
        let lines = [
            "AIOStreams for Apple TV \(Identity.version)",
            "tvOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
        ] + videoLines(player: player, window: window) + [""] + MemoryLog.report + TopShelf.report + [
            "Web app: \(web ?? "unknown")",
            "Server: \(server ?? "none")",
        ]
        return ["type": "diagnostics", "text": lines.joined(separator: "\n")]
    }

    /// What the app ships besides the page, for the page's Licences list. FFmpegBuild bundles dav1d, zimg
    /// and libzvbi (its README's licence table; libzvbi's GPL files are left out of that build), the
    /// engine's `TrueHDObjectAudio` trait links LibTrueHD with truehdd's crates (Apache-2.0), and
    /// swift-libass bundles libass with FreeType, FriBidi, HarfBuzz, fontconfig and libpng (its README's
    /// prebuilt versions).
    static let licenses: Message = [
        "type": "licenses",
        "texts": [
            "GNU Lesser General Public License, version 3, with AetherEngine's Apple Store exception: https://github.com/superuser404notfound/AetherEngine/blob/main/LICENSE",
            "GNU Lesser General Public License, version 2.1: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html",
            "MIT License: https://opensource.org/license/mit",
            "BSD 2-Clause License: https://opensource.org/license/bsd-2-clause",
            "WTFPL: https://www.wtfpl.net/about/",
            "GNU Library General Public License, version 2: https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html",
            "ISC License: https://opensource.org/license/isc-license-txt",
            "FreeType License (or GPL-2.0): https://gitlab.freedesktop.org/freetype/freetype/-/blob/master/docs/FTL.TXT",
            "PNG Reference Library License, version 2: https://github.com/pnggroup/libpng/blob/libpng16/LICENSE",
            "Fontconfig licence (MIT style): https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/main/COPYING",
            "Apache License, version 2.0: https://www.apache.org/licenses/LICENSE-2.0 (LibTrueHD's NOTICE: https://github.com/superuser404notfound/LibTrueHD/blob/main/NOTICE)",
        ],
        "libraries": [
            ["name": "AetherEngine", "licence": "LGPL-3.0", "url": "https://github.com/superuser404notfound/AetherEngine", "texts": [0]],
            ["name": "FFmpeg (FFmpegBuild)", "licence": "LGPL-2.1-or-later", "url": "https://github.com/superuser404notfound/FFmpegBuild", "texts": [1]],
            ["name": "dav1d (FFmpegBuild)", "licence": "BSD-2-Clause", "url": "https://code.videolan.org/videolan/dav1d", "texts": [3]],
            ["name": "zimg (FFmpegBuild)", "licence": "WTFPL", "url": "https://github.com/sekrit-twc/zimg", "texts": [4]],
            ["name": "libzvbi (FFmpegBuild)", "licence": "LGPL-2.0-or-later", "url": "https://github.com/zapping-vbi/zvbi", "texts": [5, 2]],
            ["name": "libdovi (LibDovi)", "licence": "MIT", "url": "https://github.com/quietvoid/dovi_tool", "texts": [2]],
            ["name": "LibTrueHD", "licence": "MIT", "url": "https://github.com/superuser404notfound/LibTrueHD", "texts": [2]],
            ["name": "truehd and oamd (truehdd, in LibTrueHD)", "licence": "Apache-2.0", "url": "https://github.com/truehdd/truehdd", "texts": [10]],
            ["name": "swift-libass", "licence": "MIT", "url": "https://github.com/mihai8804858/swift-libass", "texts": [2]],
            ["name": "libass", "version": "0.17.3", "licence": "ISC", "url": "https://github.com/libass/libass", "texts": [6]],
            ["name": "FreeType", "version": "2.13.2", "licence": "FTL OR GPL-2.0-or-later", "url": "https://freetype.org", "texts": [7]],
            ["name": "FriBidi", "version": "1.0.14", "licence": "LGPL-2.1-or-later", "url": "https://github.com/fribidi/fribidi", "texts": [1]],
            ["name": "HarfBuzz", "version": "8.5.0", "licence": "MIT", "url": "https://github.com/harfbuzz/harfbuzz", "texts": [2]],
            ["name": "fontconfig", "version": "2.15.0", "url": "https://www.freedesktop.org/wiki/Software/fontconfig/", "texts": [9]],
            ["name": "libpng", "version": "1.6.43", "licence": "libpng-2.0", "url": "http://www.libpng.org/pub/png/libpng.html", "texts": [8]],
        ] as [Message],
    ]

    /// This app doesn't update itself; it's built and installed from Xcode.
    static let updateState: Message = [
        "type": "update-state", "state": "off", "channel": NSNull(), "version": NSNull(), "error": NSNull(),
    ]
}

/// Back to the TV's home screen, as the Menu button does. tvOS has no public call for it.
func suspendApp() {
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
}
