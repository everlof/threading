import Foundation

// MARK: - Environment Keys

public enum EnvironmentKeys {
    public static let term = "TERM"
    public static let colorTerm = "COLORTERM"

    /// `<foreground>;<background>`, as ANSI colour indices — rxvt's convention for telling a
    /// program whether it is drawing on paper or on ink. See `TerminalTheme.colorFGBG`.
    public static let colorFGBG = "COLORFGBG"

    /// Says "the stream you are writing to is not a colour terminal", whatever it is set to.
    /// Inside a session that stream is a PTY Threading draws, so an inherited value describes
    /// wherever the *app* was started from and is never true of a session. Cleared rather than
    /// overwritten: absence is the only way to say "colour is fine".
    public static let noColor = "NO_COLOR"

    /// The same claim, but only when spelled `0` — any other value is the user *asking* for
    /// colour and is left alone.
    public static let colorVetoes = ["CLICOLOR", "FORCE_COLOR"]

    /// The other half of "nothing is watching this": a caller that cannot page sets these to a
    /// program that does not page. A session *can* page, so the claim is dropped there — and
    /// only there. On the headless path it is true, and `AgentEnvironment.launchEnvironment`
    /// leaves it alone.
    public static let pagers = ["PAGER", "GIT_PAGER", "GH_PAGER"]

    /// How that claim is spelled. Anything else is a pager the user chose, which is theirs.
    public static let nonPager = "cat"

    public static let lang = "LANG"
    public static let path = "PATH"
    public static let home = "HOME"
    public static let shell = "SHELL"
    public static let columns = "COLUMNS"
    public static let lines = "LINES"
}
