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
    /// The touch the anchor belongs to, so a touch whose start was missed anchors where it's first seen.
    private var swipeTouch: ObjectIdentifier?
    /// The swipe under way has already stepped.
    private var swipeStepped = false
    /// A finger is on the touch surface, and whether it has moved far enough to be a swipe.
    private var touchDown = false
    private var touchSwiping = false
    /// When the last swipe's finger lifted.
    private var swipeEndedAt: TimeInterval = 0

    /*
     * The clickpad reports a touch near its edge as an arrow press too (Click and Touch), so a
     * swipe that starts or ends near an edge came with an arrow of its own: a swipe down from the
     * top edge sent Up as well as the swipe's Down, and focus went one row and straight back. An
     * arrow pressed while a finger is on the surface waits `pressSettle` before it counts; if the
     * finger turns it into a swipe in that time, or it comes during a swipe or just after one, the
     * swipe alone counts. A click with the finger at rest still steps and repeats as before.
     */
    private var pending: (type: UIPress.PressType, key: String)?
    private var pendingTimer: Timer?
    /// Arrow presses dropped as part of a swipe, whose ends are dropped too.
    private var dropped: Set<UIPress.PressType> = []
    private static let pressSettle: TimeInterval = 0.12
    /// Movement past which a finger on the surface is a swipe, well short of a step.
    private static let swipeIntent: CGFloat = 40
    /// How long after a swipe's finger lifts an arrow press still counts as part of it.
    private static let swipeAfterglow: TimeInterval = 0.2

    private static let menuHoldTime: TimeInterval = 1
    private static let repeatDelay: TimeInterval = 0.45
    private static let repeatEvery: TimeInterval = 0.11
    /// How far a swipe on the touch surface goes before it steps.
    private static let swipeStepX: CGFloat = 190
    private static let swipeStepY: CGFloat = 150

    /// Presses that began here and haven't ended, whose ends come here too (`owns`).
    private var down: Set<UIPress.PressType> = []

    /**
     * Whether this press began here. Its end still belongs here when something has opened over the
     * page since (Up from a searchable list's top entry opens the search keyboard while Up is still
     * held): it lets the page's key go, and the screen on top never sees the end of a press it
     * didn't see begin.
     */
    func owns(_ press: UIPress) -> Bool { down.contains(press.type) }

    /// The app is leaving the screen, where the presses down now will end unseen.
    func forgetPresses() {
        down.removeAll()
        dropped.removeAll()
        clearPending()
    }

    /**
     * Something is opening over the page: a held arrow stops repeating into the page under it, and
     * one still waiting to settle is dropped. Touches stop coming here, so the finger counts as up.
     */
    func interrupt() {
        stopRepeating()
        if let held = pending {
            clearPending()
            dropped.insert(held.type)
        }
        touchDown = false
        touchSwiping = false
        swipeStepped = false
        swipeTouch = nil
    }

    func press(_ press: UIPress) {
        let began = press.phase == .began
        let ended = press.phase == .ended || press.phase == .cancelled
        guard began || ended else { return }
        if began { down.insert(press.type) } else { down.remove(press.type) }

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
            let arrow = Self.isArrow(press.type)
            if began {
                if arrow, partOfSwipe {
                    dropped.insert(press.type)
                    return
                }
                // A dropped press whose end never came mustn't swallow this one's.
                dropped.remove(press.type)
                if arrow, touchDown {
                    holdPending(press.type, key)
                    return
                }
                keyDown(key, false)
                if key != "Enter" { startRepeating(key) }
            } else {
                if dropped.remove(press.type) != nil { return }
                if let held = pending, held.type == press.type {
                    // Let go before it settled: a quick click, which steps once.
                    clearPending()
                    tap(key)
                    return
                }
                stopRepeating()
                keyUp(key)
            }
        }
    }

    /// A swipe is under way, or one just ended.
    private var partOfSwipe: Bool {
        touchSwiping || ProcessInfo.processInfo.systemUptime - swipeEndedAt < Self.swipeAfterglow
    }

    private func holdPending(_ type: UIPress.PressType, _ key: String) {
        clearPending()
        pending = (type, key)
        pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.pressSettle, repeats: false) { [weak self] _ in
            guard let self, let held = self.pending else { return }
            self.clearPending()
            self.keyDown(held.key, false)
            self.startRepeating(held.key)
        }
    }

    private func clearPending() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        pending = nil
    }

    /// The finger turned out to be swiping: an arrow still waiting is the swipe's, not a click.
    private func swipeStarted() {
        touchSwiping = true
        if let held = pending {
            clearPending()
            dropped.insert(held.type)
        }
    }

    /**
     * A swipe on the touch surface steps once, as one press of an arrow does, however far or fast
     * it goes: the finger has to lift before the next swipe steps again.
     */
    func touches(_ touches: Set<UITouch>) {
        // Of the touches in the event, the one still on the surface, if any.
        guard let touch = touches.first(where: { $0.phase != .ended && $0.phase != .cancelled }) ?? touches.first
        else { return }
        let at = touch.location(in: nil)
        let id = ObjectIdentifier(touch)
        switch touch.phase {
        case .began:
            startTouch(id, at)
        case .moved, .stationary:
            // A touch whose start wasn't seen is measured from where it's first seen, not from
            // where the last swipe began, which could read as the opposite direction.
            if swipeTouch != id { startTouch(id, at) }
            let dx = at.x - swipeAnchor.x
            let dy = at.y - swipeAnchor.y
            if !touchSwiping, max(abs(dx), abs(dy)) >= Self.swipeIntent { swipeStarted() }
            guard !swipeStepped else { return }
            if abs(dx) >= Self.swipeStepX, abs(dx) > abs(dy) {
                swipeStepped = true
                tap(dx > 0 ? "ArrowRight" : "ArrowLeft")
            } else if abs(dy) >= Self.swipeStepY, abs(dy) > abs(dx) {
                swipeStepped = true
                tap(dy > 0 ? "ArrowDown" : "ArrowUp")
            }
        case .ended, .cancelled:
            if touchSwiping { swipeEndedAt = ProcessInfo.processInfo.systemUptime }
            swipeStepped = false
            touchDown = false
            touchSwiping = false
            swipeTouch = nil
        default:
            break
        }
    }

    private func startTouch(_ id: ObjectIdentifier, _ at: CGPoint) {
        swipeTouch = id
        swipeAnchor = at
        swipeStepped = false
        touchDown = true
        touchSwiping = false
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

    private static func isArrow(_ type: UIPress.PressType) -> Bool {
        type == .upArrow || type == .downArrow || type == .leftArrow || type == .rightArrow
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
