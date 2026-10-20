# Managed agent clients

Threading owns the local client version and executable path for Claude Code, Codex, Grok,
OpenCode and Cursor. Provider accounts, configuration and conversations keep their existing
locations. This is a local macOS installation boundary; remote hosts retain their own clients.

## Why selection belongs to the app

A support report showed Claude exiting 127 immediately without captured output. The old path
could establish that a file was executable but still launched the bare command through the
user's login shell. A failed shell, interpreter, profile or different PATH could therefore
prevent startup before the provider printed anything. The report alone does not identify which
of those failed.

`AgentLocalLaunch` is configured by the application composition root before restoring sessions.
`ManagedAgentRuntimeStore` resolves the actual executable word in `ShellCommand`, including
account-routing `env` prefixes. It never searches a prompt or reparses shell source. Local
terminal, stream, research, export, archive and discovery commands use the same resolver, as do
account setup and version probes. Remote command builders do not use this store.

The resolved command runs through `/bin/sh -c`, with an absolute executable and quoted words,
without loading a shell profile. A bounded login-shell probe separately supplies the project's
PATH. Its last successful bounded value is retained for immediate launches after app restart.
If a probe fails, that value remains available; without one, the inherited or system PATH is
used. None of these values can change which client launches. Codex's packaged `codex-path` directory is also supplied for its ripgrep helper.
An absent or invalid receipt resolves to a missing private path, never an ambient command.
Restored and scheduled chats also refuse an unconfigured client before spawning and carry the
selected path in an actionable installation failure, even when the composer was bypassed.

## Publisher artifacts and activation

`ManagedAgentCatalog` pins the Apple Silicon artifact URL, digest, version and executable for
every provider. The pinned Cursor runtime requires macOS 13.5; the other clients require
macOS 13.0. Unsupported systems are refused before downloading. Four are official native npm artifacts; npm itself is never run. Cursor's
archive includes its Node runtime. Grok's native executable is Brotli compressed; a separately
pinned Node distribution is downloaded into staging solely to decompress it. Only `bin/node`
is extracted, and staging is removed afterwards. No global package prefix or shell profile is
changed.

Relevant publisher documentation:

- [Claude setup](https://code.claude.com/docs/en/setup)
- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Grok CLI package](https://www.npmjs.com/package/@xai-official/grok)
- [OpenCode CLI environment](https://opencode.ai/docs/cli/#environment-variables)
- [Cursor CLI installation](https://cursor.com/docs/cli/installation)

Installation is explicit and on demand. One installation or rollback runs per store at a time.
The worker streams the download, checks the pinned digest, validates archive paths, entry kinds
and expanded size before extracting, and runs the executable's version command in a scratch
home with a system-only PATH. Symlinks, hard links and special files are refused.

After verification, the payload moves to a fresh UUID directory beneath
`~/Library/Application Support/Threading/AgentTools/<provider>/`. Its
`.threading-installation.json` identifies the release. `active.json` is written atomically and
names both the active and previous generation. The receipt is the commit point. Cancellation,
download errors, integrity failures and unsuccessful verification leave the old selection intact.
A verified reinstall can replace an invalid receipt. An interrupted activation can leave an
unselected generation, never a partly selected payload.

Running processes retain their original generation. Installation never overwrites or removes an
existing generation, including ones a detached PTY host could still be using. Rollback verifies
the previous executable before atomically swapping the two receipt entries. The inventory is
capped at eight generations per provider; the installer refuses before adding a ninth. Settings'
Show Installation Folder exposes retained generations for deliberate removal after their agents
have stopped. Account data is outside this tree.

## Selection, updates and presentation

Settings ▸ General ▸ Agent tools exposes all five providers, their selected version, install or
reinstall, previous-version restore, and an explicit external-executable picker. An external
choice is verified before its absolute path is saved in `PreferenceStore`; it does not rewrite
the managed receipt. Use Managed Installation switches back to a retained managed generation.

Managed update checks compare against the catalog shipped in the app. A new pin therefore ships
with a Threading release and is tested before it is offered. Claude, Grok and OpenCode receive
their documented update-disable environment; Cursor receives `--disable-auto-update` before its
subcommand; Codex launch commands already disable startup update checks. External selections
keep the existing publisher update path. The terminal update planner refuses managed selections,
so an outdated or mixed notice cannot run a vendor self-updater against a private generation.

The install sheet is shared by onboarding, missing-client recovery and settings. Opening it does
not download anything. Install starts the worker; Cancel cancels staging. The host owns artifact
trust, executable selection, account separation, activation and recovery. This is deliberately
host-only UI, with themed controls and a design-layer wrapper around the system file picker.

## Bounds and verification

The inventory is fixed at five providers. Downloads are capped at 512 MiB, archive listings at
2 MiB and 8,192 entries, expanded packages at 2 GiB, and receipts at 32 KiB. Version verification
has a 20-second deadline and a 16 KiB output cap. File, archive, hashing, network and process work
run on workers. Launch planning reads only cached receipts and selection preferences. Receipt
reload and activation serialize disk access so an older refresh cannot overwrite a new selection.

`ManagedAgentRuntimeTests` covers quoted path selection, absence without PATH fallback, real
child launch, verification failures, cancellation, receipt refusal, reinstall and rollback.
`AgentCLISettingsTests` captures the shipping settings shell and attached installer.
`ManagedAgentJourneyUITests` drives rollback through the real settings menu, relaunches the app
to prove persistence, and opens and cancels a reinstall without changing the selected generation.

Opt in to real publisher download, extraction and launch verification with:

```bash
THREADING_MANAGED_AGENT_LIVE_TESTS=1 scripts/test.sh fast \
  -only-testing:ThreadingTests/ManagedAgentRuntimeTests/testAllPinnedPublisherArtifactsInstallAndLaunchWithoutGlobalRuntime
```

This uses a disposable installation root and no account credentials. A catalog pin change also
requires an authentication-free native-protocol initialization check where supported, plus the
provider's existing adapter tests. Version output alone does not prove conversation compatibility.
