import XCTest
@testable import Threading

/// Covers the command classifier that decides which shell calls skip the permission prompt.
///
/// The refusals matter more than the approvals here. A missed approval costs one extra click;
/// a wrong approval runs something destructive without asking, so most of this file is about
/// what must *not* pass.
final class ShellCommandPolicyTests: XCTestCase {

    private func assertReadOnly(_ command: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            ShellCommandPolicy.isReadOnly(command),
            "should not have prompted: \(command)", file: file, line: line
        )
    }

    private func assertPrompts(_ command: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            ShellCommandPolicy.isReadOnly(command),
            "MUST prompt: \(command)", file: file, line: line
        )
    }

    // MARK: - What May Skip The Prompt

    func testOrdinaryReadsAreAllowed() {
        for command in [
            "ls", "ls -la", "pwd", "cat README.md", "head -20 file.txt",
            "wc -l src/main.swift", "grep -rn TODO Sources", "rg --json pattern",
            "find . -name '*.swift'", "du -sh .", "file binary", "stat -f %z x",
            "diff a.txt b.txt", "date", "whoami", "jq .name package.json"
        ] {
            assertReadOnly(command)
        }
    }

    func testReadOnlyGitIsAllowed() {
        for command in [
            "git status", "git status --porcelain", "git log --oneline -10",
            "git diff", "git diff HEAD~1", "git show abc123", "git rev-parse HEAD",
            "git ls-files", "git blame file.swift", "git merge-base main HEAD"
        ] {
            assertReadOnly(command)
        }
    }

    func testPipelinesOfReadsAreAllowed() {
        assertReadOnly("cat file.txt | grep TODO")
        assertReadOnly("ls -la | head -20")
        assertReadOnly("git log --oneline | wc -l")
        assertReadOnly("find . -name '*.swift' | sort | uniq")
    }

    // MARK: - Writes Must Prompt

    func testObviousWritesPrompt() {
        for command in [
            "rm -rf build", "mv a b", "cp a b", "mkdir out", "touch file",
            "chmod +x script.sh", "chown me file", "ln -s a b",
            "npm install", "swift build", "xcodebuild", "make",
            "curl https://example.com", "ssh host", "kill 123"
        ] {
            assertPrompts(command)
        }
    }

    /// Every git subcommand that writes under some arguments is absent from the safe list
    /// wholesale, rather than admitted and then flag-checked.
    func testWritingGitPrompts() {
        for command in [
            "git commit -m x", "git push", "git checkout main", "git reset --hard",
            "git clean -fd", "git stash", "git branch -D old", "git tag -d v1",
            "git config user.email x@y.z", "git remote add origin url", "git rebase main"
        ] {
            assertPrompts(command)
        }
    }

    // MARK: - Escapes Must Prompt

    /// The whole point of checking before splitting: these constructs make a segment mean
    /// something other than the words it appears to contain.
    func testRedirectionAndSubstitutionPrompt() {
        for command in [
            "cat secrets > /tmp/stolen",
            "echo pwned >> ~/.zshrc",
            "ls `rm -rf /`",
            "ls $(rm -rf /)",
            "cat ${HOME}/.ssh/id_rsa",
            "cat < /etc/passwd",
            "diff <(ls a) <(ls b)",
            "ls\nrm -rf /"
        ] {
            assertPrompts(command)
        }
    }

    /// Chaining is allowed only when *every* link is independently read-only. Measured on real
    /// rollouts, refusing `&&` outright made a chain of reads prompt, which is most of them.
    func testChainsOfReadsAreAllowed() {
        assertReadOnly("cat a.txt && cat b.txt")
        assertReadOnly("git status && git diff")
        assertReadOnly("ls || pwd")
        assertReadOnly("cat pkg.json && sed -n '1,50p' src/index.ts")
    }

    func testChainingIntoAWritePrompts() {
        assertPrompts("ls && rm -rf build")
        assertPrompts("cat file; rm file")
        assertPrompts("grep TODO . || npm install")
        assertPrompts("cat file | sh")
        assertPrompts("cat script.sh | bash")
        assertPrompts("cat a.txt && cargo build")
    }

    /// A single `&` detaches what came before it and lets the rest run unwatched, so it must
    /// still be refused even though `&&` is now allowed.
    func testBackgroundingStillPrompts() {
        assertPrompts("ls & rm -rf /")
        assertPrompts("sleep 100 &")
        assertPrompts("cat a && ls & rm x")
    }

    // MARK: - sed

    /// `sed -n '1,220p' file` is how Codex reads a file — 42% of its shell calls — so it is
    /// admitted, but only in exactly that shape.
    func testPrintingSedIsAllowed() {
        assertReadOnly("sed -n '1,220p' file.swift")
        assertReadOnly("sed -n '5p' file.txt")
        assertReadOnly("sed -n 240,290p file.txt")
    }

    /// `sed -n '10,$p'` reads to end-of-file and is perfectly safe, but it prompts — the `$`
    /// ban runs before any of this and cannot tell `$p` inside single quotes from a variable
    /// reference without tracking shell quoting. Refusing a rare legitimate form is the price
    /// of not having to be right about quoting, and it is the correct direction to be wrong in.
    func testEndOfFileRangePromptsBecauseOfTheDollarBan() {
        assertPrompts("sed -n '10,$p' file.txt")
    }

    /// `sed` is the one allowlisted command that can write, so everything outside the bare
    /// line-range print is refused — including forms that happen to be harmless.
    func testEverySedThatCouldWritePrompts() {
        assertPrompts("sed -i '' s/a/b/ file")
        assertPrompts("sed -i.bak s/a/b/ file")
        assertPrompts("sed --in-place s/a/b/ file")
        assertPrompts("sed -n -f script.sed file")
        assertPrompts("sed -n 's/a/b/w out.txt' file")
        assertPrompts("sed -n '/secret/w leak.txt' file")
        assertPrompts("sed 's/a/b/' file")
        assertPrompts("sed -n '/pattern/p' file")
    }

    /// Without `-n` the whole file is printed and the script is not a plain range read.
    func testSedWithoutSuppressedOutputPrompts() {
        assertPrompts("sed '1,220p' file")
    }

    /// Naive splitting is safe *because* it is naive: a quoted `;` splits into a segment whose
    /// first word is not allowlisted, so the command is refused rather than admitted.
    func testQuotedSeparatorsFailClosed() {
        assertPrompts("grep '; rm -rf /' file.txt")
        assertPrompts("echo 'a | sh'")
    }

    /// `find` is the one allowlisted command that runs other commands and deletes files.
    func testFindCannotExecuteOrDelete() {
        assertPrompts("find . -name '*.o' -delete")
        assertPrompts("find . -exec rm {} ;")
        assertPrompts("find . -execdir rm {} +")
        assertPrompts("find . -ok rm {} ;")
        assertPrompts("find . -fprint /tmp/out")
    }

    /// A leading assignment runs the command with an environment the policy never inspected,
    /// and an absolute path names a binary the allowlist never vetted.
    func testEnvironmentPrefixesAndPathsPrompt() {
        assertPrompts("PATH=/tmp ls")
        assertPrompts("LD_PRELOAD=evil.so cat file")
        assertPrompts("/bin/ls")
        assertPrompts("./script.sh")
        assertPrompts("../../bin/rm x")
    }

    /// Shaped like reads, but each has a write mode selected by an argument — which is exactly
    /// the judgement the allowlist exists to avoid making.
    func testInPlaceEditorsPrompt() {
        assertPrompts("awk '{print}' file")
        assertPrompts("tee /etc/hosts")
        assertPrompts("xargs rm")
        assertPrompts("sudo ls")
        assertPrompts("env ls")
        assertPrompts("eval ls")
    }

    // MARK: - Degenerate Input

    func testEmptyAndNonsenseInputPrompts() {
        assertPrompts("")
        assertPrompts("   ")
        assertPrompts(";")
        assertPrompts("|")
        assertPrompts("&&")
    }

    // MARK: - Integration

    /// The classifier only matters through the broker, and only for shell tools — an unknown
    /// tool whose arguments happen to contain a harmless string must still prompt.
    func testOnlyShellCallsConsultTheClassifier() {
        let readOnlyShell = PermissionRequest(
            sessionID: SessionID(), toolName: "exec", input: ["command": "ls -la"]
        )
        XCTAssertEqual(readOnlyShell.shellCommand, "ls -la")
        XCTAssertTrue(ShellCommandPolicy.isReadOnly(readOnlyShell.shellCommand ?? ""))

        // Codex spells it `cmd`.
        let codexSpelling = PermissionRequest(
            sessionID: SessionID(), toolName: "exec_command", input: ["cmd": "git status"]
        )
        XCTAssertEqual(codexSpelling.shellCommand, "git status")

        // A call naming no command must yield nil, so the broker asks rather than deciding.
        let noCommand = PermissionRequest(
            sessionID: SessionID(), toolName: "exec", input: ["something": "else"]
        )
        XCTAssertNil(noCommand.shellCommand)
    }

    /// A writing shell call is still refused after the mapping that made it `.bash`.
    func testWritingShellCallStillPrompts() {
        let request = PermissionRequest(
            sessionID: SessionID(), toolName: "exec", input: ["cmd": "rm -rf build"]
        )
        XCTAssertFalse(ShellCommandPolicy.isReadOnly(request.shellCommand ?? ""))
    }
}
