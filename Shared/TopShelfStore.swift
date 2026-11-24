import Foundation

/// A title on the Top Shelf: one of the page's `watch-next` items.
struct TopShelfItem: Codable, Equatable {
    var id: String
    var episode: Bool
    /// The show's, for an episode.
    var title: String
    var episodeTitle: String?
    var season: Int?
    var number: Int?
    /// The page's landscape artwork, at the size the Top Shelf draws.
    var image: String?
    /// The movie's or show's poster, for the Top Shelf set to posters (`TopShelfStyle.posters`). Missing in
    /// a list saved before the setting.
    var poster: String?
    var positionMs: Double
    var durationMs: Double?
    /// `aiostreams://play/<id>?server=…&start=…`
    var link: String

    var resumes: Bool { positionMs > 0 }

    /// "Show · S1 E3", or the film's name.
    var label: String {
        guard episode else { return title }
        var parts = [title]
        switch (season, number) {
        case let (s?, n?): parts.append("S\(s) E\(n)")
        case let (nil, n?): parts.append("E\(n)")
        default: if let episodeTitle { parts.append(episodeTitle) }
        }
        return parts.joined(separator: " · ")
    }

    var progress: Double? {
        guard resumes, let durationMs, durationMs > 0 else { return nil }
        return min(max(positionMs / durationMs, 0), 1)
    }

    var playURL: URL? { URL(string: link) }

    /// The item's page rather than playing it: `aiostreams://item/<id>?server=…`.
    var detailsURL: URL? {
        guard var parts = URLComponents(string: link) else { return nil }
        parts.host = "item"
        // As the page encoded it.
        parts.percentEncodedQueryItems = parts.percentEncodedQueryItems?.filter { $0.name == "server" }
        return parts.url
    }
}

/// What the Top Shelf shows of the list, as the page's Top Shelf setting (patches/web/0104) picks.
enum TopShelfStyle: String {
    /// Each title's landscape picture, as Continue Watching and Next Up show them (the default).
    case thumbnails
    /// The movies' and shows' posters.
    case posters
    /// Nothing: tvOS shows the app's Top Shelf image.
    case off
}

/**
 * Where the app leaves the Top Shelf's list for the extension: a folder in
 * each App Group this process is signed with. Sideloading tools rename the
 * groups when they re-sign, some to a handful of generic ones
 * (`group.<hash>.1` to `.5`) in no set order, so neither side can tell which
 * one the other picked. The app writes to all of them, and each side reads
 * the newest copy it finds in any.
 */
enum TopShelfStore {
    static let declaredGroup = "group.io.github.aiostreams.tvos"

    /// The Top Shelf's artwork width, in pixels: 548 points at 2x.
    static let imageWidth = 1096
    /// A poster's, in pixels: the sectioned Top Shelf draws them 404 points wide, at 2x.
    static let posterWidth = 808

    /// The App Groups this process was signed with.
    static let entitled = entitledGroups()

    private static var groups: [String] { entitled.isEmpty ? [declaredGroup] : entitled }

    /**
     * A TopShelf folder in each group's container that tvOS gave this process.
     * tvOS keeps nothing on disk but caches, in a shared container as in the
     * app's own, and refuses writes anywhere else in it; so `Library/Caches`.
     */
    static let folders: [URL] = groups.compactMap {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
    }

    /// Each group's shared settings, which tvOS keeps, unlike caches.
    private static let suites: [UserDefaults] = groups.compactMap { UserDefaults(suiteName: $0) }

    private static let listName = "items.json"
    private static let mergedName = "merged.txt"
    private static let styleName = "style.txt"
    private static let languageName = "language.txt"
    private static let askedName = "asked.txt"
    private static func settingsKey(_ name: String) -> String { "aiostreams.topShelf.\(name)" }

    /// The most recently written copy, from any group's settings or folder.
    private static func newest(_ name: String) -> Data? {
        let key = settingsKey(name)
        let fromSettings = suites.compactMap { suite -> (Data, Date)? in
            guard let saved = suite.dictionary(forKey: key),
                  let data = saved["data"] as? Data, let date = saved["date"] as? Date else { return nil }
            return (data, date)
        }
        let fromFiles = folders.compactMap { folder -> (Data, Date)? in
            let url = folder.appendingPathComponent(name)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  let data = try? Data(contentsOf: url) else { return nil }
            return (data, date)
        }
        return (fromSettings + fromFiles).max { $0.1 < $1.1 }?.0
    }

