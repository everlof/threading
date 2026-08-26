# SSH remote hosts and SFTP attachment sources

> Status: feature draft — the independently useful first slice is a host-owned SFTP source in
> the macOS and iPhone composers. The Mac owns the SSH connection, host trust, credentials,
> transfer and final file custody; iPhone browses it through the existing paired-owner protocol.
> A later remote-execution slice may reuse the same host profile, but no SSH/SFTP dependency has
> been adopted and nothing here is scheduled.

Part of the [drafts index](README.md). Read alongside
[`media-documents.md`](../architecture/media-documents.md) (attachment admission, custody and
preview), [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md) (the iPhone's authorization and wire
boundary), [`reliability-and-type-safety.md`](../architecture/reliability-and-type-safety.md)
(external failures, concurrency and bounds), and
[`performance.md`](../architecture/performance.md#implementation-time-scaling-gate) (directory
and file-list scaling).

**The one-sentence version.** Let a person choose a file from an SFTP server exactly where they
currently choose a photo or local document, copy the chosen bytes into the session's own
attachment store before sending, and later reuse the same trusted SSH host profile to run agents
on a remote machine without replacing Threading's remote-companion protocol.

---

## Decision

Build one **SSH host profile** and expose its SFTP filesystem as a built-in attachment source.

- The macOS app opens SSH/SFTP connections and owns credentials and host-key trust.
- The Mac composer can browse a saved host directly.
- A paired iPhone can browse the same saved sources through new owner-only, bounded remote routes.
  It never receives the password, private key, host key, absolute remote path, or an SFTP socket.
- Selecting a file starts a bounded transfer into private Mac-side staging. Only a completed,
  validated, session-owned local copy becomes a composer attachment.
- The agent receives the ordinary quoted local attachment path. It does not receive an SFTP URL,
  credential, server name, or path that may disappear after the turn.
- The first slice is a chooser, not a file manager: browse, select, transfer, retry, cancel. It
  does not delete, rename, edit, synchronize, recursively copy, or mount remote filesystems.
- The current browser/iPhone companion transport remains the semantic Threading protocol over its
  existing authenticated routes. SSH is a future execution-host transport, not a replacement for
  conversation roles, permission cards, presence, notifications, Git Review or attachment DTOs.

This ordering makes SFTP useful before the much larger remote-execution project and proves the
hard shared seam — host identity, authentication, connection lifecycle and bounded file transfer
— against a surface people can use on its own.

## User problem

Threading can take a photo, a local document, a dropped file, pasted bytes, or a file uploaded by
a paired phone. It cannot take the file that already lives where much development work happens:
a NAS, build host, home server, Linux workstation or managed SSH machine.

Today the person has to leave the composer, open another SFTP client, download the file, find the
local copy, return to Threading and attach it. On iPhone that often means configuring a second app
and moving bytes through Files merely to send them back to the Mac that owns the chat.

Concrete cases:

1. Attach a remote build log, crash archive or generated report to a Claude/Codex prompt.
2. Pull a screenshot, design export, dataset sample or document from a NAS while composing on the
   phone.
3. Select a file produced by a remote agent host without first deciding where to download it.
4. Reuse a trusted host later when Threading can launch and supervise an agent on that machine.

The product promise is **choose there, use here**. It is not “the agent can read this server” and
it is not “this remote path is now part of the project.”

## Product shape

### Saved SSH hosts

Settings gains a host-owned **SSH Hosts** section. A profile contains non-secret connection
metadata: stable ID, display name, host, port, username, optional starting directory and enabled
capabilities. Passwords, imported private keys and key passphrases are separate app-owned secrets.

Adding a host follows an explicit trust sequence:

1. enter host, port and username;
2. connect with a deadline and obtain the server host key;
3. show key type and SHA-256 fingerprint before saving trust;
4. authenticate with password or an explicitly imported OpenSSH private key; and
5. verify that the SFTP subsystem can open before advertising the source to a composer.

There is no `acceptAnything` path, including in a first-run convenience flow. A changed host key
is a named blocking state with the old and new fingerprints and an explicit replace-trust action.
Authentication failure never rewrites the saved credential automatically. Threading does not scan
`~/.ssh/id_*`, read every Keychain SSH item, import `~/.ssh/config`, enable Remote Login, or ask a
person to weaken a server's algorithms. Explicit import and later config discovery are separate
features.

Trust, authentication and reachability are three states. A host may be trusted but offline, or
reachable with an expired password. The settings row and picker render those facts separately
rather than collapsing them into “Connection failed.”

### Choosing an SFTP attachment

