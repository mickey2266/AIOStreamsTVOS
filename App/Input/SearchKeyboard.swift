import UIKit

/**
 * tvOS's own search keyboard, shown over the page for one of the page's text
 * fields. Each change goes straight into the page's field, so a search's
 * results update while typing. Menu, or moving down off the keyboard, closes
 * it and hands the remote back to the page.
 */
final class SearchKeyboard: NSObject, UISearchResultsUpdating, UISearchBarDelegate {
    /// What to present.
    let controller: UIViewController
    private let search: UISearchController
    private var text: String
    private var submitted = false
    private var closed = false
    private let onChange: (String) -> Void
    private let onClose: (_ submit: Bool) -> Void

    init(
        text: String,
        prompt: String,
        keyboardType: UIKeyboardType,
        onChange: @escaping (String) -> Void,
        onClose: @escaping (_ submit: Bool) -> Void
    ) {
        self.text = text
        self.onChange = onChange
        self.onClose = onClose
        let below = BelowKeyboard()
        search = UISearchController(searchResultsController: below)
        let container = Container(searchController: search)
        let host = KeyboardHost(container: container)
        controller = host
        super.init()

        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        let bar = search.searchBar
        bar.delegate = self
        bar.text = text
        bar.placeholder = prompt
        bar.keyboardType = keyboardType
        bar.autocorrectionType = .no
        bar.autocapitalizationType = .none

        // Over the page, which shows through beside or below the keyboard.
        host.modalPresentationStyle = .overFullScreen
        host.view.backgroundColor = .clear
        container.view.backgroundColor = .clear
        search.view.backgroundColor = .clear
        below.leave = { [weak host] in host?.dismiss(animated: true) }
        host.leave = { [weak host] in host?.dismiss(animated: true) }
        below.moved = { [weak container] in container?.view.setNeedsLayout() }
        container.disappeared = { [weak self] in self?.close() }
    }

    // MARK: UISearchResultsUpdating

    func updateSearchResults(for searchController: UISearchController) {
        let now = searchController.searchBar.text ?? ""
        guard now != text else { return }
        text = now
        onChange(now)
    }

    // MARK: UISearchBarDelegate

    /// A keyboard's return key, where there is one.
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submitted = true
        controller.dismiss(animated: true)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        onClose(submitted)
    }
}

/**
 * Where the keyboard sits. tvOS lays its search keyboard out itself: the
 * linear one across the top of the screen, the grid one (Settings → General →
 * Keyboard) down the left, over the page's navigation and results. An app
 * can't place it, but it can give it a smaller space to lay out in, so the grid
 * keyboard gets a box at the screen's top right: its keys' width, clipped from a
 * wider layout as tvOS lays the search field out across it (as NuvioTVOS hosts
 * it). The page shows to the left, and moving left off the keys returns to it.
 *
 * Which keyboard tvOS drew is read from its views, as NuvioTVOS reads it: one
 * taller than 320 pt and narrower than 900 pt is the grid. The last one seen is
 * remembered, so the next keyboard opens in its place, and a change moves it.
 */
private final class KeyboardHost: UIViewController {
    var leave: () -> Void = {}

    /*
     * The grid keyboard's box: as wide and tall as the keyboard tvOS draws, read from its view once
     * it's laid out, plus a margin. NuvioTVOS's 520 pt clipped this one's last column of keys, so
     * 640 is the first guess until a keyboard has been measured; the measure is remembered.
     */
    private static let gridFirstWidth: CGFloat = 640
    private static let gridMinWidth: CGFloat = 360
    private static let gridMaxWidth: CGFloat = 960
    private static let gridLayoutWidth: CGFloat = 840
    private static let gridHeight: CGFloat = 860
    /// Room around the keys, on each side.
    private static let gridMargin: CGFloat = 32
    /// tvOS's own margin from the screen's edge, inside which a TV shows all of the picture.
    private static let gridRightInset: CGFloat = 90
    private static let gridKey = "keyboard.gridLayout"
    private static let gridLeftKey = "keyboard.gridLeft"
    private static let gridWidthKey = "keyboard.gridKeysWidth"
    private static let gridHeightKey = "keyboard.gridHeight"

