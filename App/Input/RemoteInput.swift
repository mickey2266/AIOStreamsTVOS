import UIKit

/**
 * The Siri Remote as the keys the web app reads from a TV's remote: the
 * clickpad's edges as arrows (held, they repeat), a swipe as arrows (one for each
 * stretch of it, as the focus engine moves), Select as Enter (the page's hold
 * actions work on a held Enter), Play/Pause as `MediaPlayPause`. Back goes
 * through the bridge, as on Android. Held for a second, Play/Pause opens the
 * app's own menu instead. Follows the working aiostreams-tvos project's
 * RootViewController; the touch surface reads as NuvioTVOS's trackpad does
 * (RemoteInput.swift / PlayerViewModel.remoteTouch…).
 */
final class RemoteInput {
    var keyDown: (_ key: String, _ repeat: Bool) -> Void = { _, _ in }
    var keyUp: (_ key: String) -> Void = { _ in }
    var back: () -> Void = {}
    var menu: () -> Void = {}
    /// One step of a swipe, with the number of the finger's swipe it belongs to, so the page can
    /// treat a swipe over the player as NuvioTVOS's player does (`__aioTV.swipe`). Unset, a step
    /// is a press and release of the arrow.
    var swipeStep: ((_ key: String, _ stroke: Int) -> Void)?

    private var repeatTimer: Timer?
    private var repeating: String?
    private var menuHold: Timer?
    private var menuOpened = false

    // MARK: Touch surface state

    /// Which way the swipe under way runs, settled once it moves past `swipeIntent`.
    private enum Axis { case horizontal, vertical }
    private var swipeAxis: Axis?
    /// Where the finger was when the touch began (or was first seen); swipes are measured from it,
    /// as a pan recognizer's translation is.
    private var swipeAnchor: CGPoint = .zero
    /// The touch the anchor belongs to, so a touch whose start was missed anchors where it's first seen.
    private var swipeTouch: ObjectIdentifier?
    /// How far along its axis the swipe had gone at its last step.
    private var stepAnchor: CGFloat = 0
    /// Steps the swipe under way has made.
    private var swipeSteps = 0
    /// Counts the finger's swipes, each measured from where it began.
    private var stroke = 0
    /// The last sample along the swipe's axis, and its speed there (points a second, signed).
    private var lastAlong: CGFloat = 0
    private var lastSampleTime: TimeInterval = 0
    private var swipeSpeed: CGFloat = 0
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
    /**
     * Presses whose key went down to the page and hasn't come up. While one is held the finger is
     * clicking, not swiping (a click moves the finger a little), as NuvioTVOS's press recognizers
     * never run beside its pan; the swipe starts again from wherever the finger is once it's let go.
     */
    private var fired: Set<UIPress.PressType> = []
    private static let pressSettle: TimeInterval = 0.12
    /// Movement past which a finger on the surface is a swipe: NuvioTVOS's 15 pt dead zone, under
    /// which a touch is a tap or a click.
    private static let swipeIntent: CGFloat = 15
    /// How long after a swipe's finger lifts an arrow press still counts as part of it (NuvioTVOS
    /// keeps the move commands a swipe brings with it away for 0.3 s after it ends).
    private static let swipeAfterglow: TimeInterval = 0.3
    /// How far a swipe goes for each step, as the focus engine moves on one item a stretch: a long
    /// swipe steps several times, and coming back steps back.
    private static let swipeStepX: CGFloat = 160
    private static let swipeStepY: CGFloat = 130
    /// A quick flick that ends short of a step still steps once.
    private static let flickDistance: CGFloat = 40
    private static let flickSpeed: CGFloat = 700
    /// At most this many steps from one movement of the finger, however far it jumped.
    private static let maxStepsPerSample = 3

