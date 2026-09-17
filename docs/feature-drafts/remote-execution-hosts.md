# Remote execution hosts

> Status: feature draft — slice 1 (a Linux build of `threading-ptyd`) builds and passes its
> suite on Linux; its durable decisions are in [`pty-host.md`](../architecture/pty-host.md#linux).
> Nothing else has started. This is the implementation plan for slice C of
> [SSH remote hosts and SFTP attachment sources](ssh-remote-hosts-and-sftp-attachments.md#c-remote-execution-host),
> pulled forward and cut so its first slices do not wait on SFTP.

Part of the [drafts index](README.md). Read alongside [`pty-host.md`](../architecture/pty-host.md)
(the daemon this reuses), [`session-activity.md`](../architecture/session-activity.md) (hooks and
the bridge socket), [`mcp-and-display.md`](../architecture/mcp-and-display.md) (tool routing by
session token), [`sessions.md`](../architecture/sessions.md) (launching and resuming) and
[`reliability-and-type-safety.md`](../architecture/reliability-and-type-safety.md).

**The one-sentence version.** Let a session's agent run on a Linux machine the person owns — a
Raspberry Pi, a Hetzner or Lightsail VPS, a workstation — by running `threading-ptyd` there,
reaching it over SSH, and keeping the Mac the authority for projects, sessions, policy and every
surface.

---

## Decision

- **The execution host is any Linux machine with `sshd`**, `aarch64` or `x86_64`. A Pi, a VPS and
  a spare workstation are the same case; nothing here is vendor-specific.
- **The Mac stays the authority.** Projects, sessions, roles, presentation, permission policy,
  scheduled work and the paired iPhone remain on the Mac. The remote machine owns only processes
  and the checkout they run in.
- **The PTY host protocol is the execution protocol.** `threading-ptyd` already owns a child, its
  ring, its window size and its exit, speaks a versioned framed protocol, refuses an incompatible
  peer, and replays exactly what a detached watcher missed. A remote host is the same daemon
  reached through a forwarded unix socket instead of a local one. No second protocol.
- **SSH is transport and authentication only.** It does not replace the Threading remote protocol
  the iPhone speaks, and Threading does not scrape a remote TUI.
- **Unsupported is a refusal, not a lookalike.** A remote session that cannot offer Git Review,
  transcript replay or usage reading says so through a host capability, the same way
  `AgentKind.capabilities` refuses what a runtime cannot do.

This is **not** [Native Linux host and UI](linux-host-runtime.md). No AppKit code moves and no
Linux UI is built.

## What already exists

| Asset | Why it matters here |
| --- | --- |
| `Targets/PTYHost` (`threading-ptyd`) | Session outlives its watcher; exact rejoin after a disconnect is the Mac-sleeps/Wi-Fi-drops case. Imports only Foundation, Darwin, Dispatch and the wire package. |
| `Packages/ThreadingPTYHostKit` | Foundation-only framing, frames and version gate, shared by both ends. |
| `.pipes` channel | Native conversations already run their CLI in the daemon over three pipes, so stream-JSON transports can run remotely unchanged. |
| `MCPBridgeDefaults` socket + `threading-mcp-bridge` | Hooks and MCP already address a unix socket through `$THREADING_MCP_SOCKET`, which SSH can forward in reverse. |
| Host-profile design | The SSH draft already settles trust, authentication and reachability as three separate states. |

## The gaps, in delivery order

### 1. `threading-ptyd` builds and passes on Linux

The daemon's platform surface is small and named:

| Darwin today | Linux |
| --- | --- |
| `import Darwin`, `Darwin.close/read/write/kill/bind/connect/shutdown` | `Glibc`/`Musl`, through one `PTYHostPOSIX` shim so call sites stay platform-neutral |
| `proc_pidinfo(PROC_PIDTBSDINFO)` start time | `/proc/<pid>/stat` field 22 (ticks since boot) plus `/proc/stat` `btime` |
| `DispatchSource.makeProcessSource(.exit)` | a read source on a `pidfd_open` descriptor (Linux ≥ 5.3), polling `waitpid` where no pidfd can be opened; `waitpid` is unchanged |
| `POSIX_SPAWN_CLOEXEC_DEFAULT` | every daemon descriptor created close-on-exec (`pipe2(O_CLOEXEC)`); the flag does not exist |
| `sockaddr_un.sun_len`, `SO_NOSIGPIPE` | absent; the process-wide `SIGPIPE` ignore is the whole guard |
| `forkpty`, `TIOCSWINSZ` ioctl, `pipe2` | the same calls, reached through a small C shim so glibc and musl agree |
| launchd / `SMAppService` registration | a `systemd --user` unit, with `loginctl enable-linger` on a headless box |

The artifact is one **statically linked** binary per architecture built with the Swift Static Linux
SDK (musl), so the same file runs on Raspberry Pi OS, Debian, Ubuntu and Alpine with nothing
installed. The Linux build uses a SwiftPM manifest beside the daemon sources
(`Targets/PTYHost/Package.swift`); the Xcode project remains the only build of the app and of the
macOS daemon.

**Verification environment.** A Linux container under Docker Desktop is enough for this slice: it
is a real Linux kernel (in Apple's virtualization framework, native `arm64`), has `/dev/ptmx` and
`pidfd`, and starts in seconds. `scripts/test-ptyd-linux.sh` builds the daemon there, runs the
`ThreadingPTYHostKit` tests on Linux, and runs daemon integration tests that speak the real wire
protocol: spawn, output, resize raising `SIGWINCH`, detach and exact replay, pipes, kill of the
whole group, exit status, restart recovery. `x86_64` runs the same lane with
`--platform linux/amd64`. A full VM (QEMU, Lima or a real Pi) is only needed from slice 2, for
`systemd --user`, linger and a real `sshd`.

Done when the macOS daemon tests are unchanged and green, and the Linux lane passes on both
architectures.

**Result, 2026-09-17.** macOS: the hosted daemon suites through Xcode, 68 tests, green (one opt-in
stress case skipped as designed), and the same suite through SwiftPM. Linux arm64 native and
x86_64 emulated (Docker Desktop, kernel 6.12, Swift 6.3.2), each: 77 `ThreadingPTYHostKit` tests,
30 package tests (25 daemon, 5 `/proc`) and the 25 daemon tests again against the stripped static
binary (57 MB and 59 MB), none skipped. The lane
needs a watchdog for an open swift-corelibs-xctest deadlock; see
[`pty-host.md`](../architecture/pty-host.md#linux). The static binary is large because of
Foundation's ICU data; moving the daemon to `FoundationEssentials` is a follow-up if install size
matters.

### 2. Host profiles, helper install and the forwarded socket

- The SSH host profile, trust and credential model from the SSH draft — adopted here first rather
  than after SFTP. Dependency selection is that draft's gate 1 and applies unchanged.
- Install: detect `uname -m`, copy the matching static binary to
  `~/.local/lib/threading/<generation>/threading-ptyd`, install the user unit, check linger.
  The generation directory makes upgrade the existing `retire` handshake: the old daemon drains,
  the new one binds.
- Transport: forward the remote `ptyd.sock` to a Mac-local `0700` path
  (`streamlocal` forwarding), so the app's existing `PTYHost` client connects to a local path and
  never learns it is remote.
- Reconnect: an SSH drop is a connection close, which the daemon already treats as a detach
  without seeds; the next attach is a cut and the app re-derives its screen. Mac sleep is the same
  event.

### 3. Where a session runs becomes part of the model

- An `ExecutionHost` (`local` | `ssh(hostProfileID)`) on the project, inherited by its sessions,
  persisted with a migration and quarantine semantics from `persistence.md`.
- `AgentLauncher` composes the command line for the host: remote login-shell `PATH`, remote
  checkout path, remote environment. `AgentRuntime` chooses the local or forwarded daemon.
- A host capability set, asked the way `kind.supports(_:)` is asked, so each surface below
  refuses instead of reading the Mac's disk and showing the wrong answer.

### 4. Hooks and MCP reach the Mac

- A Linux build of `threading-mcp-bridge` installed beside the daemon.
- A reverse `streamlocal` forward of the bridge socket, exported to the remote child as
  `THREADING_MCP_SOCKET`. Tool routing by session token is unchanged.
- Tools that execute on the Mac (browser, display, simulator) work as-is. Tools that pass a file
  path need the bytes to cross first; they refuse until that exists.
- A hook fired while the Mac is unreachable fails exactly as it does after an app quit today, and
  the activity inference that already tolerates that stays the answer.

### 5. Work that reads the agent's own files

Transcript replay, Codex/OpenCode/Grok session discovery, account discovery, usage scans, Git
Review, managed worktrees and project scripts all read the Mac's filesystem or run a local
command. Each needs a remote reader or a capability refusal.

These do **not** go into `threading-ptyd`: its safety argument is that it parses nothing and owns
no policy. They belong in a second, separately versioned remote helper with bounded, typed
requests. Slice 3's first release refuses them; each is then restored one surface at a time.

### 6. Authentication on the box

The first release asks the person to sign in to each CLI once from a remote shell session. Moving
logins between machines is out of scope.

## The autonomy question

With the Mac as authority, an agent **keeps running** while the Mac sleeps — that is what the
daemon is for — but hooks, MCP, scheduled messages, triggers, limit recovery and curfew live in
the Mac app and wait for it. That is the right first product.

A machine that acts on its own schedule while every Mac is asleep is a different product: the
scheduler and `threading-triggerd` would run on Linux, and the phone would reach the host directly.
It depends on the headless-core slices of [Native Linux host and UI](linux-host-runtime.md) and is
not part of this plan. Decide separately, with evidence of demand.

## Scaling gate

- Hosts: expected 1–3 per person, stress 20. Sessions per host: expected 10, stress 100 (the
  daemon's existing capacity refusal applies per host).
- Output frequency is the daemon's own; a forwarded socket adds latency, not work. The existing
  backpressure close applies to a slow SSH link exactly as to a slow local watcher.
- Nothing proportional to remote content runs on the main actor: SSH connection, helper install,
  capability probing and forward setup are background work with deadlines and typed failures.
- A host that is unreachable costs one bounded probe per backoff step, not one per session.

## Security

- The remote daemon's authorization boundary stays the `0700` directory, now on the remote
  account. The Mac-side forwarded socket gets the same `0700` directory.
- Threading never enables SSH agent forwarding for the agent's own use, never writes to
  `~/.ssh/authorized_keys`, and never installs anything outside the user's home.
- The binary is checked against the app-bundled checksum before it is executed; a mismatch is a
  refusal, not a re-download.

## Customization-surface gate

Slices 2–3 add a Settings section for hosts and a host indicator on project and session rows.
Both pass [`CUSTOMIZATION_SURFACE_AUDIT.md`](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md) when
they are designed; this draft reserves no component IDs yet.

## Effort

| Slice | Estimate |
| --- | --- |
| 1. Linux `threading-ptyd` + Linux test lane | 1–2 weeks |
| 2. Host profiles, install, forwarded socket | 4–6 weeks (includes the SSH dependency spike) |
| 3. `ExecutionHost` model, launcher, runtime, capability refusals — terminal sessions work end to end | 3–5 weeks |
| 4. Hooks and MCP over the reverse forward | 2–3 weeks |
| 5. Remote readers, one surface at a time | 1–3 weeks each |

Slices 1–4 give a useful product — a remote agent in a Threading terminal with activity, tools
and reconnect — in roughly three months, inside the SSH draft's four-to-eight-month estimate for
the whole.

## Open decisions

1. SSH dependency (the SSH draft's gate 1), or shelling out to the system `ssh` for the first
   release.
2. Minimum kernel. Exit events use `pidfd_open` (5.3); older kernels fall back to polling, so
   the practical floor is whatever the Swift static runtime accepts. Decide whether to state one.
3. Whether the first release ships `x86_64` or only `aarch64`.
4. Whether a project is bound to one host, or a session may choose.
