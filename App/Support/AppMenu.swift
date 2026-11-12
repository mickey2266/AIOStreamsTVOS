import UIKit

/**
 * The app's own menu (hold Play/Pause): what the app knows about the video,
 * and its memory, in a panel the remote scrolls, beside the
 * menu's actions. An action sheet cuts off a message it can't fit, so this is
 * a screen of its own. Menu closes it, as it does an action sheet.
 */
final class AppMenu: UIViewController {
    struct Action {
        let title: String
        let destructive: Bool
        /// Runs once the menu has closed.
        let run: () -> Void
    }

    /// The menu has closed, however it was.
    var closed: () -> Void = {}

    private let heading: String
    private let text: String
    private let actions: [Action]
    private var buttons: [UIButton] = []

    init(title: String, text: String, actions: [Action]) {
        heading = title
        self.text = text
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.7)

        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0.1, alpha: 0.96)
        panel.layer.cornerRadius = 28
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let title = UILabel()
        title.text = heading
        title.font = .systemFont(ofSize: 48, weight: .bold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)

        let details = ScrollingText()
        details.text = text
        details.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(details)

        let hint = UILabel()
        hint.text = "Swipe up and down on the details to scroll them"
        hint.font = .systemFont(ofSize: 22)
        hint.textColor = UIColor(white: 0.6, alpha: 1)
        hint.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(hint)

        buttons = actions.enumerated().map { index, action in
            let button = UIButton(type: .system)
            button.setTitle(action.title, for: .normal)
            if action.destructive { button.setTitleColor(.systemRed, for: .normal) }
            button.tag = index
            button.addTarget(self, action: #selector(chose(_:)), for: .primaryActionTriggered)
            return button
        }
        let column = UIStackView(arrangedSubviews: buttons)
        column.axis = .vertical
        column.spacing = 24
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 120),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -120),
            panel.topAnchor.constraint(equalTo: view.topAnchor, constant: 90),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -90),

            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 60),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 48),

            details.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 48),
            details.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 28),
            details.trailingAnchor.constraint(equalTo: column.leadingAnchor, constant: -60),
            details.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -16),

            hint.leadingAnchor.constraint(equalTo: details.leadingAnchor, constant: 12),
            hint.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -32),

            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -60),
            column.topAnchor.constraint(equalTo: details.topAnchor),
            column.widthAnchor.constraint(equalToConstant: 460),
        ])
    }

    /// The first action, as an action sheet does; moving left reaches the details.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        buttons.first.map { [$0] } ?? super.preferredFocusEnvironments
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        closed()
    }

    @objc private func chose(_ button: UIButton) {
        let action = actions[button.tag]
        dismiss(animated: true, completion: action.run)
    }
}

/**
 * Text the remote scrolls: it takes focus, swipes on the touch surface pan
 * it, and clicks up and down move it most of a screen.
 */
private final class ScrollingText: UITextView {
    init() {
        super.init(frame: .zero, textContainer: nil)
        // tvOS text views are never editable, so there's no `isEditable` to turn off.
        isSelectable = false
        isScrollEnabled = true
        isUserInteractionEnabled = true
        // The touch surface's swipes, which are indirect touches.
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        showsVerticalScrollIndicator = true
        indicatorStyle = .white
        backgroundColor = UIColor(white: 1, alpha: 0.06)
        textColor = UIColor(white: 0.92, alpha: 1)
        font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        textContainerInset = UIEdgeInsets(top: 20, left: 12, bottom: 20, right: 12)
        layer.cornerRadius = 16
        layer.borderWidth = 3
        layer.borderColor = UIColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { [self] in
            layer.borderColor = (isFocused ? UIColor.white : UIColor.clear).cgColor
            backgroundColor = UIColor(white: 1, alpha: isFocused ? 0.12 : 0.06)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isFocused, let press = presses.first(where: { $0.type == .upArrow || $0.type == .downArrow }) else {
            return super.pressesBegan(presses, with: event)
        }
        let step = bounds.height * 0.7 * (press.type == .upArrow ? -1 : 1)
        let lowest = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let y = min(max(contentOffset.y + step, -adjustedContentInset.top), lowest)
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: true)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // The clicks it scrolled with go no further, so focus stays here.
        if isFocused, presses.contains(where: { $0.type == .upArrow || $0.type == .downArrow }) { return }
        super.pressesEnded(presses, with: event)
    }
}
