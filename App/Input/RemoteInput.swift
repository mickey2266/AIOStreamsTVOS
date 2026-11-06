import UIKit

/**
 * The Siri Remote as the keys the web app reads from a TV's remote: the
 * clickpad's edges as arrows (held, they repeat), a swipe as one arrow, Select as Enter
 * (the page's hold actions work on a held Enter), Play/Pause as
 * `MediaPlayPause`. Back goes through the bridge, as on Android. Held for a
 * second, Play/Pause opens the app's own menu instead. Follows the working
 * aiostreams-tvos project's RootViewController.
 */
final class RemoteInput {
    var keyDown: (_ key: String, _ repeat: Bool) -> Void = { _, _ in }
    var keyUp: (_ key: String) -> Void = { _ in }
    var back: () -> Void = {}
    var menu: () -> Void = {}

    private var repeatTimer: Timer?
    private var repeating: String?
    private var menuHold: Timer?
    private var menuOpened = false
    private var swipeAnchor: CGPoint = .zero
    /// The swipe under way has already stepped.
    private var swipeStepped = false

    private static let menuHoldTime: TimeInterval = 1
    private static let repeatDelay: TimeInterval = 0.45
    private static let repeatEvery: TimeInterval = 0.11
    /// How far a swipe on the touch surface goes before it steps.
    private static let swipeStepX: CGFloat = 190
    private static let swipeStepY: CGFloat = 150

    func press(_ press: UIPress) {
        let began = press.phase == .began
        let ended = press.phase == .ended || press.phase == .cancelled
        guard began || ended else { return }

        switch press.type {
        case .menu:
            if began { back() }
        case .playPause:
            if began {
                menuOpened = false
                menuHold?.invalidate()
                menuHold = Timer.scheduledTimer(withTimeInterval: Self.menuHoldTime, repeats: false) { [weak self] _ in
                    self?.menuOpened = true
                    self?.menu()
                }
            } else {
                menuHold?.invalidate()
                menuHold = nil
                if !menuOpened { tap("MediaPlayPause") }
            }
        default:
            guard let key = Self.key(for: press.type) else { return }
            if began {
                keyDown(key, false)
                if key != "Enter" { startRepeating(key) }
            } else {
                stopRepeating()
                keyUp(key)
            }
        }
    }

    /**
     * A swipe on the touch surface steps once, as one press of an arrow does, however far or fast
     * it goes: the finger has to lift before the next swipe steps again.
     */
    func touches(_ touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        let at = touch.location(in: nil)
        switch touch.phase {
        case .began:
            swipeAnchor = at
            swipeStepped = false
        case .moved:
            guard !swipeStepped else { return }
            let dx = at.x - swipeAnchor.x
            let dy = at.y - swipeAnchor.y
            if abs(dx) >= Self.swipeStepX, abs(dx) > abs(dy) {
                swipeStepped = true
                tap(dx > 0 ? "ArrowRight" : "ArrowLeft")
            } else if abs(dy) >= Self.swipeStepY, abs(dy) > abs(dx) {
                swipeStepped = true
                tap(dy > 0 ? "ArrowDown" : "ArrowUp")
            }
        case .ended, .cancelled:
            swipeStepped = false
        default:
            break
        }
    }

    func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeating = nil
    }

    private func tap(_ key: String) {
        keyDown(key, false)
        keyUp(key)
    }

    private func startRepeating(_ key: String) {
        stopRepeating()
        repeating = key
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatEvery, repeats: true) { [weak self] _ in
                if let key = self?.repeating { self?.keyDown(key, true) }
            }
        }
    }

    private static func key(for type: UIPress.PressType) -> String? {
        switch type {
        case .upArrow: return "ArrowUp"
        case .downArrow: return "ArrowDown"
        case .leftArrow: return "ArrowLeft"
        case .rightArrow: return "ArrowRight"
        case .select: return "Enter"
        case .pageUp: return "PageUp"
        case .pageDown: return "PageDown"
        default: return nil
        }
    }
}