    private static let menuHoldTime: TimeInterval = 1
    private static let repeatDelay: TimeInterval = 0.45
    private static let repeatEvery: TimeInterval = 0.11

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
        fired.removeAll()
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
        endTouch()
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
                fire(press.type, key)
            } else {
                if dropped.remove(press.type) != nil { return }
                if let held = pending, held.type == press.type {
                    // Let go before it settled: a quick click, which steps once.
                    clearPending()
                    tap(key)
                    return
                }
                if repeating == key { stopRepeating() }
                released(press.type)
                keyUp(key)
            }
        }
    }

    /// The press's key goes down to the page, repeating unless it's Enter.
    private func fire(_ type: UIPress.PressType, _ key: String) {
        fired.insert(type)
        keyDown(key, false)
        if key != "Enter" { startRepeating(key) }
    }

    /// A press whose key went down has let go; once none is held, a finger still on the surface
    /// swipes again, measured from where it is now.
    private func released(_ type: UIPress.PressType) {
        guard fired.remove(type) != nil, fired.isEmpty else { return }
        swipeTouch = nil
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
            self.fire(held.type, held.key)
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

    // MARK: Touch surface

    /**
     * The touch surface as NuvioTVOS reads its trackpad: movement is measured from where the finger
     * came down, a touch that stays within `swipeIntent` is a tap or a click and sends nothing of
     * its own, and past it the swipe keeps to the axis it set off along. Each `swipeStepX` /
     * `swipeStepY` along that axis is one arrow, as the focus engine moves on one item a stretch,
     * and coming back the other way steps back. A flick too short for a step still steps once.
     */
    func touches(_ touches: Set<UITouch>) {
        // Of the touches in the event, the one still on the surface, if any.
        guard let touch = touches.first(where: { $0.phase != .ended && $0.phase != .cancelled }) ?? touches.first
        else { return }
        let at = touch.location(in: nil)
        let id = ObjectIdentifier(touch)
        switch touch.phase {
        case .began:
            startTouch(id, at, touch.timestamp)
        case .moved, .stationary:
            // A touch whose start wasn't seen (or that clicked) is measured from where it's seen
            // now, not from where the last swipe began, which could read as the opposite direction.
            if swipeTouch != id {
                startTouch(id, at, touch.timestamp)
                return
            }
            // A click is held: the finger is pressing, not swiping.
            guard fired.isEmpty else { return }
            let dx = at.x - swipeAnchor.x
            let dy = at.y - swipeAnchor.y
            if swipeAxis == nil {
                guard max(abs(dx), abs(dy)) >= Self.swipeIntent else { return }
                swipeAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                swipeStarted()
            }
            follow(swipeAxis == .horizontal ? dx : dy, at: touch.timestamp)
        case .ended, .cancelled:
            // Where the finger lifts is left out: it slides as the finger comes off.
            if touchSwiping {
                flickIfShort()
                swipeEndedAt = ProcessInfo.processInfo.systemUptime
            }
            endTouch()
        default:
            break
        }
    }

    /// The swipe has gone `along` points along its axis: a step for each stretch past the last one.
    private func follow(_ along: CGFloat, at time: TimeInterval) {
        let elapsed = time - lastSampleTime
        if elapsed > 0.001 {
            let speed = (along - lastAlong) / CGFloat(elapsed)
            swipeSpeed = swipeSpeed * 0.4 + speed * 0.6
        }
        lastAlong = along
        lastSampleTime = time

        let stretch = swipeAxis == .horizontal ? Self.swipeStepX : Self.swipeStepY
        var steps = 0
        while abs(along - stepAnchor) >= stretch, steps < Self.maxStepsPerSample {
            let forward = along > stepAnchor
            stepAnchor += forward ? stretch : -stretch
            steps += 1
            step(forward: forward)
        }
    }

    /// A quick flick that ended before its first step still steps once, its own way.
    private func flickIfShort() {
        guard swipeSteps == 0, swipeAxis != nil,
              abs(lastAlong) >= Self.flickDistance,
              abs(swipeSpeed) >= Self.flickSpeed,
              (lastAlong > 0) == (swipeSpeed > 0)
        else { return }
        step(forward: lastAlong > 0)
    }

    private func step(forward: Bool) {
        let key: String
        switch swipeAxis {
        case .horizontal: key = forward ? "ArrowRight" : "ArrowLeft"
        case .vertical: key = forward ? "ArrowDown" : "ArrowUp"
        case nil: return
        }
        swipeSteps += 1
        if let swipeStep {
            swipeStep(key, stroke)
        } else {
            tap(key)
        }
    }

    private func startTouch(_ id: ObjectIdentifier, _ at: CGPoint, _ time: TimeInterval) {
        stroke &+= 1
        swipeTouch = id
        swipeAnchor = at
        swipeAxis = nil
        stepAnchor = 0
        swipeSteps = 0
        lastAlong = 0
        lastSampleTime = time
        swipeSpeed = 0
        touchDown = true
        touchSwiping = false
    }

    private func endTouch() {
        swipeTouch = nil
        swipeAxis = nil
        swipeSteps = 0
        touchDown = false
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
