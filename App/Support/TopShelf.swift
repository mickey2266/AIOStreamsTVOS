import TVServices

/**
 * The page's `watch-next` list, what Android TV puts in its Watch Next row:
 * the home page's resume points and next episodes, newest first, or none
 * once signed out. Saved where the Top Shelf extension reads it, and tvOS
 * told to ask the extension again.
 */
enum TopShelf {
    /// The last list the page sent was saved, so the same list again needn't be.
    private static var lastSaved = false

    static func publish(_ message: Message) {
        let items = (message["items"] as? [Message] ?? []).compactMap(item)
        // The page's "Merge Continue Watching and Next Up" (patches/web/0074): one row, as the home page shows.
        let merged = message.flag("merged") == true
        // The page's Top Shelf setting (patches/web/0104); a list sent without it, as at sign-out, keeps the last.
        let style = message.text("shelf").flatMap(TopShelfStyle.init(rawValue:)) ?? TopShelfStore.style
        if items == TopShelfStore.load(), merged == TopShelfStore.merged, style == TopShelfStore.style, lastSaved { return }
        let saved = TopShelfStore.save(items, merged: merged, style: style)
        lastSaved = saved
        if saved {
            TVTopShelfContentProvider.topShelfContentDidChange()
        } else {
            NSLog("[top-shelf] no App Group container took the list; groups: %@", TopShelfStore.entitled.joined(separator: ", "))
        }
    }

    /// The page's language, for the Top Shelf's row titles; tvOS asks the extension again when it changes.
    static func language(_ language: String) {
        if TopShelfStore.saveLanguage(language) { TVTopShelfContentProvider.topShelfContentDidChange() }
    }

    private static func item(_ entry: Message) -> TopShelfItem? {
        guard let id = entry.text("id"), let title = entry.text("title"), let link = entry.text("link") else { return nil }
        return TopShelfItem(
            id: id,
            episode: entry.text("kind") == "episode",
            title: title,
            episodeTitle: entry.text("episodeTitle"),
            season: entry.number("season").map { Int($0) },
            number: entry.number("episode").map { Int($0) },
            image: entry.text("image").map { TopShelfStore.sized($0) },
            poster: entry.text("poster").map { TopShelfStore.sized($0, width: TopShelfStore.posterWidth) },
            positionMs: entry.number("positionMs") ?? 0,
            durationMs: entry.number("durationMs"),
            link: link
        )
    }
}
