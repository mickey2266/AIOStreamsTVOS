import UIKit

/// Where the page wants the video, from its `player-frame` (upstream's `VideoFrame`,
/// `lib/playback/engine.ts`): a box in the page's pixels, or none for the whole screen.
struct VideoFrame: Equatable {
    var rect: CGRect
    /// Under something the page draws over it (a dialog, or the page's own picture around a trailer):
    /// the video stays in its box beneath the page, and no hole is cut through the page for it.
    var hidden: Bool
    /// Moves there as the page's card does, rather than at once.
    var animate: Bool
    /// The top corners' and the bottom corners'.
    var radius: CGFloat
    var bottomRadius: CGFloat
    /// Subtitles show in the box; trailer previews have none.
    var subtitles: Bool

    /// nil when the message holds no frame (`frame: null`), which fills the screen again. `webWidth` is the
    /// web view's width in points: the frame is in the page's measure, and the bridge script sends the
    /// page's width in that measure (`pageWidth`), so the two give the points per page pixel.
    static func from(_ message: Message, webWidth: CGFloat) -> VideoFrame? {
        guard let frame = message.object("frame") else { return nil }
        var scale: CGFloat = 1
        if let page = message.number("pageWidth"), page.isFinite, page > 0, webWidth > 0 {
            scale = webWidth / CGFloat(page)
        }
        func number(_ key: String) -> CGFloat {
            guard let value = frame.number(key), value.isFinite else { return 0 }
            // Far outside any screen is a mistake in the page, not a place.
            return CGFloat(min(max(value, -100_000), 100_000)) * scale
        }
        return VideoFrame(
            rect: CGRect(x: number("x"), y: number("y"), width: max(0, number("width")), height: max(0, number("height"))),
            hidden: frame.flag("hidden") == true,
            animate: frame.flag("animate") == true,
            radius: max(0, number("radius")),
            bottomRadius: max(0, number("bottomRadius")),
            subtitles: frame.flag("subtitles") != false
        )
    }
}

/**
 * The video and its subtitles, which the page can draw small: its mini player docked in a page's
 * preview, and trailers playing by themselves in cards, the hero and title pages (upstream's
 * `features/player/mini-player.tsx` and `features/trailers/preview.tsx`). As the Android app's
 * MiniPlayer does, the stage shrinks to the frame beneath the page, and while the frame isn't hidden a
 * rounded hole is cut through the page (a mask on the web view) so the video shows even where the
 * page draws. A TV has no corner card to drag (upstream's `canMinimise` is false on a TV), and the
 * remote's presses reach the page as keys, so no `player-frame` events go back to the page.
 */
@MainActor
final class VideoStage {
    /// Holds the video view and the subtitle overlay, which follow its bounds.
    let view = UIView()
    /// The page, which the hole is cut through.
    weak var web: UIView? {
        didSet { refresh(animated: false) }
    }
    /// Picture in picture shows the video in the system's window, so the page keeps no hole for it.
    var pictureInPicture: () -> Bool = { false }

    private let subtitles: UIView
    private let hole = CAShapeLayer()
    private var frame: VideoFrame?
    private var animator: UIViewPropertyAnimator?

    /// As the page's card moves (`MINI_MOVE_MS`, `MINI_MOVE_EASE`).
    private static let moveSeconds: TimeInterval = 0.22
    private static let moveCurve = (CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.2, y: 1))

    init(video: UIView, subtitles: UIView) {
        self.subtitles = subtitles
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        for pane in [video, subtitles] {
            pane.frame = view.bounds
            pane.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(pane)
        }
        hole.fillRule = .evenOdd
        hole.fillColor = UIColor.black.cgColor
    }

    /// The page's `player-frame`; nil fills the screen again.
    func place(_ next: VideoFrame?) {
        guard next != frame else { return }
        frame = next
        refresh(animated: next?.animate == true)
    }

    /// Lays the stage and the hole out again, as picture in picture starts or ends.
    func refresh(animated: Bool = false) {
        guard let container = view.superview else { return }
        animator?.stopAnimation(true)
        animator = nil
        let shown = frame.flatMap { pictureInPicture() ? nil : $0 }
        let target: CGRect
        if let shown, let web {
            target = container.convert(shown.rect, from: web)
        } else {
            target = container.bounds
        }
        // Full screen it follows the window as before; boxed it stays where the page put it.
        view.autoresizingMask = shown == nil ? [.flexibleWidth, .flexibleHeight] : []
        view.clipsToBounds = shown != nil
        view.layer.cornerRadius = shown.map { max($0.radius, $0.bottomRadius) } ?? 0
        view.layer.maskedCorners = Self.corners(shown)
        subtitles.alpha = shown?.subtitles == false ? 0 : 1
        if animated, shown != nil {
            let (c1, c2) = Self.moveCurve
            let animator = UIViewPropertyAnimator(
                duration: Self.moveSeconds,
                timingParameters: UICubicTimingParameters(controlPoint1: c1, controlPoint2: c2)
            )
            animator.addAnimations { [view] in view.frame = target }
            animator.startAnimation()
            self.animator = animator
        } else {
            view.frame = target
        }
        cutHole(shown, animated: animated)
    }

    /// The corners the radius applies to: the bar's video has a bottom radius of its own, a docked
    /// preview's is the same all round.
    private static func corners(_ frame: VideoFrame?) -> CACornerMask {
        guard let frame else { return [] }
        var corners: CACornerMask = []
        if frame.radius > 0 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if frame.bottomRadius > 0 { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        return corners
    }

    /// Cuts the frame's box out of the page, or puts the page back whole.
    private func cutHole(_ frame: VideoFrame?, animated: Bool) {
        guard let web else { return }
        guard let frame, !frame.hidden, frame.rect.width > 0, frame.rect.height > 0 else {
            if web.layer.mask === hole { web.layer.mask = nil }
            return
        }
        let path = UIBezierPath(rect: web.bounds)
        var corners: UIRectCorner = []
        if frame.radius > 0 { corners.formUnion([.topLeft, .topRight]) }
        if frame.bottomRadius > 0 { corners.formUnion([.bottomLeft, .bottomRight]) }
        let radius = max(frame.radius, frame.bottomRadius)
        path.append(UIBezierPath(
            roundedRect: frame.rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        ))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hole.frame = web.bounds
        if animated, web.layer.mask === hole, let from = hole.path {
            let move = CABasicAnimation(keyPath: "path")
            move.fromValue = from
            move.toValue = path.cgPath
            move.duration = Self.moveSeconds
            let (c1, c2) = Self.moveCurve
            move.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(c1.x), Float(c1.y), Float(c2.x), Float(c2.y)
            )
            hole.add(move, forKey: "path")
        }
        hole.path = path.cgPath
        if web.layer.mask !== hole { web.layer.mask = hole }
        CATransaction.commit()
    }
}