The Mac paperclip/source menu and the iPhone photo/document menu gain **SFTP** when at least one
eligible saved host exists. Choosing it opens:

```text
SFTP
├── Build server
├── Home NAS
└── Add SSH Host…              macOS only in the first slice

Build server / reports / nightly
├── app-crash-2026-08-26.zip       8.4 MB
├── integration.log               1.2 MB
└── screenshots/
```

The directory surface is lazy and cursor-paged. It shows name, directory/file kind, bounded size
and modification metadata when the server supplies them. It does not prefetch file contents or
construct one view per remote entry. Search filters entries already loaded in the first slice; a
server-side or bounded recursive search is later work, never an unbounded walk disguised behind a
result cap.

Selecting files reserves composer slots and creates visible transfer chips. A chip has one of
these exact states:

- **Waiting** — queued behind the bounded transfer limit;
- **Downloading** — byte progress when a trustworthy size exists, otherwise indeterminate with a
  transferred-byte reading;
- **Checking** — the complete local staging file is being classified and admitted;
- **Ready** — a session-owned attachment exists and can be sent or scheduled;
- **Needs attention** — typed failure with Retry and Remove; or
- **Cancelled** — removed from the composer and staging.

Send stays unavailable while a selected file is waiting, downloading, checking or failed. A
person who chose three files and pressed Send meant to send all three; silently omitting a failed
one is not recovery. Removing the failed item makes the remaining ready set sendable.

The existing composer owns order, drafts and submission. SFTP contributes another source of
bytes; it does not insert an `sftp://…` string into the editor or gain a second Send path.

### Custody before reference

An SFTP entry is not an attachment. The transition is:

```text
remote entry handle
        ↓  bounded SFTP read
unpublished Mac staging file
        ↓  size/type/name validation
session-owned attachment
        ↓  ordinary ComposerAttachmentHandover
quoted local path in the submitted prompt
```

The distinction is load-bearing:

- the remote server can disconnect, rotate credentials, replace the file or disappear after the
  user sends;
- scheduled messages may run hours later;
- attachments must remain visible in the session chronology and preview pane; and
- neither a guest nor an agent should be able to replay a remote path to fetch different bytes.

The transfer opens the selected file from the opaque entry handle, enforces the byte ceiling while
streaming rather than trusting the initial `stat`, writes to a unique unpublished file, validates
the completed bytes through the same host-owned classification used by local and phone
attachments, and only then moves them into session custody.

`ComposerAttachmentHandover.handOver` currently has a useful local fallback: if custody fails, it
can return the original local path because that file may still work. That fallback is invalid for
SFTP. The implementation needs a strict custody door whose failure leaves no attachment and no
remote spelling in the prompt.

An abandoned transfer has a short lease and is reaped with its bytes. Completed custody follows
the session's existing attachment lifetime. A scheduled message can be created only after the
copy is Ready; it never performs a deferred SFTP fetch at send time.

### iPhone route

ThreadingMobile remains a companion to the paired Mac. The Mac advertises SFTP attachment sources
only to a paired owner device with `allSessions` and interactive authority. Collaborators and
one-chat guests cannot enumerate a filesystem merely because they may write in one conversation.

The wire vocabulary is additive and tolerant of older clients:

| Value | Meaning |
|---|---|
| `RemoteSFTPSourceSummaryDTO` | Opaque source ID, display name and availability; no host or username required |
| `RemoteSFTPDirectoryPageDTO` | Bounded entries plus an opaque next cursor and explicit completeness |
| `RemoteSFTPEntryDTO` | Opaque entry ID, display name, kind, optional size/date; no absolute path |
| `RemoteSFTPSelectionRequestDTO` | Session ID, entry IDs and an idempotent request ID |
| `RemoteAttachmentTransferDTO` | Stable transfer ID, progress and typed terminal state |

Entry and cursor handles are bound to owner device, host profile, connection generation and a
short expiry. Selection revalidates the handle and file kind; a stale or replaced entry is refused
rather than interpreted as a new path. Remote errors use stable codes and localized client copy,
not server messages that may contain paths or account details.

The iPhone never carries SFTP bytes. The Mac downloads directly from the SFTP host and publishes
transfer state over the existing remote connection. This avoids duplicate credential stores,
duplicate host trust, raw-socket background claims and a second route into the session attachment
store. It also matches the product reality: if the Mac is unavailable, the chat and its agent are
unavailable too.

The phone cannot add a host, replace a changed host key or update a credential in the first slice.
Those are Mac-local security decisions. Its recovery action opens compact guidance to review the
named source under SSH Hosts on the Mac rather than offering a remote “trust this key” shortcut.

