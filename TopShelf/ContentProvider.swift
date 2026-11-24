import TVServices

/**
 * The Top Shelf over AIOStreams' icon on the home screen: Continue Watching
 * and Next Up, from the list the app saved when the page last sent it, or
 * one Continue Watching row where the page merges them, as its home page does.
 * Selecting a title opens its page in the app; Play plays it from where it
 * stopped. With nothing to show, tvOS shows the app's Top Shelf image.
 */
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        // The app writes a list, even an empty one, whenever the page sends it. With none where this
        // extension can read it (the app not opened since it was installed, or a signing that gave
        // the two no App Group in common), tvOS shows the Top Shelf image; the app menu lists the groups.
        // Off in the page's Top Shelf setting (patches/web/0104): the Top Shelf image, as with nothing to show.
        guard TopShelfStore.hasList, TopShelfStore.style != .off else {
            TopShelfStore.noteAsked(shown: 0)
            return completionHandler(nil)
        }
        let items = TopShelfStore.load()
        posters = TopShelfStore.style == .posters
        // The rows' titles in the page's language, as its home page words them.
        let text = TopShelfText.text(for: TopShelfStore.language)
        // With the page's "Merge Continue Watching and Next Up" on, one row in the home page's order.
        let sections = (TopShelfStore.merged
            ? [section(text.continueWatching, items)]
            : [
                section(text.continueWatching, items.filter(\.resumes)),
                section(text.nextUp, items.filter { !$0.resumes }),
            ]).compactMap { $0 }
        TopShelfStore.noteAsked(shown: sections.reduce(0) { $0 + $1.items.count })
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private func section(_ title: String, _ items: [TopShelfItem]) -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? {
        let shown = items.compactMap(shelfItem)
        guard !shown.isEmpty else { return nil }
        let section = TVTopShelfItemCollection(items: shown)
        section.title = title
        return section
    }

    /// The page's Top Shelf setting is posters: each title's movie or show poster, for those that have one.
    private var posters = false

    private func shelfItem(_ item: TopShelfItem) -> TVTopShelfSectionedItem? {
        guard let play = item.playURL else { return nil }
        let shelf = TVTopShelfSectionedItem(identifier: item.id)
        shelf.title = item.label
        // A title without a poster keeps its picture, in the poster's shape so the row lines up.
        let poster = posters ? item.poster : nil
        shelf.imageShape = posters ? .poster : .hdtv
        if let image = (poster ?? item.image).flatMap(URL.init(string:)) {
            shelf.setImageURL(image, for: .screenScale1x)
            shelf.setImageURL(image, for: .screenScale2x)
        }
        if let progress = item.progress { shelf.playbackProgress = progress }
        shelf.playAction = TVTopShelfAction(url: play)
        shelf.displayAction = TVTopShelfAction(url: item.detailsURL ?? play)
        return shelf
    }
}