    /// Why the last write into a group's folder failed, for the app menu.
    private(set) static var lastError: String?
    /// Where the last write went: how many groups' settings and folders took it.
    private(set) static var lastWrite = (settings: 0, files: 0)

    /// Into every group's settings and folder; true if any took it.
    private static func write(_ data: Data, as name: String) -> Bool {
        let now = Date()
        var settings = 0
        for suite in suites {
            suite.set(["data": data, "date": now], forKey: settingsKey(name))
            if suite.synchronize() { settings += 1 }
        }
        var files = 0
        for folder in folders {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                files += 1
            } catch {
                let reason = (error as NSError).underlyingErrors.first.map { $0.localizedDescription }
                    ?? error.localizedDescription
                lastError = "\((error as NSError).code): \(reason)"
                NSLog("[top-shelf] writing %@ to %@: %@", name, folder.path, String(describing: error))
            }
        }
        if files > 0 { lastError = nil }
        lastWrite = (settings, files)
        return settings + files > 0
    }

    /// The app has written a list, even an empty one, where this process can read it.
    static var hasList: Bool { newest(listName) != nil }

    static func load() -> [TopShelfItem] {
        guard let data = newest(listName) else { return [] }
        return (try? JSONDecoder().decode([TopShelfItem].self, from: data)) ?? []
    }

    /// The page's language, which the Top Shelf's row titles follow (`TopShelfText`); British English until it says.
    static var language: String {
        newest(languageName).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 } ?? "en-GB"
    }

    /// The page's language, saved for the extension; true if it changed and was saved.
    @discardableResult
    static func saveLanguage(_ language: String) -> Bool {
        guard !language.isEmpty, language != self.language else { return false }
        return write(Data(language.utf8), as: languageName)
    }

    /// The page merges Next Up into Continue Watching, so the Top Shelf shows the list as one row.
    static var merged: Bool { newest(mergedName).flatMap { String(data: $0, encoding: .utf8) } == "1" }

    /// What the Top Shelf shows of the list; thumbnails until the page says otherwise.
    static var style: TopShelfStyle {
        newest(styleName).flatMap { String(data: $0, encoding: .utf8) }.flatMap(TopShelfStyle.init(rawValue:)) ?? .thumbnails
    }

    /// The list, whether it shows as one row, and how; written before the list, which the extension reads by.
    @discardableResult
    static func save(_ items: [TopShelfItem], merged: Bool, style: TopShelfStyle) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        _ = write(Data((merged ? "1" : "0").utf8), as: mergedName)
        _ = write(Data(style.rawValue.utf8), as: styleName)
        return write(data, as: listName)
    }

    /// The extension notes when tvOS asked it for the Top Shelf, and what it showed.
    static func noteAsked(shown: Int) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(shown)"
        _ = write(Data(line.utf8), as: askedName)
    }

    /// When tvOS last asked the extension, and how many titles it showed then.
    static func lastAsked() -> (date: Date, shown: Int)? {
        guard let data = newest(askedName), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let date = ISO8601DateFormatter().date(from: String(parts[0])),
              let shown = Int(parts[1]) else { return nil }
        return (date, shown)
    }

    /// The page asks Jellyfin for artwork 400 wide, for its own row; the Top Shelf draws it wider.
    static func sized(_ url: String, width: Int = imageWidth) -> String {
        guard var parts = URLComponents(string: url) else { return url }
        // The rest as the page encoded it.
        var query = (parts.percentEncodedQueryItems ?? []).filter { $0.name.lowercased() != "maxwidth" }
        query.append(URLQueryItem(name: "maxWidth", value: String(width)))
        parts.percentEncodedQueryItems = query
        return parts.string ?? url
    }

    /**
     * This process's `com.apple.security.application-groups`. Security.framework
     * has the calls on tvOS but leaves them out of the SDK's headers.
     */
    private static func entitledGroups() -> [String] {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias Copy = @convention(c) (AnyObject, CFString, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let createSymbol = dlsym(security, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(security, "SecTaskCopyValueForEntitlement")
        else { return [] }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        let copy = unsafeBitCast(copySymbol, to: Copy.self)
        guard let task = create(nil)?.takeRetainedValue(),
              let value = copy(task, "com.apple.security.application-groups" as CFString, nil)?.takeRetainedValue()
        else { return [] }
        return (value as? [String]) ?? []
    }
}
