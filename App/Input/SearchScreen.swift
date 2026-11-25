import UIKit

/**
 * The Search page's keyboard as tvOS's own search screen has it (patches/web/0105): tvOS's search
 * keyboard in the page's place, rather than over the page, kept there while the page shows. tvOS lays
 * it out in the space it's given, the page's own beside the navigation: the linear keyboard across the
 * top, the grid one (Settings → General → Keyboard) down the left, with the field and "Hold to dictate"
 * above either, and the space it keeps for results below or beside the keys. The page draws its chips
 * and results there (`resultsMoved`), so the keyboard stays on screen, dimmed, while focus is on them.
 *
 * Focus moves as on tvOS. Off the keys onto the results' space, or past the keyboard's edges, the page
 * takes the remote (`left`); back as the page's focus reaches the keyboard's space (`focusKeys`, from the
 * host). What's typed goes straight into the page's field (`onChange`), and a term the page puts there
 * itself, a chip's, onto the keyboard's field (`setText`).
 */
@MainActor
final class SearchScreen: NSObject, UISearchResultsUpdating {
    /// What to embed in the page's place.
    let controller: UIViewController
    private let search: UISearchController
    private let container: EmbeddedSearch
    private let results: ResultsSpace
    private var text: String
    private let onChange: (String) -> Void

    /// Focus went off the keys that way (`ArrowDown`, `ArrowRight`, `ArrowLeft` or `ArrowUp`).
    var left: (String) -> Void = { _ in }
    /// Where tvOS keeps the results, in points from the screen's corner: `grid` when beside the keys.
    var resultsMoved: (_ grid: Bool, _ area: CGRect) -> Void = { _, _ in }

    init(text: String, prompt: String, onChange: @escaping (String) -> Void) {
        self.text = text
        self.onChange = onChange
        results = ResultsSpace()
        search = UISearchController(searchResultsController: results)
        container = EmbeddedSearch(searchController: search)
        controller = container
        super.init()
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        // The results' space shows before anything is typed too, so the page's chips have it.
        search.showsSearchResultsController = true
        let bar = search.searchBar
        bar.text = text
        bar.placeholder = prompt
        bar.keyboardType = .default
        bar.returnKeyType = .search
        bar.autocorrectionType = .no
        bar.autocapitalizationType = .none
        container.view.backgroundColor = .clear
        search.view.backgroundColor = .clear
        results.reached = { [weak self] in
            guard let self else { return }
            self.left(self.grid ? "ArrowRight" : "ArrowDown")
        }
        results.moved = { [weak self] in self?.measure() }
        container.laidOut = { [weak self] in self?.measure() }
    }

    /// The results sit beside the keys rather than below them: the grid keyboard.
    private(set) var grid = SearchScreen.rememberedGrid

    /// The page's field changed on its own, a chip's term: onto the keyboard's, without going back to the page.
    func setText(_ value: String) {
        guard value != text else { return }
        text = value
        search.searchBar.text = value
    }

    /// Traps around the keyboard's space, in the host's view: past its edges, focus goes back to the page.
    func placeTraps(in host: UIView, around frame: CGRect) {
        for trap in traps { trap.removeFromSuperview() }
        let bounds = host.bounds
        let sides: [(CGRect, String)] = [
            (CGRect(x: 0, y: 0, width: max(0, frame.minX), height: bounds.height), "ArrowLeft"),
            (CGRect(x: frame.maxX, y: 0, width: max(0, bounds.maxX - frame.maxX), height: bounds.height), "ArrowRight"),
            (CGRect(x: frame.minX, y: 0, width: frame.width, height: max(0, frame.minY)), "ArrowUp"),
        ]
        traps = sides.compactMap { rect, key in
            guard rect.width > 1, rect.height > 1 else { return nil }
            let trap = FocusTrap(frame: rect)
            trap.armed = true
            trap.reached = { [weak self] in self?.left(key) }
            host.addSubview(trap)
            return trap
        }
    }

    private var traps: [FocusTrap] = []

    /// The screen is going: its traps with it.
    func removeTraps() {
        for trap in traps { trap.removeFromSuperview() }
        traps = []
    }

    // MARK: UISearchResultsUpdating

    func updateSearchResults(for searchController: UISearchController) {
        let now = searchController.searchBar.text ?? ""
        guard now != text else { return }
        text = now
        onChange(now)
    }

    // MARK: Layout

    private static let gridKey = "searchScreen.grid.v1"
    private static let areaKey = "searchScreen.results.v1"

    private static var rememberedGrid: Bool {
        get { UserDefaults.standard.bool(forKey: gridKey) }
        set { UserDefaults.standard.set(newValue, forKey: gridKey) }
    }

    /// Where the results sat last time, from the keyboard's corner, so the page opens laid out for it.
    static var rememberedArea: CGPoint? {
        guard let text = UserDefaults.standard.string(forKey: areaKey) else { return nil }
        let point = NSCoder.cgPoint(for: text)
        return point.x >= 0 && point.y > 0 ? point : nil
    }

    private var lastArea: CGRect?

    /**
     * Where tvOS put the results' space, which says which keyboard it drew: beside the keys (more than a
     * quarter of the width in) is the grid's, below them the linear one's. Sent on as it changes.
     */
    private func measure() {
        guard let screen = container.view.window, results.view.window != nil, !results.view.isHidden else { return }
        let area = results.view.convert(results.view.bounds, to: screen).integral
        let frame = container.view.convert(container.view.bounds, to: screen)
        guard area.width > 100, area.height > 100, frame.width > 0 else { return }
        guard area != lastArea else { return }
        lastArea = area
        grid = area.minX - frame.minX > frame.width / 4
        Self.rememberedGrid = grid
        UserDefaults.standard.set(
            NSCoder.string(for: CGPoint(x: area.minX - frame.minX, y: area.minY - frame.minY)), forKey: Self.areaKey)
        resultsMoved(grid, area)
    }
}

/// The container, which says when it has laid out, as tvOS places the keyboard and the results' space then.
private final class EmbeddedSearch: UISearchContainerViewController {
    var laidOut: () -> Void = {}

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        DispatchQueue.main.async { [weak self] in self?.laidOut() }
    }
}

/**
 * Where tvOS keeps the search's results: see-through, so the page's chips and results beneath show, with
 * one focus target across it. Focus moving onto it from the keys hands the remote to the page.
 */
private final class ResultsSpace: UIViewController {
    var reached: () -> Void = {}
    var moved: () -> Void = {}
    let trap = FocusTrap()
    private var placed: CGRect?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        trap.frame = view.bounds
        trap.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        trap.reached = { [weak self] in self?.reached() }
        // Where UIKit's focus waits while the page has the remote; reaching it from the page counts for nothing.
        trap.armed = true
        view.addSubview(trap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let now = view.convert(view.bounds, to: nil)
        guard now != placed else { return }
        placed = now
        moved()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        moved()
    }
}
