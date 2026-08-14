import Foundation

#if DEBUG

// MARK: - A Report, Addressed To A Chat

/// A reviewed report on its way to an agent instead of to the intake service.
struct DeveloperReportChatRequest: Equatable, Sendable {
    /// What to name the session. Already capped by `DeveloperIssueReportComposer.title`, so the
    /// two sheets name a chat exactly the way they title the private report.
    let title: String

    /// The complete local report: the user's words first, then the app's own capture — what
    /// **Copy Report** puts on the pasteboard, screenshot path and all.
    let report: String
}

enum DeveloperReportChatOutcome: Equatable, Sendable {
    case started(projectName: String)
    case failed(message: String)
}

// MARK: - Developer Report Chat

/// The development build's second destination for a report: a chat in the repository this
/// binary was compiled from, instead of Threading's private inbox.
///
/// `MacIssueReportSubmitter` is the route that matters in a shipped build — a bounded, redacted
/// DTO posted to an intake service, durable across a failed POST. It is the wrong route while
/// building Threading *in* Threading. The report is about the window in front of you, the
/// evidence worth keeping is the full local capture including the screenshot's **path**, and an
/// intake service that is not answering leaves the note in `MacIssueReportOutbox` where nothing
/// reads it. Two reports sat there for two days before anybody asked where they had gone; the
/// outbox was behaving exactly as designed, and that is the point — a queue for a service that
/// does not exist yet is not a way to tell somebody something.
///
/// So this route hands the same reviewed text to an agent that can act on it, taking by button
/// the path the developer takes by hand: Copy Report, new chat, paste, Return.
///
/// **Debug only, and deliberately not a setting.** It rests on `#filePath` — the source root of
/// the build that is running, a fact only a development build has and one no preference could
/// keep pointing at the right folder. Everything here is a decision over values, so what is
/// worth holding can be held without a window, a store, or an agent process.
enum DeveloperReportChat {

    // MARK: - Where The Build Came From

    /// The repository this binary was compiled from.
    ///
    /// A build run from a copy — an rsync'd tree, a worktree, a second checkout — resolves to
    /// that copy, which is right: it is the tree whose code drew the window being reported on.
    /// When the copy is not a project in the sidebar, `targetProjectID` falls back to what is on
    /// screen rather than inventing one.
    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)  // …/Sources/Threading/Core/Remote/<this file>
            .deletingLastPathComponent()  // Remote
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // Threading
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // the repository root
    }

    /// Which project the chat opens in: the one whose folder **is** this build's source root,
    /// and otherwise whatever the window is showing.
    ///
    /// An exact match rather than "somewhere under", because one repository holds several
    /// projects here — checkouts, worktrees, a dogfooded extension beside the app — and a
    /// report about Threading's own window belongs to the tree that drew it, not to the first
    /// row whose path happens to share a prefix.
    ///
    /// The fallback is not a guess about the report. It is the same project a new chat would
    /// open in if the developer had started one themselves, which is the honest answer when the
    /// running build was compiled somewhere Threading has never been pointed at.
    static func targetProjectID(
        projects: [Project],
        sourceRoot: URL,
        fallback: ProjectID?
    ) -> ProjectID? {
        let root = canonicalPath(sourceRoot)
        let match = projects.first { canonicalPath(URL(fileURLWithPath: $0.folderPath)) == root }
        return match?.id ?? fallback
    }

    /// Symlinks resolved and the path standardized, on both sides. `/var` is a symlink to
    /// `/private/var` on this platform, and a repository under a symlinked home compares unequal
    /// to its own path for that reason alone.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - How The Chat Is Configured

    /// The configuration a report chat inherits: the most recently used chat in that project.
    ///
    /// Not the app defaults, and not a runtime chosen here. The person filing the report is the
    /// person who was working in that project a moment ago, and a chat that comes up on a
    /// different agent, login, model or permission mode than the one they have used all day is a
    /// chat they have to reconfigure before it can do anything. Archived rows are skipped —
    /// those are the ones deliberately put away.
    ///
    /// **Never a managed workspace, and never a branch.** A UI report is read against the tree
    /// the build came from; a detached worktree would put the agent somewhere the screenshot is
    /// not about.
    ///
    /// The two clamps are `AgentSessionConfiguration`'s own rules, applied here rather than
    /// discovered as a nil session later: an account handle only means something for a runtime
    /// with logins, and a permission mode only for one with modes. Inheriting them from a
    /// session of the same kind keeps both valid, and the defaults path is where they would
    /// otherwise go wrong.
    static func plan(
        projectID: ProjectID,
        sessions: [AgentSession],
        defaultKind: AgentKind
    ) -> ScheduledSessionPlan {
        let latest = sessions
            .filter { !$0.isArchived }
            .max { $0.lastUsedAt < $1.lastUsedAt }
        let kind = latest?.kind ?? defaultKind
        let inherited = latest?.kind == kind ? latest : nil

        return ScheduledSessionPlan(
            projectID: projectID,
            kind: kind,
            accountHandle: kind.supportsAccounts
                ? (inherited?.accountHandle ?? .standard)
                : .standard,
            model: inherited?.model,
            reasoningEffort: inherited?.reasoningEffort,
            fastMode: inherited?.fastMode,
            branch: nil,
            usesNativeUI: inherited?.usesNativeUI ?? kind.supportsNativeUI,
            permissionMode: kind.supportsPermissionModes ? inherited?.permissionMode : nil,
            managedWorkspacePlan: nil
        )
    }

    // MARK: - What The Chat Is Opened With

    /// The report under one line saying where it came from.
    ///
    /// The line is Threading speaking, and it earns its place twice. The note reads as a
    /// person's words, so without a frame the view chain and frame rectangle underneath read as
    /// something that person typed. And it names the screenshot as a **file**, because a path is
    /// the one form of an image the agent CLIs can act on — an agent that does not know it may
    /// open the capture describes the geometry instead of looking at it.
    ///
    /// Deliberately not the `[Cross-session message …]` header. Nothing here was written by
    /// another session's agent, and this is the opening prompt of a chat the user started by
    /// pressing a button, so the mechanics are honest as they stand; claiming a provenance that
    /// does not apply is the failure `control-plane.md` names for the watch notice.
    static func framedReport(_ report: String) -> String? {
        let trimmed = report.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return DeveloperReportChatStrings.frame + "\n\n" + trimmed
    }
}

// MARK: - Strings

enum DeveloperReportChatStrings {
    /// English source copy, and the key it is looked up by. Agent-facing rather than on screen,
    /// and localized for the same reason `SessionReportBackRequest` is: the reader is the user's
    /// own agent, working in the user's own language.
    static var frame: String {
        L10n.string("""
            Reported from Threading’s inspector in this development build. My description comes \
            first, then the app’s own capture of the element. The screenshot is a file on disk \
            you can open.
            """)
    }

    static var buttonTitle: String { L10n.string("Send to Chat") }
    static var startingStatus: String { L10n.string("Starting a chat…") }

    static func started(projectName: String) -> String {
        L10n.format("Started a chat in “%@”.", projectName)
    }

    static var noProject: String {
        L10n.string("Add this build’s repository as a project, or open one first.")
    }
    static var notCreated: String { L10n.string("The chat could not be created.") }
    static var notStarted: String {
        L10n.string("The chat was created, but its agent didn’t start.")
    }
}

#endif
