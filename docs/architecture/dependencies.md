# Dependencies

The three local Swift packages, and the seams in each that are ours.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

- **SwiftTerm** (local fork): Terminal emulation engine handling VT100/xterm, ANSI parsing, PTY communication
  - Location: `./SwiftTerm/` (git submodule)
  - Upstream: https://github.com/migueldeicaza/SwiftTerm
  - **This is our fork** - feel free to modify SwiftTerm source code directly to implement features or fix bugs. The iOS folder is excluded on macOS builds.
  - **The PTY seam is ours.** Local processes launch through `forkpty`; a `posix_spawn`-based
    wrapper cannot establish the child as the PTY's controlling terminal. The launch publishes
    the exact child PID synchronously, before its exit source is activated, and reaps that PID
    with `waitpid` so `TerminalSession` never guesses from the app's process table.
    `running` remains true after SIGTERM until that exact PID is reaped, so a rapid replacement
    cannot overwrite the exit monitor and make the old callback wait on a new child.
    `TerminalSession` retains a launch requested during that short interval and performs it from
    the old child's termination callback.
  - **Main-queue output is bounded.** PTY reads pause once pending terminal data reaches the
    4 MiB high-water mark and resume below 1 MiB. The kernel PTY buffer then supplies
    normal producer backpressure instead of an unbounded queue growing behind a busy AppKit
    thread. One completed `DispatchIO` read starts one successor; partial callbacks do not fork
    additional read chains. Reads and queued chunks carry a launch generation; starting the next
    process clears the previous generation so late DispatchIO callbacks cannot leak old bytes
    into the replacement terminal. Deinitialization closes the PTY, cancels the monitor and gives
    the child to an independent waiter so it cannot remain a zombie.
  - **Mouse-wheel coordinates are viewport-relative.** Full-screen clients such as Claude enable
    mouse reporting and receive ordinary wheel input themselves; Option-wheel is the explicit
    local-scrollback escape hatch. Holding history above the live edge sets
    `Terminal.userScrolling`, so output repaints do not pull the viewport back to the bottom.

- **ThinkingOrbs** (local fork): the dotted "working" thought-orb drawn beside the
  conversation status while a turn is in flight.
  - Location: `./ThinkingOrbs/` (git submodule), referenced as a local Swift package the same
    way SwiftTerm is (`XCLocalSwiftPackageReference`, mirrored entries in `project.pbxproj`).
  - Upstream: https://github.com/everlof/thinking-orbs-swift — **our fork**, mod it directly.
  - The app uses only the AppKit `ThinkingOrbView` (a plain `NSView` drawing through a
    CoreGraphics engine, display link on 14+ / 60Hz timer on 13). SwiftUI ships in the package
    but the app touches none of it, so the app itself stays AppKit-only.
  - **The `tint` seam is ours.** The stock engine draws grayscale ink keyed off a `dark: Bool`,
    so it follows macOS light/dark but knows nothing of Skalman's accent. `paint` gained an
    optional `tint`: when set, depth rides on opacity instead of luminance (a dot's visibility
    is `1 - white` on either substrate), so a tinted orb reads identically in light and dark,
    only in the accent's hue. `WorkingOrbView` (in `UI/Design/`) is the theme boundary that
    drives it from `Design.Surface.accent`, re-resolved on a live theme switch and an
    appearance change.

- **LabelMorph** (local fork): the single-line label that morphs a name character by
  character when it changes, used for every session, project and checkout name the app shows.
  - Location: `./LabelMorph/` (git submodule), a local Swift package like the other two.
  - Upstream: https://github.com/everlof/LabelMorph — **our fork**, mod it directly.
  - `MorphingTitleLabel` (in `UI/Design/`) is the theme boundary: the package owns glyph
    layout and animation, the wrapper owns the semantic ink, Reduce Motion, clipping,
    accessibility and the user's chosen preset.
  - **Truncation is ours.** The stock label lays a whole line out from the leading edge and
    lets it run past the view, which the wrapper's clip then cuts dead mid-glyph. That is
    fine for a toolbar item sized to its text and wrong for every sidebar row, where names
    are sentences and the pane is the narrow one. `MorphTruncation.tail` keeps the longest
    head that fits and ends it with an ellipsis — found with one `CTLineGetStringIndexForPosition`
    rather than a search, then verified and stepped back by *composed character* so a cut
    never lands inside a surrogate pair. `intrinsicContentSize` still reports the whole
    text's width, so Auto Layout hears what the label wants and truncation only describes
    what it does once given less.
  - **Assigning the value already in force costs nothing** (`font`, `textColor`,
    `alignment` all guard on equality). Each rebuilds or repaints every glyph layer, and a
    sidebar row restates all three on every configure — which happens continuously while an
    agent works.
