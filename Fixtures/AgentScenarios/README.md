# Agent scenario tapes

Committed tapes in this directory are deterministic provider-wire fixtures for application-level
UI scenarios. They are not transcripts and must not contain user repositories, home-directory
paths, credentials, provider tokens, or raw recordings that have not passed the scenario privacy
audit.

The format and validator live in `Packages/ThreadingScenarioKit`. Validate a tape with:

```bash
swift run --package-path Packages/ThreadingScenarioKit threading-scenario validate \
  Fixtures/AgentScenarios/example.json
```

Record against a disposable synthetic repository. Normalize dynamic identifiers and paths to the
format's fixed placeholders while their meanings are still known. A recording is evidence used to
author a scenario, not permission to commit every byte the provider happened to emit.

No tape is committed yet. The first recorded fixture should arrive with the mock-agent replay
process and a UI journey that consumes it.