    private static var rememberedGrid: Bool {
        get { UserDefaults.standard.bool(forKey: gridKey) }
        set { UserDefaults.standard.set(newValue, forKey: gridKey) }
    }

    /**
     * Where the keys sit in the layout, as measured: from their left edge across their width, and
     * down to their bottom. tvOS lays them out some way in from the layout's left, which the box
     * leaves out by moving the layout left by as much.
     */
    private static var rememberedKeys: CGRect? {
        get {
            let defaults = UserDefaults.standard
            let width = defaults.double(forKey: gridWidthKey)
            let height = defaults.double(forKey: gridHeightKey)
            guard width > 0, height > 0 else { return nil }
            return CGRect(x: defaults.double(forKey: gridLeftKey), y: 0, width: width, height: height)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Double(newValue?.minX ?? 0), forKey: gridLeftKey)
            defaults.set(Double(newValue?.width ?? 0), forKey: gridWidthKey)
            defaults.set(Double(newValue?.maxY ?? 0), forKey: gridHeightKey)
        }
    }

    private var keys = KeyboardHost.rememberedKeys

    private let container: UIViewController
    private let box = UIView()
    private let leftOfBox = FocusTrap()
    private var grid = KeyboardHost.rememberedGrid
    private var detectQueued = false
    private var focusWatch: NSObjectProtocol?

    init(container: UIViewController) {
        self.container = container
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    deinit {
        if let focusWatch { NotificationCenter.default.removeObserver(focusWatch) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        box.clipsToBounds = true
        box.layer.cornerRadius = 28
        leftOfBox.reached = { [weak self] in self?.leave() }
        view.addSubview(leftOfBox)
        view.addSubview(box)
        addChild(container)
        box.addSubview(container.view)
        container.didMove(toParent: self)
        // Focus moving is when tvOS has the keyboard laid out, and when it may have swapped it.
        focusWatch = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.detectSoon() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        place()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for delay in [0.0, 0.1, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.detectSoon() }
        }
        // Only once the keyboard has taken focus, so it can't land here as the keyboard opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.leftOfBox.armed = true }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        leftOfBox.armed = false
    }

    private func place() {
        let bounds = view.bounds
        if grid {
            let measured = keys.map { $0.width + 2 * Self.gridMargin } ?? Self.gridFirstWidth
            let width = min(max(measured, Self.gridMinWidth), Self.gridMaxWidth)
            let tall = keys.map { $0.maxY + Self.gridMargin } ?? Self.gridHeight
            box.frame = CGRect(x: bounds.maxX - Self.gridRightInset - width, y: 0,
                               width: width, height: min(tall, bounds.height))
            box.backgroundColor = .black
            // Always laid out the same width, so the keys stay where they were measured; moved left
            // by the space tvOS leaves before them, less the box's margin.
            let shift = keys.map { Self.gridMargin - $0.minX } ?? 0
            container.view.frame = CGRect(x: shift, y: 0, width: Self.gridLayoutWidth,
                                          height: min(Self.gridHeight, bounds.height))
            leftOfBox.frame = CGRect(x: 0, y: 0, width: box.frame.minX, height: bounds.height)
            leftOfBox.isHidden = false
        } else {
            box.frame = bounds
            box.backgroundColor = .clear
            container.view.frame = box.bounds
            leftOfBox.isHidden = true
        }
    }

    private func detectSoon() {
        guard !detectQueued else { return }
        detectQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detectQueued = false
            self.detect()
        }
    }

    /// Which keyboard tvOS drew, and the box moved when it isn't the one placed for.
    private func detect() {
        guard let window = view.window, presentingViewController != nil else { return }
        var found: Bool?
        /*
         * Where the grid keyboard's keys sit in the layout, from the narrowest of its tall views: the
         * keys themselves, rather than a view around them that may run the layout's whole width.
         */
        var measuredKeys: CGRect?
        var narrowest = CGFloat.infinity
        let layout: UIView = container.view
        func look(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else { return }
            if String(describing: type(of: view)).contains("Keyboard") {
                let size = view.bounds.size
                if size.height > 320, size.width > 200, size.width < 900 {
                    found = true
                    // Only a keyboard drawn in the layout itself measures the box.
                    if view.isDescendant(of: layout), size.width < narrowest {
                        narrowest = size.width
                        measuredKeys = view.convert(view.bounds, to: layout)
                    }
                } else if found == nil, size.width > 400, size.height > 40, size.height <= 320 {
                    found = false
                }
            }
            for subview in view.subviews { look(subview) }
        }
        // The keyboard may be drawn in a window of its own.
        let windows = window.windowScene?.windows ?? [window]
        for each in windows { look(each) }
        guard let found else { return }
        var changed = found != grid
        if found, let measuredKeys, measuredKeys.width > 0, measuredKeys.maxY > 0 {
            let rounded = CGRect(x: measuredKeys.minX.rounded(.down), y: 0,
                                 width: measuredKeys.width.rounded(.up), height: measuredKeys.maxY.rounded(.up))
            if rounded != keys {
                keys = rounded
                Self.rememberedKeys = rounded
                changed = true
            }
        }
        guard changed else { return }
        grid = found
        Self.rememberedGrid = found
        UIView.animate(withDuration: 0.2) {
            self.place()
            self.container.view.layoutIfNeeded()
        }
    }
}

