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

The `codex-update-status-*` pair replays the minimized fresh/resume exchange behind the file-change
and relaunch journey. The `codex-stop-turn-*` pair adds the host-driven interrupt exchange behind
the Stop-and-continue journey. Each fresh tape has a matching resume tape because the application
chooses that process contract from durable session state before it starts the provider.

`codex-question-fresh` and `codex-question-resume` are synthetic fixtures authored against the
installed Codex 0.154.0 generated app-server schema. The fresh tape waits for two exact question
answers before writing its receipt and completing the turn; no real provider runs in this journey.

`codex-browser-annotations-fresh` accepts two annotation turns from the browser's counted Send
button and Command-Return. Each accepted request writes a separate sandbox receipt; the hosted
component tests assert the exact note, URL and coordinate payload. It uses the existing thread-1
resume fixture only to satisfy the shared bootstrap contract; this journey does not relaunch.
