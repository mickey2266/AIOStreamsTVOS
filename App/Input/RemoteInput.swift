import UIKit

/**
 * The Siri Remote as the keys the web app reads from a TV's remote: the
 * clickpad's edges as arrows (held, they repeat), a swipe as arrows (up or down one row, or
 * two for a long one; across, as many posters as its length), Select as Enter
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
    /// The way the swipe under way runs, settled by its first step (true across, false up or
    /// down), the sign of that way (1 right or down, -1 left or up), and the steps it has sent.
    private var swipeAcross: Bool?
    private var swipeSign: CGFloat = 1
    private var swipeSteps = 0
    /*
     * tvOS reports a touch as coming down at a place of its own (the middle of the screen across,
     * x = 960 every time), not where the finger is, and its first move jumps to the finger: once
     * 187 pt down while the finger went up, which stepped Down before the swipe Up began. So a
     * swipe is measured from its first move, and the down point counts for nothing.
     */
    private var anchored = false
    /// Where the touch came down as tvOS reported it, to tell a press measured from it.
    private var downAt: CGPoint?
    /// The previous sample, so a step only goes the way the finger is moving.
    private var lastAt: CGPoint = .zero
    /// A finger is on the touch surface, and whether it has moved far enough to be a swipe.
    private var touchDown = false
    private var touchSwiping = false
    /// The touch's swipe has sent a step (kept after it ends, until the next touch begins).
    private var swipeStepped = false
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
    /*
     * Time alone didn't tell them apart: a swipe down from the top edge lifts off the edge, which
     * ends its Up, before it has moved far enough to count as a swipe, and an Up that ended before
     * it settled was taken for a quick click. Every swipe down then went up a row and down again,
     * and focus stayed between two rows. A click barely moves the finger, and an edge touch that
     * becomes a swipe always does, so an arrow whose finger moved more than `pressSlop` from where
     * it was when the press began is the swipe's, however it ends. The press is held back the same
     * way when its touch hasn't been seen yet, as the two can come in either order.
     */
    private var pending: (type: UIPress.PressType, key: String, from: CGPoint?)?
    private var pendingTimer: Timer?
    /// Arrow presses dropped as part of a swipe, whose ends are dropped too.
    private var dropped: Set<UIPress.PressType> = []
    private static let pressSettle: TimeInterval = 0.12
    /// How far the finger may move during a click: a click shifts it a few points, a swipe more.
    private static let pressSlop: CGFloat = 20
    /// A finger that has moved less than this between two looks is at rest.
    private static let stillSlop: CGFloat = 6
    /// How many `pressSettle` looks a moving finger may take before its arrow counts (0.48 s).
    private static let maxSettleLooks = 4
    /// Where the finger on the surface was last seen.
    private var touchAt: CGPoint = .zero
    /// Movement past which a finger on the surface is a swipe, well short of a step.
    private static let swipeIntent: CGFloat = 40
    /// How long after a swipe's finger lifts an arrow press still counts as part of it.
    private static let swipeAfterglow: TimeInterval = 0.2

    private static let menuHoldTime: TimeInterval = 1
    private static let repeatDelay: TimeInterval = 0.45
    private static let repeatEvery: TimeInterval = 0.11
    /*
     * How far a swipe goes for each step, measured from its first move along the way it set off.
     * Up and down: a short swipe moves one row (`firstStepY`), a long one two (`secondStepY`), no
     * more; a full-length swipe on the clickpad measured 700 to 950 pt. Across: one poster at
     * `firstStepX`, then one more for each `strideX`, so the steps follow the swipe's length.
     */
    /// One row at 280 pt (was 220), as a short brush moved a row. A second row needs 1100 pt (was 950,
    /// 900 and 800 before), past the longest full-length swipes measured (700 to 950): a swipe the
    /// length of the clickpad stays one row, and only an unusually long one moves two.
    private static let firstStepY: CGFloat = 280
    private static let secondStepY: CGFloat = 1000
    /// Across, half as sensitive again (was 150 and 280): a full-length swipe of about 1000 pt
    /// moves two posters.
    private static let firstStepX: CGFloat = 300
    private static let strideX: CGFloat = 560
    /// At most this many steps from one sample, however far the finger jumped.
    private static let maxStepsPerSample = 3

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
            note("dropped (something opened over the page)", held.type)
            clearPending()
            dropped.insert(held.type)
        }
        touchDown = false
        touchSwiping = false
        resetSteps()
        swipeTouch = nil
    }

    /// An arrow's press, its touch and the swipe under way, for the remote log.
    private func note(_ what: String, _ type: UIPress.PressType) {
        guard let key = Self.key(for: type), Self.isArrow(type) else { return }
        let since = ProcessInfo.processInfo.systemUptime - swipeEndedAt
        var parts = ["\(key) \(what):", touchDown ? "finger on" : "finger off"]
        if touchDown {
            let dx = Int(touchAt.x - swipeAnchor.x), dy = Int(touchAt.y - swipeAnchor.y)
            parts.append("swipe \(dx),\(dy)\(touchSwiping ? " swiping" : "")\(swipeStepped ? " stepped" : "")")
        }
        if since < 1 { parts.append("last swipe ended \(Int(since * 1000)) ms ago") }
        if let held = pending, held.type == type, let from = held.from {
            parts.append("moved \(Int(touchAt.x - from.x)),\(Int(touchAt.y - from.y)) since press")
        }
        EngineLogBook.remote(parts.joined(separator: " "))
    }

    func press(_ press: UIPress) {
        let began = press.phase == .began
        let ended = press.phase == .ended || press.phase == .cancelled
        guard began || ended else { return }
        if began { down.insert(press.type) } else { down.remove(press.type) }
        note(began ? "down" : (press.phase == .cancelled ? "cancelled" : "up"), press.type)

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
                    if !clickDuringDrift {
                        dropped.insert(press.type)
                        note("dropped (part of a swipe)", press.type)
                        return
                    }
                    note("taken (the thumb drifted without stepping)", press.type)
                    // The drift is over: the swipe starts again from the click, so it can't step after it.
                    if touchSwiping {
                        swipeAnchor = touchAt
                        lastAt = touchAt
                        resetSteps()
                        touchSwiping = false
                    }
                }
                // A dropped press whose end never came mustn't swallow this one's.
                dropped.remove(press.type)
                if arrow {
                    holdPending(press.type, key)
                    return
                }
                keyDown(key, false)
                if key != "Enter" { startRepeating(key) }
            } else {
                if dropped.remove(press.type) != nil {
                    if arrow { EngineLogBook.remote("\(key) end of a dropped press") }
                    return
                }
                if let held = pending, held.type == press.type {
                    // The finger slid off the edge: the start of a swipe, not a click.
                    if strayTravel(since: held.from, held.type) > Self.pressSlop {
                        note("dropped at release (finger strayed)", press.type)
                        clearPending()
                        return
                    }
                    clearPending()
                    // Let go before it settled: a quick click, which steps once.
                    EngineLogBook.remote("\(key) sent (quick click)")
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

    /*
     * A thumb resting on the clickpad drifts before it clicks: past `swipeIntent`, so it counts as a
     * swipe, but short of a step, so the swipe did nothing. The remote log showed Up dropped after the
     * thumb had drifted 130 and 204 pt without a step, either way from the edge it then clicked, and
     * after a cutoff of 80 pt, after 14 and 78 pt. The arrow a swipe brings with it from an edge begins
     * as the finger comes down, before it has moved: it's held back then (`holdPending`), and
     * `swipeStarted` drops it. So an arrow that begins once a swipe is under way, or just after one,
     * is a click unless the swipe has stepped. A swipe that stepped still owns its arrows.
     */
    private var clickDuringDrift: Bool { !swipeStepped }

    /// How far the finger has gone from `from` other than toward the arrow's edge: a thumb rolling onto
    /// the edge it presses is the click, while one moving along or away from it is a swipe.
    private func strayTravel(since from: CGPoint?, _ type: UIPress.PressType) -> CGFloat {
        guard let from else { return 0 }
        let dx = touchAt.x - from.x
        let dy = touchAt.y - from.y
        switch type {
        case .upArrow: return max(dy, abs(dx))
        case .downArrow: return max(-dy, abs(dx))
        case .leftArrow: return max(dx, abs(dy))
        case .rightArrow: return max(-dx, abs(dy))
        default: return max(abs(dx), abs(dy))
        }
    }

    private func holdPending(_ type: UIPress.PressType, _ key: String) {
        clearPending()
        pending = (type, key, touchDown ? touchAt : nil)
        settleLater(checkedAt: touchDown ? touchAt : nil)
    }

    /*
     * A thumb resting low on the clickpad holds Down, and a sideways swipe it starts slowly hasn't
     * gone far in `pressSettle`: Down fired, then the swipe's Left, so focus went down a row
     * instead of left into the rail. A held arrow settles only once the finger has kept still for
     * a `pressSettle` (moved under `stillSlop` since the last look): while it moves, the arrow
     * waits, and it's dropped once the finger has gone `pressSlop` from where the press began.
     * After `maxSettleLooks` looks, a finger still inside `pressSlop` is taken as resting, so a
     * trembling thumb still holds and repeats.
     */
    private func settleLater(checkedAt: CGPoint?, looks: Int = 1) {
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.pressSettle, repeats: false) { [weak self] _ in
            guard let self, let held = self.pending else { return }
            if self.strayTravel(since: held.from, held.type) > Self.pressSlop {
                self.note("dropped while settling (finger strayed)", held.type)
                self.clearPending()
                self.dropped.insert(held.type)
                return
            }
            if self.touchDown, looks < Self.maxSettleLooks, let from = checkedAt ?? held.from {
                // The press came before its touch, which has shown since (no look from there yet),
                // or the finger is on its way somewhere: a swipe, or a click that ends where it is.
                if checkedAt == nil || self.fingerTravel(since: from) > Self.stillSlop {
                    self.settleLater(checkedAt: self.touchAt, looks: looks + 1)
                    return
                }
            }
            self.clearPending()
            EngineLogBook.remote("\(held.key) sent (settled after \(looks) look\(looks == 1 ? "" : "s"))")
            self.keyDown(held.key, false)
            self.startRepeating(held.key)
        }
    }

    /// How far the finger has gone from `from`, measured to where it was last seen, so a press
    /// whose end comes just after the finger lifts still knows the finger slid.
    private func fingerTravel(since from: CGPoint?) -> CGFloat {
        guard let from else { return 0 }
        return max(abs(touchAt.x - from.x), abs(touchAt.y - from.y))
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
            note("dropped (finger started swiping)", held.type)
            clearPending()
            dropped.insert(held.type)
        }
        // An arrow that settled before the finger set off keeps its one step, but doesn't repeat
        // against the swipe.
        if let key = repeating, key.hasPrefix("Arrow") { stopRepeating() }
    }

    /**
     * A swipe on the touch surface steps as it goes, keeping to the way its first step went:
     * up or down one row, or two for a long swipe; across, one poster per stretch of it.
     */
    func touches(_ touches: Set<UITouch>) {
        // Of the touches in the event, the one still on the surface, if any.
        guard let touch = touches.first(where: { $0.phase != .ended && $0.phase != .cancelled }) ?? touches.first
        else { return }
        let at = touch.location(in: nil)
        let id = ObjectIdentifier(touch)
        if touch.phase != .ended, touch.phase != .cancelled {
            touchAt = at
            // The press came before its touch: it's measured from where the finger first shows.
            if let held = pending, held.from == nil { pending = (held.type, held.key, at) }
        }
        switch touch.phase {
        case .began:
            startTouch(id, at)
            downAt = at
        case .moved, .stationary:
            // A touch whose start wasn't seen is measured from where it's first seen, not from
            // where the last swipe began, which could read as the opposite direction.
            if swipeTouch != id {
                startTouch(id, at)
                // A move is where the finger really is, so it anchors the swipe.
                anchored = true
                lastAt = at
            }
            if !anchored {
                // The first move: where the finger really is. The swipe starts here.
                anchored = true
                swipeAnchor = at
                lastAt = at
                // An arrow pressed as the touch came down was measured from tvOS's down point.
                if let held = pending, let downAt, held.from == downAt { pending = (held.type, held.key, at) }
                return
            }
            let dx = at.x - swipeAnchor.x
            let dy = at.y - swipeAnchor.y
            // How this sample moved: a step goes only the way the finger is going now.
            let mx = at.x - lastAt.x
            let my = at.y - lastAt.y
            lastAt = at
            if !touchSwiping, max(abs(dx), abs(dy)) >= Self.swipeIntent { swipeStarted() }
            if swipeAcross == nil {
                // The first step settles the way, which the rest of the swipe keeps to.
                if abs(dx) >= Self.firstStepX, abs(dx) > abs(dy), mx * dx >= 0 {
                    swipeAcross = true
                    swipeSign = dx > 0 ? 1 : -1
                } else if abs(dy) >= Self.firstStepY, abs(dy) > abs(dx), my * dy >= 0 {
                    swipeAcross = false
                    swipeSign = dy > 0 ? 1 : -1
                } else {
                    return
                }
            }
            guard let across = swipeAcross else { return }
            // How far along its own way the swipe has gone; coming back sends nothing.
            let along = (across ? dx : dy) * swipeSign
            let due: Int
            if across {
                due = along < Self.firstStepX ? 0 : 1 + Int((along - Self.firstStepX) / Self.strideX)
            } else {
                due = along >= Self.secondStepY ? 2 : along >= Self.firstStepY ? 1 : 0
            }
            var sent = 0
            while swipeSteps < due, sent < Self.maxStepsPerSample {
                swipeSteps += 1
                swipeStepped = true
                sent += 1
                let key = across
                    ? (swipeSign > 0 ? "ArrowRight" : "ArrowLeft")
                    : (swipeSign > 0 ? "ArrowDown" : "ArrowUp")
                EngineLogBook.remote("\(key) sent (swipe step \(swipeSteps), \(Int(dx)),\(Int(dy)))")
                tap(key)
            }
        case .ended, .cancelled:
            if touchSwiping { swipeEndedAt = ProcessInfo.processInfo.systemUptime }
            resetSteps()
            touchDown = false
            touchSwiping = false
            swipeTouch = nil
        default:
            break
        }
    }

    private func startTouch(_ id: ObjectIdentifier, _ at: CGPoint) {
        anchored = false
        downAt = nil
        lastAt = at
        swipeTouch = id
        swipeAnchor = at
        resetSteps()
        touchDown = true
        touchSwiping = false
        swipeStepped = false
    }

    private func resetSteps() {
        swipeAcross = nil
        swipeSign = 1
        swipeSteps = 0
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
