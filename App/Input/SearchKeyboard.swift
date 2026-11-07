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
    /// Kept while the keyboard shows: what it presents doesn't keep its transitioning delegate.
    private let panel = RightPanel()
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

        // A panel over the screen's right half, the page in view to its left.
        container.modalPresentationStyle = .custom
        container.transitioningDelegate = panel
        container.view.backgroundColor = UIColor(white: 0.06, alpha: 0.85)
        search.view.backgroundColor = .clear
        below.leave = { [weak container] in container?.dismiss(animated: true) }
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
 * The keyboard as a panel over the screen's right half, linear and grid alike,
 * with the page in view to its left: tvOS lays its keyboard out across
 * whatever space it's given, so the panel's frame places it, as the
 * aiostreams-tvos project presents it. The page isn't drawn over, so nothing
 * shows through the keys.
 */
private final class RightPanel: NSObject, UIViewControllerTransitioningDelegate {
    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        RightPanelPresentation(presentedViewController: presented, presenting: presenting)
    }
}

private final class RightPanelPresentation: UIPresentationController {
    override var frameOfPresentedViewInContainerView: CGRect {
        guard let bounds = containerView?.bounds else { return .zero }
        let width = (bounds.width / 2).rounded(.down)
        return CGRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
    }

    // The page stays on screen beside the panel.
    override var shouldRemovePresentersView: Bool { false }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
}

/** Reports when it goes, however it was closed: Menu, moving off the keyboard, or return. */
private final class Container: UISearchContainerViewController {
    var disappeared: () -> Void = {}

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        disappeared()
    }
}

/**
 * The panel's space for results, wherever tvOS puts it: one focus target
 * across it. Moving onto it leaves the keyboard for the page, as moving to
 * the results does in tvOS's own search.
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
