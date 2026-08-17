import Foundation

// MARK: - Storage Tool Strings

enum StorageToolStrings {
    static let mainCheckout = "main checkout"

    static let scanning = """
        Threading is still measuring build output, in the user's projects and in the temporary \
        locations agents build in. Ask again shortly.
        """

    /// Names both scopes, because the answer covers both: "nothing in your projects" would be a
    /// narrower claim than the one that was actually checked.
    static let nothingFound = """
        No reclaimable build output was found, either in the user's projects or in the temporary \
        locations agents build in.
        """

    /// The two gates, stated as the alternatives they are. A finding inside a project is offered
    /// because git ignores it; one in a temporary location has no repository to ask, and is
    /// offered because Xcode's own manifest says what wrote it. Claiming git for both would be
    /// false about every scratch line.
    static let listingFooter = """
        Everything above is either ignored by git or identified as a build cache by Xcode's own \
        manifest, and is rebuildable by the command shown. To act on any of it, call \
        propose_storage_cleanup with the exact paths — that asks the user, who decides. Nothing \
        is removed without their approval.
        """

    static let noPaths = "No paths were given. Pass one absolute path per line in `paths`."

    // MARK: - Suggesting

    /// Each refusal names the gate that said no, so the answer is something an agent can act on
    /// rather than a wall. "Not reclaimable" alone is what sends it round the loop again.
    static func vetMissing(_ path: String) -> String {
        "\(path) — no such directory, or it is a file rather than a directory."
    }

    static func vetSessionNotDormant(_ path: String) -> String {
        """
        \(path) — this is an agent session's scratch directory, but that session is still \
        running, or it belongs to an agent Threading did not launch. Only a session Threading \
        knows has ended can have its scratch directory reclaimed.
        """
    }

    static func vetNotIgnoredByGit(_ path: String, kind: String) -> String {
        """
        \(path) — looks like \(kind), but the repository it sits in does not treat it as \
        disposable: git either tracks something inside it or does not ignore it. Nothing \
        tracked is reclaimable, whatever it is called.
        """
    }

    static func vetUnrecognised(_ path: String) -> String {
        """
        \(path) — nothing identifies this as rebuildable output. Threading offers a directory \
        only when git calls it disposable, or a build tool's own manifest claims it, or it is \
        the scratch directory of a session that has ended.
        """
    }

    static func vetAccepted(_ path: String, kind: String, size: String) -> String {
        "\(path) — \(size), \(kind). Added to the listing; you can now propose it."
    }

    static func vetOutOfScope(_ path: String) -> String {
        """
        \(path) — reclaimable, but it belongs to no project Threading has open and sits in no \
        temporary location it watches, so there is no listing to add it to.
        """
    }

    static func vetSummary(accepted: Int, refused: Int) -> String {
        """
        Checked \(accepted + refused) path(s): \(accepted) added to the listing, \
        \(refused) refused.
        """
    }

    static let vetFooter = """
        Threading applied the same rules it applies to everything it finds itself; nothing here \
        was taken on trust. To act on what was accepted, call propose_storage_cleanup with those \
        exact paths — the user still decides.
        """
    static let noWindow = "There is no window to ask the user in."
    static let declined = "The user declined. Nothing was removed."
    static let cleanupAlreadyRunning = "Another approved storage cleanup is already running."

    static let approve = "Remove"
    static let decline = "Keep"

    static let proposalInUse = """
        One of these was written in the last few minutes, so a build may be running in it right \
        now.
        """

    static let proposalFooter = """
        Each is rebuilt by its own tool the next time it is needed. They are deleted \
        immediately rather than moved to the Trash.
        """

    static func measured(_ relative: String) -> String {
        " · measured \(relative)"
    }

    static func inUse(_ relative: String) -> String {
        "IN USE — written \(relative)"
    }

    static func lastWritten(_ relative: String) -> String {
        "last written \(relative)"
    }

    static func rebuild(_ hint: String) -> String {
        "rebuild: \(hint)"
    }

    /// The tree a scratch finding's own tool declared it was built for. Its path says nothing
    /// about which checkout fed it; two caches in one temporary directory can belong to two
    /// checkouts of the same project.
    static func builtFor(_ workspace: String) -> String {
        "built for \(workspace)"
    }