/**
 * Reports when it goes, however it was closed: Menu, moving off the keyboard,
 * or return. Draws a solid backdrop behind the keyboard, so the page doesn't
 * show through its keys; the page still shows where tvOS puts the results.
 * With the linear keyboard that's below it; with the grid keyboard (Settings →
 * General → Keyboard), beside it, and the backdrop then covers the keyboard's
 * column down the whole screen as well as the strip above.
 */
private final class Container: UISearchContainerViewController {
    var disappeared: () -> Void = {}
    private let backdrop = UIView()
    private let cutOut = CAShapeLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        // tvOS has no systemBackground; the app's dark style is black.
        backdrop.backgroundColor = .black
        backdrop.isUserInteractionEnabled = false
        cutOut.fillRule = .evenOdd
        view.insertSubview(backdrop, at: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.sendSubviewToBack(backdrop)
        backdrop.frame = view.bounds
        // The whole screen, less the results' space once tvOS shows it, wherever it puts it.
        guard let below = searchController.searchResultsController?.view, below.window != nil,
              !below.isHidden, below.alpha > 0 else {
            backdrop.layer.mask = nil
            return
        }
        let results = below.convert(below.bounds, to: view).intersection(view.bounds)
        // Nothing left to show the keyboard over: leave the screen covered.
        guard !results.isNull, !results.isEmpty, results != view.bounds else {
            backdrop.layer.mask = nil
            return
        }
        let path = UIBezierPath(rect: view.bounds)
        path.append(UIBezierPath(rect: results))
        cutOut.frame = view.bounds
        cutOut.path = path.cgPath
        backdrop.layer.mask = cutOut
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        disappeared()
    }
}

/**
 * The space below the keyboard: see-through, so the page's results show,
 * and one focus target across it. Moving down onto it leaves the keyboard
 * for the page, as moving to the results does in tvOS's own search.
 */
private final class BelowKeyboard: UIViewController {
    var leave: () -> Void = {}
    private let trap = FocusTrap()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        trap.frame = view.bounds
        trap.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        trap.reached = { [weak self] in self?.leave() }
        view.addSubview(trap)
    }

    /// Where it sits changed, so the backdrop above it follows.
    var moved: () -> Void = {}

    private var placed: CGRect?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Only when it really moved, so the two layouts can't keep starting each other.
        let now = view.convert(view.bounds, to: nil)
        guard now != placed else { return }
        placed = now
        moved()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        placed = nil
        moved()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        moved()
        // Only once the keyboard has taken focus, so it can't land here as the keyboard opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.trap.armed = true }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        trap.armed = false
    }
}

private final class FocusTrap: UIView {
    var reached: () -> Void = {}
    var armed = false

    override var canBecomeFocused: Bool { armed }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self { reached() }
    }
}
