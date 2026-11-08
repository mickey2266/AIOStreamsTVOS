import UIKit

/**
 * tvOS's own search keyboard, shown over the page for one of the page's text
 * fields. Each change goes straight into the page's field, so a search's
 * results update while typing. Menu, or moving off the keyboard, closes it
 * and hands the remote back to the page.
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

        // Over the page, which shows through beside or below the keyboard. Faded in, as tvOS fades its
        // keyboard in, so the black box behind it comes with it rather than sliding up from below.
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        host.view.backgroundColor = .clear
        container.view.backgroundColor = .clear
        search.view.backgroundColor = .clear
        below.leave = { [weak host] in host?.dismiss(animated: true) }
        host.leave = { [weak host] in host?.dismiss(animated: true) }
        below.moved = { [weak container] in container?.view.setNeedsLayout() }
        container.disappeared = { [weak self] in self?.close() }
        // The keyboard setting changed since the last one: closed and opened again at once, laid out
        // for the keyboard tvOS draws now, without telling the page it closed.
        host.reopen = { [weak self, weak host] in
            guard let self, let host, let presenter = host.presentingViewController else { return }
            self.reopening = true
            host.dismiss(animated: false) {
                self.reopening = false
                presenter.present(host, animated: false)
            }
        }
    }

    private var reopening = false

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
        guard !closed, !reopening else { return }
        closed = true
        onClose(submitted)
    }
}

/**
 * Where the keyboard sits. tvOS lays its search keyboard out itself: the
 * linear one across the top of the screen, the grid one (Settings → General →
 * Keyboard) down the left, over the page's navigation and results. An app
 * can't place it, but it can give it a smaller space to lay out in, so the grid
 * keyboard gets a layout at the screen's top right, and tvOS draws it there (in
 * a window of its own). A black box behind it is measured around the keyboard
 * as drawn. The page shows to the left, and moving left off the keys returns to
 * it. The linear keyboard keeps the whole screen.
 *
 * Which keyboard tvOS drew is read from its views, as NuvioTVOS reads it: one
 * taller than 320 pt and narrower than 900 pt is the grid. The last one seen is
 * remembered, so the next keyboard opens in its place, and a change moves it.
 */
private final class KeyboardHost: UIViewController {
    var leave: () -> Void = {}

    /*
     * The grid keyboard's layout: the size it's laid out at, at the screen's top right, where tvOS
     * draws the keyboard (in a window of its own) 190 pt in from the layout's left. tvOS places the
     * keyboard again only when the layout's size changes, not when it moves, so the layout stays
     * put; the black box behind the keys is measured around the keyboard on the screen instead.
     */
    /// 720 rather than 640, so the search field's "Hold to dictate", which runs past the keys, has room.
    private static let gridLayoutLeft: CGFloat = 720
    private static let gridLayoutWidth: CGFloat = 840
    private static let gridHeight: CGFloat = 860
    /// Room around what tvOS draws, on each side and below.
    private static let gridMargin: CGFloat = 32
    /// tvOS's own margin from the screen's edge, inside which a TV shows all of the picture.
    private static let gridRightInset: CGFloat = 90
    /// How far the search field's "Hold to dictate" runs past the keyboard view's right edge.
    private static let hintOverhang: CGFloat = 56
    private static let gridKey = "keyboard.gridLayout.v7"
    private static let gridDrawnKey = "keyboard.gridDrawn.v7"

    private static var rememberedGrid: Bool {
        get { UserDefaults.standard.bool(forKey: gridKey) }
        set { UserDefaults.standard.set(newValue, forKey: gridKey) }
    }

    /// Where tvOS last drew the grid keyboard, so the next one's box opens there, with the keyboard.
    private static var rememberedDrawn: CGRect? {
        get {
            guard let text = UserDefaults.standard.string(forKey: gridDrawnKey) else { return nil }
            let rect = NSCoder.cgRect(for: text)
            return rect.width > 0 && rect.height > 0 ? rect : nil
        }
        set { UserDefaults.standard.set(newValue.map { NSCoder.string(for: $0) }, forKey: gridDrawnKey) }
    }

    /// What tvOS drew for the grid keyboard (the search field, its hint and the keys), on the screen.
    private var keys: CGRect? = KeyboardHost.rememberedGrid ? KeyboardHost.rememberedDrawn : nil

