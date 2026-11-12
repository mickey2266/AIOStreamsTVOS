import AetherHost
import Foundation

/*
 * The page's player messages, as the desktop and Android apps read them
 * (AIOStreams' packages/android/playback Player.kt). Each field is checked
 * before the player sees it.
 */

struct ProtocolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum SubtitleMode: String {
    case `default`, always, smart, forced, none
}

struct LoadRequest {
    let url: String
    let headers: [String: String]
    let startMs: Double
    /// Plays after the current file rather than in its place.
    let append: Bool
    let audioLanguages: [String]
    let subtitleLanguages: [String]
    let subtitleMode: SubtitleMode
    /// The server says it's live (a Live TV channel's `IsInfiniteStream`). False isn't a promise: an
    /// add-on's stream may be live without saying so, which `LiveHLS` finds out.
    let live: Bool
    /// Drawn in a box of the page from its start (a trailer playing by itself in a card, the hero or a title
    /// page), as the bridge script marks a load the page framed in the same turn (VideoStage). The TV keeps
    /// its mode for it: a muted preview isn't worth the screen blanking for Match Content.
    var framed = false

    /// A trailer, from YouTube (`YouTube.resolve`), whose streams all come from googlevideo.com.
    var isTrailer: Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }
}

/// A track to show, or none at all.
enum Pick: Equatable {
    case track(String)
    case off
}

struct Change {
    var paused: Bool?
    var volume: Double?
    var muted: Bool?
    var speed: Double?
    var audio: Pick?
    var subtitle: Pick?
    var subtitleDelayMs: Double?
}

enum Fit {
    case fit, crop, stretch
}

/// Colours are `#AARRGGBB` or `#RRGGBB`, sizes in mpv's units (a 720-line picture), which the page sends for every app.
struct SubtitleLook {
    let scale: Double
    let bold: Bool
    let color: String
    let outlineColor: String
    let outlineSize: Double
    let shadowSize: Double
    /// One of the page's font names (`SubtitleFonts`), or nil for the system's.
    let font: String?
    let backColor: String
    let box: Bool
    let forceStyle: Bool
    /// Percent of the height from the top where the bottom line sits.
    let position: Double
}

struct Style {
    let fit: Fit
    let subtitles: SubtitleLook
}

/// The settings the page sends that the player applies itself.
struct PlayerSettings: Equatable {
    var hardwareDecoding = true
    /// The page's Dolby Vision switch: off plays the HDR10 / HLG base layer on a Dolby Vision TV too.
    var dolbyVision = true
    /// `auto`, `stereo`, `5.1` or `7.1`.
    var audioChannels = "auto"
    /// The formats the receiver takes, in mpv's `audio-spdif` names: `ac3`, `eac3`, `dts`, `dts-hd`, `truehd`.
    var passthrough: [String] = []
    /// The page's Automatic: whatever the output takes, which on an Apple TV is decided by tvOS.
    var passthroughAuto = false
    var audioDelayMs = 0.0
    /// Gain on the dialogue in dB, 0 for none.
    var dialogueBoost = 0.0
    /// Evens out loud and quiet scenes.
    var nightMode = false
    /// The page's Object audio switch (tvOS only): TrueHD Atmos and DTS:X keep their objects and heights,
    /// rendered into `objectAudioLayout`, instead of playing as their 7.1 (`AetherPlayer.options`).
    var objectAudio = false
    /// The page's Speakers choice under it: 7.1.4 (the default) or 9.1.6, the two beds DTS:X renders into.
    var objectAudioLayout: SpatialSpeakerLayout = .l714
    /// Megabytes of the stream to hold, ahead and behind, 0 for the engine's own (`AetherPlayer.options`).
    var cacheMb = 0
}

