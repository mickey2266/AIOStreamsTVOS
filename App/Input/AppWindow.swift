import UIKit

/// Takes the Siri Remote while nothing the app shows over the page needs it.
protocol RemoteReceiver: AnyObject {
    var takesRemote: Bool { get }
    func remotePress(_ press: UIPress)
    func remoteTouches(_ touches: Set<UITouch>)
    /// The press began while the page had the remote, so the rest of it is the page's too.
    func ownsPress(_ press: UIPress) -> Bool
}

/**
 * Hands the remote's presses and touch-surface swipes to the page's handler
 * before UIKit does. WebKit's content view is first responder, so it would
 * otherwise take them itself. As the working aiostreams-tvos project's AIOWindow.
 */
final class AppWindow: UIWindow {
    weak var remote: RemoteReceiver?

    override func sendEvent(_ event: UIEvent) {
        guard let remote else { return super.sendEvent(event) }
        if event.type == .presses, let presses = (event as? UIPressesEvent)?.allPresses {
            if remote.takesRemote {
                for press in presses { remote.remotePress(press) }
                return
            }
            // Something opened over the page while a press was down (Up opening the search
            // keyboard): the rest of that press goes where it began, not to the screen on top.
            // A new press always goes to the screen on top.
            if presses.contains(where: { $0.phase == .began && $0.type == .upArrow }) {
                EngineLogBook.remote("ArrowUp went to the screen on top, not the page")
            }
            let carried = presses.filter { $0.phase != .began && remote.ownsPress($0) }
            for press in carried { remote.remotePress(press) }
            if !carried.isEmpty, carried.count == presses.count { return }
            return super.sendEvent(event)
        }
        guard remote.takesRemote else { return super.sendEvent(event) }
        if event.type == .touches, let touches = event.allTouches {
            let indirect = touches.filter { $0.type == .indirect }
            if !indirect.isEmpty {
                remote.remoteTouches(indirect)
                return
            }
        }
        super.sendEvent(event)
    }
}
