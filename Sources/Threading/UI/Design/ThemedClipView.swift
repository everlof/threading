import AppKit

/// A clip view whose default is the only background a themed scroll surface wants: none.
///
/// Kept separate because conversations replace the ordinary clip view with a flipped subclass.
/// Subclassing this preserves the invariant without every call site remembering to turn the
/// AppKit background off after construction.
public class ThemedClipView: NSClipView, ThemedComponent {

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