enum PlayerProtocol {
    static func isWebURL(_ value: String) -> Bool {
        guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func load(_ message: Message) throws -> LoadRequest {
        guard let url = message.text("url") else { throw ProtocolError("player-load takes a url") }
        guard isWebURL(url) else { throw ProtocolError("only http(s) urls play") }
        return LoadRequest(
            url: url,
            headers: try headers(message["headers"]),
            startMs: message.number("startMs") ?? 0,
            append: message.flag("append") == true,
            audioLanguages: try languages(message["audioLanguages"]),
            subtitleLanguages: try languages(message["subtitleLanguages"]),
            subtitleMode: message.text("subtitleMode").flatMap(SubtitleMode.init(rawValue:)) ?? .default,
            live: message.flag("live") == true,
            framed: message.flag("framed") == true
        )
    }

    static func change(_ message: Message) throws -> Change {
        Change(
            paused: message.flag("paused"),
            volume: message.number("volume"),
            muted: message.flag("muted"),
            speed: message.number("speed"),
            audio: try pick(message, "audio"),
            subtitle: try pick(message, "subtitle"),
            subtitleDelayMs: message.number("subtitleDelayMs")
        )
    }

    static func style(_ message: Message) throws -> Style {
        guard let look = message.object("subtitles") else { throw ProtocolError("player-style takes subtitles") }
        func colour(_ name: String) throws -> String {
            guard let value = look.text(name), value.range(of: colourPattern, options: .regularExpression) != nil else {
                throw ProtocolError("\(name) is not a colour")
            }
            return value
        }
        let fit: Fit
        switch message.text("fit") {
        case "crop": fit = .crop
        case "stretch": fit = .stretch
        default: fit = .fit
        }
        return Style(
            fit: fit,
            subtitles: SubtitleLook(
                scale: look.number("scale") ?? 1,
                bold: look.flag("bold") == true,
                color: try colour("color"),
                outlineColor: try colour("outlineColor"),
                outlineSize: look.number("outlineSize") ?? 0,
                shadowSize: look.number("shadowSize") ?? 0,
                font: try look.text("font").flatMap(font),
                backColor: try colour("backColor"),
                box: look.flag("box") == true,
                forceStyle: look.text("override") == "force",
                position: look.number("position") ?? 100
            )
        )
    }

    static func settings(_ message: Message) -> PlayerSettings {
        var settings = PlayerSettings()
        settings.hardwareDecoding = message.flag("hardwareDecoding") != false
        settings.dolbyVision = message.flag("dolbyVision") != false
        settings.audioChannels = message.text("audioChannels") ?? "auto"
        settings.passthroughAuto = message.flag("passthroughAuto") == true
        if !settings.passthroughAuto {
            settings.passthrough = (message["passthrough"] as? [Any])?
                .compactMap { $0 as? String }
                .filter { passthroughFormats.contains($0) } ?? []
        }
        settings.audioDelayMs = message.number("audioDelayMs") ?? 0
        settings.dialogueBoost = max(0, message.number("dialogueBoost") ?? 0)
        settings.nightMode = message.flag("nightMode") == true
        settings.objectAudio = message.flag("objectAudio") == true
        settings.objectAudioLayout = message.text("objectAudioLayout") == "9.1.6" ? .l916 : .l714
        // The page offers 128 to 1000 MB; a value far outside that is held to 64...4000.
        let cacheMb = message.number("cacheMb") ?? 0
        settings.cacheMb = cacheMb.isFinite && cacheMb > 0 ? Int(min(max(cacheMb, 64), 4000)) : 0
        return settings
    }

    /// The page's font names, which are Android's. The overlay maps each to a family tvOS has (`SubtitleFonts`).
    private static func font(_ name: String) throws -> String? {
        guard SubtitleFonts.names.contains(name) else { throw ProtocolError("\(name) is not a font") }
        return name
    }

    private static let colourPattern = "^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"
    private static let languagePattern = "^[A-Za-z0-9-]{1,16}$"
    private static let passthroughFormats: Set<String> = ["ac3", "eac3", "dts", "dts-hd", "truehd"]
    private static let headerNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"
    )

    static func headers(_ value: Any?) throws -> [String: String] {
        guard let map = value as? Message else { return [:] }
        var headers: [String: String] = [:]
        for (name, raw) in map {
            guard let text = raw as? String,
                  !name.isEmpty,
                  name.unicodeScalars.allSatisfy(headerNameCharacters.contains),
                  text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e })
            else { throw ProtocolError("header \(name) is not allowed") }
            headers[name] = text
        }
        return headers
    }

    private static func languages(_ value: Any?) throws -> [String] {
        guard let list = value as? [Any] else { return [] }
        // A preference the player only weighs: one it can't read is left out, rather than the whole load
        // refused over a tag saved elsewhere in another form.
        return list.compactMap { item in
            guard let code = item as? String, code.range(of: languagePattern, options: .regularExpression) != nil else {
                NSLog("[player] left out a language preference it can't read: %@", String(describing: item))
                return nil
            }
            return code
        }
    }

    private static func pick(_ message: Message, _ name: String) throws -> Pick? {
        guard let value = message[name] else { return nil }
        if value is NSNull { return .off }
        guard let id = value as? String, !id.isEmpty, id.allSatisfy(\.isASCIIDigit) else {
            throw ProtocolError("\(name) \(value) is not a track")
        }
        return .track(id)
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
