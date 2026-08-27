import XCTest
@testable import Threading

/// The rules for hiding secrets in a drawn command line. Key-driven throughout: a value is
/// redacted because of what *names* it, never because of what it looks like — the info panel
/// must not guess which strings are secrets, only honor the flags that say so.
final class CommandLineRedactorTests: XCTestCase {

    func testALongFlagWithAnInlineValueIsRedacted() {
        let redacted = CommandLineRedactor.redact(["deploy", "--api-key=sk-live-1234"])

        XCTAssertEqual(redacted.arguments, ["deploy", "--api-key=<redacted>"])
        XCTAssertEqual(redacted.redactedCount, 1)
    }

    /// The flag's own spelling survives — `--Api-Key` stays `--Api-Key` — because the redaction
    /// hides the value, not what the command was.
    func testTheFlagsOwnSpellingIsPreserved() {
        let redacted = CommandLineRedactor.redact(["--Api-Key=v"])
        XCTAssertEqual(redacted.arguments, ["--Api-Key=<redacted>"])
    }

    func testABareCredentialFlagRedactsTheFollowingArgument() {
        let redacted = CommandLineRedactor.redact(["curl", "--token", "abc123", "https://x"])

        XCTAssertEqual(redacted.arguments, ["curl", "--token", "<redacted>", "https://x"])
        XCTAssertEqual(redacted.redactedCount, 1)
    }

    /// `-p` names a password by convention (`mysql`, `psql`, `sshpass`) rather than by its
    /// letter, so it rides an explicit list rather than the vocabulary.
    func testTheShortPasswordFlagRedactsItsValue() {
        let redacted = CommandLineRedactor.redact(["mysql", "-p", "hunter2"])
        XCTAssertEqual(redacted.arguments, ["mysql", "-p", "<redacted>"])
    }

    func testAnEnvironmentShapedAssignmentIsRedacted() {
        let redacted = CommandLineRedactor.redact(["env", "API_KEY=sk-1", "npm", "start"])

        XCTAssertEqual(redacted.arguments, ["env", "API_KEY=<redacted>", "npm", "start"])
        XCTAssertEqual(redacted.redactedCount, 1)
    }

    func testVendorNamespacedAndCamelCaseKeysAreRedactedByTheirSegments() {
        let redacted = CommandLineRedactor.redact([
            "env",
            "GITHUB_TOKEN=ghp-secret",
            "ANTHROPIC_API_KEY=sk-ant-secret",
            "AWS_SECRET_ACCESS_KEY=aws-secret",
            "npmToken=npm-secret",
            "run"
        ])

        XCTAssertEqual(redacted.arguments, [
            "env",
            "GITHUB_TOKEN=<redacted>",
            "ANTHROPIC_API_KEY=<redacted>",
            "AWS_SECRET_ACCESS_KEY=<redacted>",
            "npmToken=<redacted>",
            "run"
        ])
        XCTAssertEqual(redacted.redactedCount, 4)
    }

    func testCredentialHeadersAndEmbeddedURLCredentialsAreRedacted() {
        let redacted = CommandLineRedactor.redact([
            "curl",
            "-H", "Authorization: Bearer sk-ant-secret",
            "--header=X-Api-Key: vendor-secret",
            "https://x-access-token:ghp-secret@github.com/o/r.git?oauthCode=temporary"
        ])

        XCTAssertEqual(redacted.arguments, [
            "curl",
            "-H", "Authorization: <redacted>",
            "--header=X-Api-Key: <redacted>",
            "https://github.com/o/r.git?oauthCode=%3Credacted%3E"
        ])
        XCTAssertEqual(redacted.redactedCount, 4)
    }

    func testBearerAndAuthFlagsRedactTheirFollowingValues() {
        let redacted = CommandLineRedactor.redact([
            "tool", "--bearer", "one", "--auth", "two", "--port", "80"
        ])

        XCTAssertEqual(
            redacted.arguments,
            ["tool", "--bearer", "<redacted>", "--auth", "<redacted>", "--port", "80"]
        )
        XCTAssertEqual(redacted.redactedCount, 2)
    }

    /// An ordinary command line passes through untouched, and says so: a zero count is what
    /// tells the row it has no reveal to offer.
    func testAnInnocentCommandLineIsUntouched() {
        let arguments = ["node", "server.js", "--port", "3000", "--verbose"]
        let redacted = CommandLineRedactor.redact(arguments)

        XCTAssertEqual(redacted.arguments, arguments)
        XCTAssertEqual(redacted.redactedCount, 0)
    }

    /// A credential flag as the last argument has no value to hide, and inventing one would
    /// miscount what was redacted.
    func testATrailingCredentialFlagRedactsNothing() {
        let redacted = CommandLineRedactor.redact(["tool", "--token"])

        XCTAssertEqual(redacted.arguments, ["tool", "--token"])
        XCTAssertEqual(redacted.redactedCount, 0)
    }

    /// Re-redacting an already redacted line changes nothing — the panel re-renders the same
    /// cached vector every rebuild, and drift here would be drift on screen.
    func testRedactionIsIdempotent() {
        let once = CommandLineRedactor.redact(["--token", "abc", "--api-key=v", "PIN=1234"])
        let twice = CommandLineRedactor.redact(once.arguments)

        XCTAssertEqual(once.arguments, twice.arguments)
        XCTAssertEqual(once.redactedCount, twice.redactedCount)
    }

    func testMixedFormsAreEachCounted() {
        let redacted = CommandLineRedactor.redact(
            ["run", "--token", "a", "--client-secret=b", "SESSION_TOKEN=c", "--port", "80"]
        )

        XCTAssertEqual(
            redacted.arguments,
            ["run", "--token", "<redacted>", "--client-secret=<redacted>", "SESSION_TOKEN=<redacted>", "--port", "80"]
        )
        XCTAssertEqual(redacted.redactedCount, 3)
    }

    /// The vocabulary is shared with the execution audit, normalization included, so the two
    /// surfaces can never disagree about what a credential key is.
    func testTheVocabularyNormalizesSpellings() {
        XCTAssertTrue(CredentialVocabulary.isCredentialKey("X-Api-Key"))
        XCTAssertTrue(CredentialVocabulary.isCredentialKey("ACCESS_TOKEN"))
        XCTAssertTrue(CredentialVocabulary.isCredentialKey("githubToken"))
        XCTAssertTrue(CredentialVocabulary.isCredentialKey("AWS_SECRET_ACCESS_KEY"))
        XCTAssertTrue(CredentialVocabulary.isCredentialKey("password"))
        XCTAssertTrue(CredentialVocabulary.isSensitiveURLQueryKey("oauthCode"))
        XCTAssertFalse(CredentialVocabulary.isCredentialKey("sourceCode"))
        XCTAssertFalse(CredentialVocabulary.isCredentialKey("mapping"))
        XCTAssertFalse(CredentialVocabulary.isCredentialKey("spinner"))
        XCTAssertFalse(CredentialVocabulary.isCredentialKey("port"))
        XCTAssertFalse(CredentialVocabulary.isCredentialKey("verbose"))
    }
}
