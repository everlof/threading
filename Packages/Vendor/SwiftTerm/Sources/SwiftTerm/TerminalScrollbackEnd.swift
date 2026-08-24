/// Defines where the normal buffer's local scrollback reaches its live end.
///
/// Full-screen terminal programs and ordinary shells use ``screen``: the
/// viewport at the live edge is the terminal's complete row grid, including
/// rows below the cursor. An inline transcript can instead use
/// ``lastPopulatedRow`` so unused rows below its compact live viewport do not
/// become a page of empty scrollback.
public enum TerminalScrollbackEnd: Equatable, Sendable {
    /// Preserve the terminal's complete live screen at the end of scrollback.
    case screen

    /// End at the last populated live-screen row, or the cursor row when it is
    /// lower. Older scrollback fills any otherwise-unused rows above it.
    case lastPopulatedRow
}