An independent iOS SFTP client can be reconsidered only with a use case that works while the Mac
is absent. It is not needed to make SFTP available in the current iPhone app.

## Architecture

### Boundaries and ownership

```text
macOS composer ───────────────┐
                             ├─ SFTPAttachmentSourceCoordinator
iPhone owner picker ─ wire ──┘              │
                                             ├─ SSHHostProfileStore (metadata)
                                             ├─ SSHSecretStore (credentials)
                                             ├─ SSHHostTrustStore
                                             └─ SFTPConnectionPool / transfer actors
                                                            │
                                                            ▼
                                                unpublished staging
                                                            │
                                                            ▼
                                               SessionAttachmentStore
                                                            │
                                                            ▼
                                               existing composer submission
```

The dependency wrapper sits behind Threading-owned protocols. UI does not import NIO, Citadel,
libssh or SFTP packet types. `ThreadingRemoteKit` receives only Foundation-only DTOs and policy
values that Mac and iPhone must share; it does not become the SSH engine.

Split an implementation package only if the dependency graph and test isolation justify it after
the spike. A plausible shape is a local `ThreadingSSHKit` containing connection/authentication,
host-key normalization and SFTP adapters, with app-owned profile/custody policy above it. Starting
with a protocol boundary inside `Core/SSH` is also valid; a package is not a substitute for the
boundary.

One actor or named serial executor owns each SSH connection and its SFTP channels. Immutable entry,
page, progress and failure values cross to application and UI layers as `Sendable`. Cancellation
closes the file handle and staging writer exactly once. Every connect, authenticate, directory
read, file open, file read and close has a deadline or participates in a parent operation that
does.

### Scaling contract

Expected directories contain 10–500 entries; stress directories contain 20,000. Expected selected
files are 1–3; the composer policy is the hard aggregate bound. File sizes and directory sizes are
external and therefore unbounded until Threading applies its own limits.

- Directory enumeration is incremental from the SFTP directory handle. One page contains a named,
  small number of value entries; an output cap is not implemented by first reading the directory.
- The picker virtualizes rows and owns O(visible) views. Loading another page appends stable entry
  identities rather than rebuilding the tree.
- At most a small fixed number of directory handles, host connections and transfers exist at once.
  The spike must measure a useful value; initial candidates are two active transfers per host and
  four globally.
- Progress is coalesced to a human-visible cadence. A network read callback never dispatches one
  main-actor mutation per packet.
- File bytes stream from SFTP to an opened staging handle. They are never accumulated as one `Data`
  value merely because the final attachment has a byte ceiling.
- Preview probing and custody remain off-main under the existing attachment rules.
- A deterministic fake with delayed pages, a 20,000-entry directory, slow reads, unknown sizes and
  mid-transfer replacement is required before the surface ships.

The exact per-file ceiling is a rollout gate. It must be no larger than the session attachment and
remote transport paths can validate without whole-file memory. The existing phone upload starts
at 24 MiB and eight files per message; the implementation should reuse authoritative policy rather
than introduce a second set of almost-equal constants.

### Security and privacy

- Credentials are stored through an app-owned Keychain seam and are never logged, put in
  `UserDefaults`, serialized into a profile, sent to iPhone, exposed to an extension, or passed to
  an agent.
- Host keys are validated before authentication. Changed keys fail closed. Fingerprints may appear
  in the trust UI but not ordinary support reports.
- Password and private-key authentication are the first candidate methods. Keyboard-interactive,
  certificates, security keys, agent forwarding and jump hosts are separate compatibility slices.
- The server's path and error text are private. UI may show the user the relative directory they
  are deliberately browsing; the agent and ordinary diagnostics receive neither.
- Symlinks are not followed in the first attachment picker. A selected entry is opened only after
  revalidating that it is a regular file.
- Names are sanitized for local custody without pretending the sanitized name identifies the
  remote object. Stable attachment identity remains the store's opaque ID.
- Partial bytes are unpublished and reaped. A failed validation cannot leave an executable or
  unsupported file in the session under a friendly extension.
- SFTP browsing is user-driven and has no MCP or agent tool in the first slice. An agent may ask
  for a file, but it cannot enumerate sources or manufacture an entry handle.
- Remote iPhone routes authorize again at dispatch. Hiding the SFTP button on an ineligible client
  is presentation, not enforcement.
- Dependency adoption requires license notices, advisory scanning, a macOS cryptography/export
  review and an exact release-build bundle inspection. The iOS archive must separately prove that
  the Mac-only engine and its crypto did not enter the mobile bundle; direct iOS support would
  reopen its export determination.