    /**
     * Called once when tvOS drew the other keyboard than the one laid out for (the setting changed
     * since the last one), to open the keyboard again laid out for it: reshaping the layout under an
     * open keyboard left it drawn wrong.
     */
    var reopen: () -> Void = {}
    private var reopened = false

    private let container: Container
    private let box = UIView()
    private let leftOfBox = FocusTrap()
    private var grid = KeyboardHost.rememberedGrid
    private var detectQueued = false
    private var focusWatch: NSObjectProtocol?

    init(container: Container) {
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
        box.layer.cornerRadius = 28
        box.backgroundColor = .black
        box.isUserInteractionEnabled = false
        box.isHidden = true
        leftOfBox.reached = { [weak self] in self?.leave() }
        view.addSubview(leftOfBox)
        view.addSubview(box)
        addChild(container)
        view.addSubview(container.view)
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
            // Always the same place and size, so tvOS keeps the keyboard where it was measured.
            let layout = CGRect(x: bounds.maxX - Self.gridRightInset - Self.gridLayoutLeft, y: 0,
                                width: Self.gridLayoutWidth, height: min(Self.gridHeight, bounds.height))
            container.view.frame = layout
            container.showsBackdrop = false
            if let keys {
                box.frame = CGRect(x: keys.minX - Self.gridMargin, y: 0,
                                   width: keys.width + 2 * Self.gridMargin,
                                   height: min(keys.maxY + Self.gridMargin, bounds.height))
                box.isHidden = false
            } else {
                box.isHidden = true
            }
            let left = box.isHidden ? layout.minX : box.frame.minX
            leftOfBox.frame = CGRect(x: 0, y: 0, width: max(0, left), height: bounds.height)
            leftOfBox.isHidden = false
        } else {
            container.view.frame = bounds
            container.showsBackdrop = true
            box.isHidden = true
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
        // Measured on the screen, in this view, which doesn't move: the box is placed in it.
        let screen: UIView = self.view
        func look(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else { return }
            if String(describing: type(of: view)).contains("Keyboard") {
                let size = view.bounds.size
                if size.height > 320, size.width > 200, size.width < 900 {
                    found = true
                    // tvOS draws the keyboard in a window of its own, so it's measured on the screen
                    // wherever it's drawn.
                    if size.width < narrowest {
                        narrowest = size.width
                        measuredKeys = view.convert(view.bounds, to: screen)
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
        let fromView = measuredKeys
        // The keyboard focus is on, where it's one of tvOS's keyboard views: the one that holds the keys.
        let focused = UIFocusSystem.focusSystem(for: layout)?.focusedItem
        var fromFocus: CGRect?
        if found, let keyboard = focused as? UIView, String(describing: type(of: keyboard)).contains("Keyboard") {
            let frame = keyboard.convert(keyboard.bounds, to: screen)
            if frame.height > 320, frame.width > 200, frame.width < 900 { fromFocus = frame }
        }
        if let fromFocus { measuredKeys = fromFocus }
        // The search field's row above the keys, its glyph, text and "Hold to dictate", which runs
        // past the keys' right edge and needs the box's room too.
        if found, let around = measuredKeys {
            var drawn = around
            func field(_ view: UIView, inField: Bool) {
                guard !view.isHidden, view.alpha > 0.01 else { return }
                let name = String(describing: type(of: view))
                let within = inField || name.contains("SearchBar") || name.contains("SearchField") ||
                    name.contains("TextField")
                if within, view is UILabel || view is UIImageView {
                    let frame = view.convert(view.bounds, to: screen)
                    if frame.width > 0, frame.height > 0, frame.maxY <= around.minY + 8,
                       frame.minX < screen.bounds.maxX, frame.maxX > around.minX - 120 {
                        drawn = drawn.union(frame)
                    }
                }
                for subview in view.subviews { field(subview, inField: within) }
            }
            for each in windows { field(each, inField: false) }
            // "Hold to dictate" ran about 50 pt past the keyboard view in the photos, where its label
            // isn't found; inside the screen, where a TV shows all of the picture.
            let right = min(max(drawn.maxX, around.maxX + Self.hintOverhang), screen.bounds.maxX - Self.gridMargin - 8)
            measuredKeys = CGRect(x: drawn.minX, y: drawn.minY, width: right - drawn.minX, height: drawn.height)
        }
        if found {
            KeyboardReport.record(
                layout: layout, fromView: fromView, fromFocus: fromFocus,
                used: measuredKeys, box: box.frame, focused: focused
            )
        }
        if found != grid {
            // Laid out for the other keyboard: opened again, once, laid out for this one.
            grid = found
            Self.rememberedGrid = found
            keys = found ? Self.rememberedDrawn : nil
            guard !reopened else { return place() }
            reopened = true
            place()
            reopen()
            return
        }
        // Only a keyboard on the screen places the box.
        guard found, let measuredKeys, measuredKeys.width > 0, measuredKeys.height > 0,
              screen.bounds.contains(CGPoint(x: measuredKeys.midX, y: measuredKeys.midY)) else { return }
        let rounded = measuredKeys.integral
        // A point or two either way is the same place.
        let same = keys.map {
            abs($0.minX - rounded.minX) <= 2 && abs($0.width - rounded.width) <= 2 &&
                abs($0.maxY - rounded.maxY) <= 2
        } ?? false
        guard !same else { return }
        let had = keys != nil
        keys = rounded
        Self.rememberedDrawn = rounded
        // A box already showing moves to it; one that wasn't shows where it is, with the keyboard.
        if had {
            UIView.animate(withDuration: 0.2) { self.place() }
        } else {
            UIView.performWithoutAnimation { self.place() }
        }
    }
}

/**
 * What the grid keyboard's box was last measured from, for the app menu (hold
 * Play/Pause): the measures tried, the one used, the box, the focused key, and
 * the views drawn at the keyboard's left, leftmost first. In points, in the
 * keyboard's layout, which the box shows from the measured left edge.
 */
enum KeyboardReport {
    private(set) static var lines: [String] = ["Grid keyboard: not measured since the app started"]

    private static func text(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "x %.0f, y %.0f, %.0f × %.0f", rect.minX, rect.minY, rect.width, rect.height)
    }

    fileprivate static func record(
        layout: UIView, fromView: CGRect?, fromFocus: CGRect?,
        used: CGRect?, box: CGRect, focused: UIFocusItem?
    ) {
        var out = [
            "Grid keyboard, last measured \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)):",
            "Layout: \(text(layout.frame)); box \(text(box)); both on screen, as the keyboard below",
            "Narrowest keyboard view: \(text(fromView))",
            "Focused keyboard view: \(text(fromFocus))",
            "Used: \(text(used))",
        ]
        if let focused {
            var frame = focused.frame
            if let view = focused as? UIView {
                frame = view.convert(view.bounds, to: layout)
            } else if let space = focused.parentFocusEnvironment?.focusItemContainer?.coordinateSpace {
                frame = space.convert(focused.frame, to: layout)
            }
            out.append("Focused: \(String(describing: type(of: focused))) \(text(frame))")
        }
        // The views at the keyboard's left, to see what starts where.
        var views: [(CGRect, String)] = []
        func look(_ view: UIView, depth: Int) {
            guard !view.isHidden, view.alpha > 0.01, depth < 40 else { return }
            if view !== layout {
                let frame = view.convert(view.bounds, to: layout)
                if frame.width >= 2, frame.height >= 2, frame.minY < 700 {
                    let name = String(describing: type(of: view))
                    views.append((frame, "\(name)\(view.subviews.isEmpty ? "" : " [\(view.subviews.count)]")"))
                }
            }
            for subview in view.subviews { look(subview, depth: depth + 1) }
        }
        look(layout, depth: 0)
        views.sort { $0.0.minX < $1.0.minX }
        out.append("Views, leftmost first (\(views.count)):")
        for (frame, name) in views.prefix(40) { out.append("  \(text(frame)) \(name)") }
        lines = out
        NSLog("[keyboard] %@", out.joined(separator: " | "))
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
    /// Off for the grid keyboard, whose box behind its keys is the host's.
    var showsBackdrop = true {
        didSet { backdrop.isHidden = !showsBackdrop }
    }
    private let backdrop = UIView()
    private let cutOut = CAShapeLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        // tvOS has no systemBackground; the app's dark style is black.
        backdrop.backgroundColor = .black
        backdrop.isUserInteractionEnabled = false
        backdrop.isHidden = !showsBackdrop
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