    /// The same when that tree is gone, marked in the shape `inUse(_:)` uses so the two states
    /// that change what a line is worth read alike. This is the tier to propose first: nothing
    /// can rebuild into it and nothing will ever read it again.
    static func orphaned(_ workspace: String) -> String {
        "ORPHANED — built for \(workspace), which no longer exists"
    }

    static func header(total: String, count: Int, measured: String) -> String {
        "\(total) reclaimable across \(count) directories\(measured):"
    }

    static func unknownPaths(_ paths: [String]) -> String {
        """
        None of these paths are in the current listing, so none can be proposed: \
        \(paths.joined(separator: ", ")). Call list_reclaimable_storage and quote its paths \
        exactly. Only build output Threading has already vetted can be proposed.
        """
    }

    /// Who is asking, and for how much.
    ///
    /// The session's own name rather than "an agent", because the complaint this answers is
    /// being asked by several of them: a sheet that will not say which one is asking makes two
    /// proposals from two sessions look like the same one asked twice.
    static func proposalTitle(asker: String?, count: Int, size: String) -> String {
        let what = count == 1
            ? "a build directory"
            : "\(count) build directories"
        guard let asker, !asker.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "An agent suggests removing \(what) to reclaim \(size)."
        }
        return "“\(asker)” suggests removing \(what) to reclaim \(size)."
    }

    // MARK: - The answer a proposal gets

    /// What one proposal is told, from what the user decided about the paths it named.
    ///
    /// Every sentence here exists to keep an agent from asking again. A proposal that folded
    /// into somebody else's approval is told the directories are already gone and what that
    /// freed; one that folded into a decline is told the user said no and asked not to repeat
    /// it. "None of these paths are in the current listing" is reserved for what it actually
    /// means — a stale quote — rather than being the answer to "you and two other sessions
    /// proposed the same 20 GB".
    static func result(of answer: StorageCleanupLedger.Answer) -> MCPToolResult {
        // Nothing decided, nothing folded, nothing left but paths no listing knows.
        if !answer.askedTheUser,
           answer.alreadyRemoved.isEmpty,
           answer.declinedEarlier.isEmpty,
           answer.couldNotAsk.isEmpty,
           !answer.unknown.isEmpty {
            return .failure(unknownPaths(answer.unknown))
        }

        if !answer.couldNotAsk.isEmpty, answer.removed.isEmpty, answer.declined.isEmpty {
            return .failure(couldNotAsk(answer.couldNotAskReason))
        }

        var sentences: [String] = []

        if answer.askedTheUser {
            if !answer.removed.isEmpty {
                sentences.append("""
                    The user approved. Removed \(answer.removed.count) \
                    \(directories(answer.removed.count)), reclaiming \
                    \(StorageCleanupOutline.size(answer.removedBytes)).
                    """)
            } else if !answer.declined.isEmpty {
                sentences.append(declined)
            }

            if !answer.refused.isEmpty {
                sentences.append("""
                    \(answer.refused.count) of them were left alone: they no longer looked safe \
                    to remove when checked again.
                    """)
            }
        }

        if !answer.alreadyRemoved.isEmpty {
            sentences.append("""
                \(answer.alreadyRemoved.count) \(directories(answer.alreadyRemoved.count)) had \
                already been removed on the user's approval a moment ago, freeing \
                \(StorageCleanupOutline.size(answer.alreadyRemovedBytes)); they were not \
                put to them a second time. Treat that space as already reclaimed.
                """)
        }

        if !answer.declinedEarlier.isEmpty {
            sentences.append("""
                The user has already declined \(answer.declinedEarlier.count) of these and was \
                not asked again: \(answer.declinedEarlier.joined(separator: ", ")). Do not \
                propose them again; tell them what it would free and let them decide.
                """)
        }

        if !answer.couldNotAsk.isEmpty {
            sentences.append(couldNotAsk(answer.couldNotAskReason))
        }

        if !answer.unknown.isEmpty {
            sentences.append("""
                Not in the listing and therefore ignored: \
                \(answer.unknown.joined(separator: ", ")).
                """)
        }

        return .success(sentences.joined(separator: " "))
    }

    private static func couldNotAsk(_ reason: String?) -> String {
        let because = reason.map { " \($0)" } ?? ""
        return "The proposal could not be put to the user, so nothing was decided.\(because)"
    }

    private static func directories(_ count: Int) -> String {
        count == 1 ? "directory" : "directories"
    }
}
