import Foundation
import ImageIO

/**
 * Pictures the page asks the app to draw down to a width, at
 * `aiostv://localhost/fit/<width>?u=<address>`: backdrops at the screen's width
 * (patches/web/0042), and every other artwork at the width its address asks for
 * (BridgeScript's FIT_IMAGES). The server
 * sends TMDB's original, often wider than 3000, for any backdrop asked over
 * 1280 wide, and WebKit holds each decoded at its full size: about three in
 * the hero ran the page's process out of memory with the artwork background
 * on. The page's own artwork workers can't help, as this WebKit doesn't start
 * them for the app's scheme.
 *
 * Here the original is fetched and ImageIO makes the smaller copy, decoding a
 * JPEG at the reduced size itself, so the whole picture is never held in
 * either process. One already no wider goes back as it came. All in the app's
 * process, which has the memory to spare.
 */
enum ImageFit {
    static let prefix = "/fit/"

    /// How the fits went since launch, for the memory log.
    struct Counts {
        var drawn = 0
        var passed = 0
        var failed = 0
        var lastError = ""
    }

    private static let lock = NSLock()
    private static var counts = Counts()
    /**
     * Fitted pictures by address and width, the newest, as the hero comes back round to them and the
     * page's sweep puts released artwork back as it nears the screen again. Encoded, so a few MB.
     */
    private static var kept: [String: (data: Data, type: String)] = [:]
    private static var order: [String] = []
    private static var keptBytes = 0
    private static let keptMaxBytes = 32 << 20
    /// One at a time, so at most one picture is being made at once.
    private static let queue = DispatchQueue(label: "io.github.aiostreams.image-fit", qos: .userInitiated)
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        // Every picture on the page comes through here, so originals are kept on disk too.
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 256 << 20,
                                          directory: AppFolders.caches.appendingPathComponent("image-fit", isDirectory: true))
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    static var current: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// The picture at `source` no wider than `width`, as `done(data, type)`, or `done(nil, nil)`.
    static func fit(_ source: URL, width: Int, done: @escaping (Data?, String?) -> Void) {
        guard ["http", "https"].contains(source.scheme?.lowercased() ?? ""), width > 0 else {
            note(failed: "not a web address")
            return done(nil, nil)
        }
        let key = "\(width) \(source.absoluteString)"
        if let hit = cached(key) { return done(hit.data, hit.type) }
        session.dataTask(with: source) { data, response, error in
            if let error {
                note(failed: error.localizedDescription)
                return done(nil, nil)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard let data, (200..<300).contains(status) else {
                note(failed: "HTTP \(status)")
                return done(nil, nil)
            }
            queue.async {
                guard let made = make(data, width: width) else {
                    note(failed: "couldn't read the picture")
                    return done(nil, nil)
                }
                keep(key, made.data, made.type)
                note(drawn: made.drawn)
                done(made.data, made.type)
            }
        }.resume()
    }

    private static func make(_ data: Data, width: Int) -> (data: Data, type: String, drawn: Bool)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelsWide = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelsHigh = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelsWide > 0, pixelsHigh > 0
        else { return nil }
        let png = (CGImageSourceGetType(source) as String?) == "public.png"
        let type = png ? "image/png" : mime(CGImageSourceGetType(source) as String?)
        if pixelsWide <= width { return (data, type, false) }
        // ImageIO sizes a thumbnail by its longer side; the width is what's capped.
        let longest = Int((Double(max(pixelsWide, pixelsHigh)) * Double(width) / Double(pixelsWide)).rounded())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        // A PNG may be see-through; a backdrop otherwise is not.
        let format = png ? "public.png" : "public.jpeg"
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, format as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, png ? "image/png" : "image/jpeg", true)
    }

    private static func mime(_ uti: String?) -> String {
        switch uti {
        case "public.jpeg": return "image/jpeg"
        case "org.webmproject.webp": return "image/webp"
        case "public.avif": return "image/avif"
        case "com.compuserve.gif": return "image/gif"
        default: return "image/jpeg"
        }
    }

    private static func cached(_ key: String) -> (data: Data, type: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = kept[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    private static func keep(_ key: String, _ data: Data, _ type: String) {
        lock.lock()
        defer { lock.unlock() }
        if let old = kept.updateValue((data, type), forKey: key) {
            keptBytes -= old.data.count
        } else {
            order.append(key)
        }
        keptBytes += data.count
        while keptBytes > keptMaxBytes, !order.isEmpty {
            if let gone = kept.removeValue(forKey: order.removeFirst()) { keptBytes -= gone.data.count }
        }
    }

    private static func note(drawn: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if drawn { counts.drawn += 1 } else { counts.passed += 1 }
    }

    private static func note(failed why: String) {
        lock.lock()
        defer { lock.unlock() }
        counts.failed += 1
        counts.lastError = why
    }
}
