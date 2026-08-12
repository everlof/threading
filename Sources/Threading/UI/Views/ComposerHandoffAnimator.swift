import AppKit

// MARK: - Constants

enum ComposerHandoffDefaults {
    /// How faded the arriving conversation starts.
    ///
    /// Held back rather than hidden: the ghost of the composer is opaque over most of the pane
    /// for the first half of the move, and a conversation starting at zero would be a blank
    /// pane appearing behind it. This reads as the thread coming up under a surface leaving.
    static let contentArrivalAlpha: CGFloat = 0.7
}

// MARK: - ComposerHandoffAnimator

/// The composer's box becoming the conversation's reply box.
///
/// Starting a session swaps two whole surfaces, and exactly one thing is on both of them: the
/// box that was just typed into. Moving it from where it stood to where the conversation replies
/// from is what says the thread *is* the thing being written in, rather than a second screen that
/// replaced it. Everything else the composer holds — the hero, the chips, the import offer — has
/// no counterpart on the other side, so it leaves as a picture of itself.
///
/// It lives beside `TerminalContainerViewController` rather than inside it because the pane's
/// swap is already its longest method, and because one type owning every ghost is what lets
/// "take them all away and put every alpha back" be a single call the cancellation path can make
/// from anywhere.
///
/// The ghosts choose nothing: each is an image of a view that had already drawn itself, so no
/// colour, font, radius or hairline here is a second opinion about what the theme states.
@MainActor
final class ComposerHandoffAnimator {

    // MARK: - Properties

    /// Everything read off the composer before it is hidden — two pictures and two frames, the
    /// frames already in the host's coordinates, because the views they came from are about to
    /// stop being on screen.
    struct Snapshot {
        let composerImage: NSImage
        let composerFrame: NSRect
        let boxImage: NSImage
        let boxFrame: NSRect
    }

    private var ghosts: [NSView] = []
    private var revealed: [NSView] = []
    private var completion: (() -> Void)?
    private var landing: DispatchWorkItem?

    /// Whether a handoff is on screen right now. False the instant `finish()` has run, whatever
    /// the animation underneath is still doing.
    var isRunning: Bool { !ghosts.isEmpty }

    // MARK: - Public Methods

    /// Captures the composer and the box inside it, in the host's coordinates.
    ///
    /// Called while the composer is still the visible surface: both the frame and the picture
    /// are gone the moment the conversation takes the pane.
    static func snapshot(composer: NSView, box: NSView, in host: NSView) -> Snapshot? {
        guard let composerImage = image(of: composer),
              let boxImage = image(of: box) else { return nil }

        return Snapshot(
            composerImage: composerImage,
            composerFrame: composer.convert(composer.bounds, to: host),
            boxImage: boxImage,
            boxFrame: box.convert(box.bounds, to: host)
        )
    }

    /// Runs the one orchestrated moment: the ghost of the whole composer fades out where it
    /// stood, the ghost of its box travels to `destination` and crossfades into the real one,
    /// and the conversation's own content comes up under both.
    ///
    /// One animation group, so no part of the move can drift out of step with the rest, and one
    /// landing: `finish` is the only place the end state is arrived at, whichever signal reaches
    /// it first.
    func run(
        _ snapshot: Snapshot,
        in host: NSView,
        below reference: NSView?,
        into destination: NSView,
        revealing content: [NSView],
        completion: (() -> Void)? = nil
    ) {
        // A second start cancels the first rather than layering two sets of ghosts over one
        // pane. This is also the guard against a double-run: `finish` leaves nothing behind.
        finish()

        let target = destination.convert(destination.bounds, to: host)

        // Under Reduce Motion the token is zero, and the honest reduced form of a move is the
        // thing already being where it lands: nothing is built, nothing is faded, and the pane
        // is in exactly the state the completion would have left it in.
        guard Design.Motion.handoff > 0, target.width > 0, target.height > 0 else {
            completion?()
            return
        }

        let composerGhost = Self.ghost(snapshot.composerImage, frame: snapshot.composerFrame)
        let boxGhost = Self.ghost(snapshot.boxImage, frame: snapshot.boxFrame)

        // Above the conversation and below the git status card: the card is the pane's own
        // floating surface and outranks a transition passing underneath it.
        Self.add(composerGhost, to: host, below: reference)
        Self.add(boxGhost, to: host, below: reference)

        destination.alphaValue = 0
        for view in content { view.alphaValue = ComposerHandoffDefaults.contentArrivalAlpha }

        ghosts = [composerGhost, boxGhost]
        revealed = [destination] + content
        self.completion = completion

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.handoff
            // Eased at both ends: the box is one object being carried, and a linear move reads
            // as a slide rather than as something picked up and set down.
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            composerGhost.animator().alphaValue = 0
            boxGhost.animator().frame = target
            boxGhost.animator().alphaValue = 0
            destination.animator().alphaValue = 1
            for view in content { view.animator().alphaValue = 1 }
        } completionHandler: { [weak self] in
            self?.finish()
        }