### Customization-surface gate

The initial SFTP host editor, trust prompt and attachment picker are deliberately **host-only**.
They present and mutate security truth: which server is trusted, which credential is used, which
remote file is selected, whether all bytes arrived, and which local attachment will be sent.
Allowing a replacement presentation could claim a changed key is trusted or a failed file is
attached when the host says otherwise.

Threading retains connection identity, host-key decisions, credential collection, authorization,
selection handles, transfer progress, cancellation, admission, custody, composer order and Send
eligibility. The existing composer accessory contracts remain available around the native
composer; they do not replace this flow.

An internal `AttachmentSource` protocol is still worthwhile so Photos, Files, paste/drop and SFTP
converge at selection and custody. It is not a public extension capability in this slice. A future
public source needs a separately reviewed brokered-content authority and must never turn UI
composition into credential or filesystem access.

## Remote execution later

SFTP attachment selection and remote agent execution share a host profile, but not a runtime
contract. SFTP alone cannot provide a PTY, signals, environment, process lifecycle, Git operations,
provider login discovery, tool routing or durable supervision.

A future remote-execution host should use SSH to authenticate and bootstrap or reach a small
versioned Threading helper. The helper owns the remote PTY and process, while a typed protocol over
an SSH channel carries lifecycle, input/output, resize, exit and control events. The Mac remains
the authority for Threading projects, sessions, roles, presentation and policy. Git and agent CLIs
execute on the remote host against its checkout; Threading does not simulate a local repository by
syncing files over SFTP.

The current remote companion remains in front of that Mac authority:

```text
iPhone / browser ── Threading remote protocol ── Mac ── SSH ── remote execution helper
```

That is the useful composition. Replacing the left-hand protocol with SSH would still require all
of its semantic messages and would trade QR pairing and scoped conversation roles for a Unix
account. Scraping a remote Claude/Codex TUI over SSH would also discard the native conversation and
permission structures Threading already has.

Remote execution is a later project with its own acceptance matrix and estimated effort measured
in months. It must not enlarge the SFTP attachment slice until both become unshippable.

## Dependency research, 2026-08-26

No library is selected. The implementation begins with a compatibility and lifecycle spike.

