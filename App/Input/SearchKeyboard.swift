import UIKit

/**
 * tvOS's own search keyboard, shown over the page for one of the page's text
 * fields, in a panel at the bottom of the screen, centred. Each change goes
 * straight into the page's field, so a search's results update while typing.
 * Menu closes it and hands the remote back to the page.
 */
final class SearchKeyboard: NSObject, UISearchResultsUpdating, UISearchBarDelegate, UIViewControllerTransitioningDelegate {
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
        controller = container
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

        // In a panel of its own over the page, which shows around it.
        container.modalPresentationStyle = .custom
        container.transitioningDelegate = self
        container.view.backgroundColor = .clear
        search.view.backgroundColor = .clear
        below.leave = { [weak container] in container?.dismiss(animated: true) }
        below.moved = { [weak container] in container?.view.setNeedsLayout() }
        container.disappeared = { [weak self] in self?.close() }
    }

    // MARK: UIViewControllerTransitioningDelegate

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        let panel = BottomPanel(presentedViewController: presented, presenting: presenting)
        (presented as? Container)?.panel = panel
        return panel
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
 * Where the keyboard goes: the whole screen while tvOS lays it out the first
 * time, unseen, then a panel the keyboard's own size, at the bottom of the
 * screen and centred. tvOS has no setting for where its keyboard goes, so the
 * panel is cut to what it drew: the linear keyboard's strip, its height and
 * half the screen's width, a little above the bottom edge; the grid
 * keyboard's column (Settings → General → Keyboard), its width, from top to
 * bottom.
 */
private final class BottomPanel: UIPresentationController {
    /// Nil while tvOS lays the keyboard out over the whole screen.
    private(set) var size: CGSize?
    var margin: CGFloat = 0

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let bounds = containerView?.bounds else { return .zero }
        guard let size else { return bounds }
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height - margin)
        return CGRect(x: bounds.midX - width / 2, y: bounds.maxY - margin - height, width: width, height: height)
    }

    override var shouldRemovePresentersView: Bool { false }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    func place(_ size: CGSize, margin: CGFloat) {
        self.size = size
        self.margin = margin
        presentedView?.frame = frameOfPresentedViewInContainerView
        containerView?.setNeedsLayout()
    }
}

/**
 * Reports when it goes, however it was closed: Menu or return. Draws a solid
 * backdrop behind the keyboard, so the page doesn't show through its keys,
 * and measures where tvOS put the keyboard to cut its panel to it.
 */
private final class Container: UISearchContainerViewController {
    var disappeared: () -> Void = {}
    weak var panel: BottomPanel?
    private let backdrop = UIView()
    /// Measured once; the panel then keeps its size until the keyboard closes.
    private var placed = false

    /// The linear keyboard's panel, as wide as half the screen.
    private static let stripShare: CGFloat = 0.5
    /// Room between the linear keyboard's panel and the screen's bottom edge.
    private static let stripMargin: CGFloat = 40

    override func viewDidLoad() {
        super.viewDidLoad()
        // tvOS has no systemBackground; the app's dark style is black.
        backdrop.backgroundColor = .black
        backdrop.isUserInteractionEnabled = false
        view.insertSubview(backdrop, at: 0)
        view.layer.cornerRadius = 24
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        // All but unseen until it has its panel, so the full-screen layout it's measured in doesn't
        // show; not 0, which would leave focus nothing to land on as the keyboard opens.
        view.alpha = 0.01
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Nothing to measure: shown where tvOS put it, over the whole screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.placed else { return }
            self.placed = true
            self.show()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.sendSubviewToBack(backdrop)
        backdrop.frame = view.bounds
        guard !placed, let panel, panel.size == nil else { return }
        guard let below = searchController.searchResultsController?.view, below.window != nil,
              !below.isHidden else { return }
        let bounds = view.bounds
        let results = below.convert(below.bounds, to: view).intersection(bounds)
        guard !results.isNull, !results.isEmpty, results != bounds else { return }
        let size: CGSize
        let margin: CGFloat
        if results.minY > 1, results.minX < 1 {
            // Linear: the strip above the results.
            size = CGSize(width: (bounds.width * Self.stripShare).rounded(), height: results.minY.rounded(.up))
            margin = Self.stripMargin
        } else if results.minX > 1 {
            // Grid: the column beside the results.
            size = CGSize(width: results.minX.rounded(.up), height: bounds.height)
            margin = 0
        } else {
            return
        }
        placed = true
        panel.place(size, margin: margin)
        show()
    }

    private func show() {
        UIView.animate(withDuration: 0.2) { self.view.alpha = 1 }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        disappeared()
    }
}

/**
 * The space tvOS keeps for results: see-through and empty, as the page's own
 * results show behind the panel. It reports where it lies, which the panel is
 * measured from.
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

    /// Where it sits changed, so the panel's measuring runs again.
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