        // The landing is scheduled as well as handed to the group, because a group whose
        // animations never start never reports one: a window that is not on screen — hidden,
        // minimised, on another Space — commits no layer transaction, and the ghosts would sit
        // over the conversation until the next surface swap took them away. `finish` is
        // idempotent, so whichever of the two arrives first is the landing.
        let landing = DispatchWorkItem { [weak self] in self?.finish() }
        self.landing = landing
        DispatchQueue.main.asyncAfter(deadline: .now() + Design.Motion.handoff, execute: landing)
    }

    /// The end state, reachable from anywhere: the ghosts gone and every alpha back to one.
    ///
    /// Safe at any point, including from the completion handler of a run something else already
    /// cancelled — it leaves nothing to undo, so the second call does nothing. Cancelling does
    /// not have to stop the animation either: every property this animates *targets* the end
    /// state, so a frame still in flight over a restored view can only land where the restore
    /// has already put it.
    func finish() {
        landing?.cancel()
        landing = nil

        guard !ghosts.isEmpty || !revealed.isEmpty || completion != nil else { return }

        for ghost in ghosts {
            ghost.layer?.removeAllAnimations()
            ghost.removeFromSuperview()
        }
        ghosts = []

        for view in revealed { view.alphaValue = 1 }
        revealed = []

        let finished = completion
        completion = nil
        finished?()
    }

    // MARK: - Private Methods

    /// A picture of a view as it is drawn *now*.
    ///
    /// `cacheDisplay` draws in whatever appearance happens to be current, which is not the
    /// window's — a pane captured without this arrives wearing the light palette over a dark
    /// window, which is the one thing a ghost of live content cannot get wrong.
    private static func image(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        // Layer colours are CGColors frozen when a surface was last configured. A composer can
        // be constructed before its dark window owns it, so merely drawing under the window's
        // appearance leaves a light field baked into the snapshot. Re-resolve the whole source
        // tree at the capture boundary; a ghost is only truthful if it has the same lifecycle
        // repair as the live view it depicts.
        AppThemeRefresh.repaint(view)

        guard let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: representation)
        }

        // Points, not pixels, so the ghost is the size of the view it was taken from on any
        // backing scale.
        representation.size = bounds.size

        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    /// Placed by frame and animated by frame, so it takes part in no layout pass the pane is
    /// running underneath it.
    private static func ghost(_ image: NSImage, frame: NSRect) -> NSView {
        let view = NSImageView(frame: frame)
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        // The real content is in the tree behind it: an assistive technology reading this would
        // be reading the composer twice, once from a picture that is already leaving.
        view.setAccessibilityElement(false)
        return view
    }

    private static func add(_ view: NSView, to host: NSView, below reference: NSView?) {
        guard let reference, reference.superview === host else {
            host.addSubview(view)
            return
        }
        host.addSubview(view, positioned: .below, relativeTo: reference)
    }
}