| Candidate | What it provides | Current issue for Threading |
|---|---|---|
| [Apple SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) | Maintained SSHv2 building blocks, session/exec/forwarding, password and public-key auth | Explicitly does not ship a production-ready client; no SFTP client layer. Building both high-level client and SFTP here is too much protocol ownership. |
| [Citadel](https://github.com/orlandos-nl/Citadel) | MIT, high-level NIOSSH client, SFTP operations and host-key validator seam | Current manifest requires macOS 14 while Threading supports macOS 13 and depends on a forked NIOSSH line. Lifecycle, algorithms, key parsing and platform lowering need proof before adoption. |
| [mft](https://github.com/mplpl/mft) | Broad SFTP client operations on macOS/iOS through bundled libssh/OpenSSL | LGPL and prebuilt C crypto expand licensing, binary provenance, advisory and export-compliance work. Keep as an interoperability/reference candidate, not the default. |
| `/usr/bin/ssh` / `sftp` | Uses the Mac's OpenSSH configuration and compatibility | No iOS implementation; parsing an interactive CLI is not a typed file API. Potentially useful for bootstrapping a later remote helper, not for the cross-platform picker engine. |

The spike must build against macOS 13 and a physical iOS release configuration even though iPhone
does not initially link the engine; verify that keeping SSH Mac-only is real in the final mobile
bundle. Exercise repeated connect/close, cancellation during authentication and transfer, changed
host keys, password and encrypted key auth, large directory paging, connection loss and clean
event-loop shutdown. Run the repository's dependency/license/advisory audit before accepting a
candidate, not after UI work depends on it.

## Rejected alternatives

### Replace Threading remote access with SSH

Rejected. SSH could secure a byte channel but would not replace the application protocol for
session catalogues, roles, native messages, permissions, presence, drafts, input control,
notifications, attachments, Git Review, browser previews or extension panels. Browser clients
would need a gateway and phone pairing would become Unix-account provisioning.

### Connect to SFTP directly from iPhone

Rejected for the first slice. It duplicates profiles, secrets, host trust, diagnostics and network
lifecycle, and raw SFTP cannot make the system-managed background-transfer promise available to
HTTP `URLSession` tasks. The paired Mac already has to be alive to own the chat. Broker through it.

### Keep an SFTP URL as the attachment

Rejected. It leaks server identity/path, depends on future credentials and availability, lets
bytes change after selection, breaks scheduled messages and gives the agent a network authority
the user did not grant.

### Mount the server or mirror it into the project

Rejected. FUSE is not an iPhone answer, path and watcher semantics differ across servers, and an
SFTP mount turns every local filesystem assumption into a network operation. Remote execution
should run against the remote checkout rather than pretending it is local.

### Ship a general SFTP file manager first

Rejected. Delete, rename, recursive transfer, overwrite conflict, permissions and synchronization
multiply destructive and recovery states without improving the core chat flow. The attachment
source is narrow, reversible and useful.

## Delivery slices

### 0. Dependency and interoperability spike

- Choose or reject a high-level client behind Threading-owned protocols.
- Preserve the macOS 13 deployment target unless a separate product decision changes it.
- Produce a supported authentication/algorithm matrix rather than claiming “works with SSH.”
- Verify teardown, bounded streaming, deadlines and cancellation under repeated connections.
- Complete license, advisory, cryptography/export and bundle reviews.

Exit: one command-line test target connects to controlled OpenSSH fixtures, validates/pins a host
key, pages a directory, streams a bounded file, cancels it and exits with no retained threads or
descriptors.

### A. macOS SFTP attachment source

- Add profile, secret and trust stores with corruption/failure states.
- Add the connection/transfer coordinator and strict custody door.
- Add host settings, trust/authentication flow and the composer picker through Design components.
- Reuse attachment classification, session custody, draft ownership and submission.
- Keep destructive SFTP operations absent.

Exit: a person selects remote files, sees accurate progress/failure, sends or schedules only
session-owned copies, relaunches, and can still preview what was sent with the server offline.

### B. Paired-iPhone source

- Add tolerant DTOs, source/directory/selection routes and typed progress events.
- Authorize only paired owner devices and bind every opaque handle to its authority/generation.
- Add the themed iPhone source and directory surfaces using the Mac's profiles.
- Add route-loss/reconnect behavior without restarting or duplicating accepted transfers.

Exit: the physical iPhone chooses a file from a Mac-owned SFTP source over LAN and Hosted Direct,
the Mac takes custody once, and an old phone continues without seeing the unsupported source.

### C. Remote execution host

Start a separate implementation plan after the attachment source has proved the host profile and
SSH lifecycle. Define helper installation/versioning, PTY ownership, agent/provider discovery,
remote checkout identity, reconnect/durability, permissions and recovery before changing session
launching. SFTP may move bounded setup artifacts; it is not the runtime protocol.

## Verification

- Pure model tests for profile validation, trust transitions, availability and typed failures.
- Keychain/store tests for missing, corrupt, newer-version, update and delete behavior without
  touching the developer's real credentials.
- Adapter tests against controlled OpenSSH servers for supported host keys/authentication, paging,
  regular files, refused symlinks, unknown sizes, partial reads, cancellation and teardown.
- Stress fixture for 20,000 directory entries with O(visible) views and bounded enumeration work.
- Transfer tests for size growth past the ceiling, name collisions, same-name/different-file,
  content-probe refusal, staging cleanup, retry and all-selected-files Send gating.
- Remote integration tests for owner/guest refusal, expired/foreign handles, idempotent selection,
  older-client decoding and reconnect progress.
- macOS and physical-iPhone UI evidence for no-host, first trust, changed key, empty directory,
  large directory, transfer, failure, retry, Ready and offline-after-custody states in light/dark
  themes, Dynamic Type and VoiceOver.
- Shipping-path checks include fast/all tests, package tests, architecture/theme/localization
  gates, release builds, bundled license notices and the dependency/export audit.

## Effort and gates

The SFTP attachment feature is roughly **8–11 engineer-weeks** with the Mac-brokered iPhone
architecture: one week for the dependency spike, three to four for profiles/trust/streaming and
custody, two for the two native surfaces and wire path, and two to four for compatibility,
failure, evidence and release hardening. A direct independent iOS client or general file-manager
operations move it toward 12–18 weeks.

Remote execution remains a separate **four-to-eight-month** project until a narrower implementation
plan proves otherwise.

Named gates before implementation is called ready:

1. choose a dependency that passes lifecycle/interop tests and preserves the supported deployment
   and license/export posture;
2. choose the exact per-file and aggregate transfer ceilings from a measured stress case;
3. decide the v1 authentication matrix, explicitly listing what is unsupported;
4. threat-model host-key persistence and replacement; and
5. verify the Mac-brokered iPhone route on a physical device and at least one non-OpenSSH SFTP
   server before calling compatibility broad.
