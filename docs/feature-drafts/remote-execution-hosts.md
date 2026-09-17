# Remote execution hosts

> Status: feature draft — slice 1 (a Linux build of `threading-ptyd`) builds and passes its
> suite on Linux; its durable decisions are in [`pty-host.md`](../architecture/pty-host.md#linux).
> A developer version of slices 2–3 runs Claude terminal sessions on a host behind a hidden setting
> (see [The developer version](#the-developer-version-2026-09-17)).
> The remote-session spike (below) ran on 2026-09-17 and settles slice 2's transport, install and
> upgrade shape. Nothing else has started. This is the implementation plan for slice C of
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
  `~/.local/lib/threading/<generation>/threading-ptyd`, install the templated user unit, enable
  linger. Upgrade is the existing zero-session `retire` handshake followed by switching unit
  instances — never `systemctl restart`, which kills agents. See the spike's decisions 4–6.
- Transport: system OpenSSH forwards the remote `ptyd.sock` to a Mac-local path in a `0700`
  directory (`streamlocal` forwarding), so the app's existing `PTYHost` client connects to a local
  path and never learns it is remote. Measured in the spike: no protocol change needed.
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

## The developer version, 2026-09-17

Slices 2 and 3 as a hidden developer setting, before host profiles or any UI: a project folder is
assigned to an `ssh` destination, and its Claude terminal sessions run there.

**What it does.** `RemoteExecutionHosts` (`Sources/Threading/Core/RemoteHost/`) prepares a host off
the main actor, one serial job per host: read its facts over `ssh` (`sh -s`, never a quoted
argument), upload the static daemon into a content-named directory and verify its SHA-256, write the
templated unit, enable lingering, retire another build only when it answers at this rendezvous with
zero sessions, start this build's instance, open a dedicated `ssh -N -L` tunnel and wait for
`hello`. A launch never blocks on it: `AgentSessionViewController` waits for
`RemoteExecutionHosts.didChangeNotification` and retries. `RemoteAgentLaunch` composes the command
from the host's facts — its login shell, its home, the remote checkout — and the host's own shell
decides `--resume` or `--session-id` by testing the transcript file. `TerminalSession.hostPlacement`
carries the host's environment and turns off every lookup that would ask this Mac's kernel about a
host pid.

**What it refuses, by name.** Every agent without `remoteExecutionHostLaunch` (all but Claude);
native chats; side-chat forks; managed workspaces; a login shell `-l -c` cannot hand POSIX syntax
to; a host whose login shell does not find `claude`; a host without systemd. No hooks or MCP yet
(slice 4), so activity comes from terminal output inference.

**Measured on the spike's Lima VM** (Debian 12, arm64) by `RemoteExecutionHostLiveTests`: facts,
upload, unit, linger, tunnel and `hello`, then a child spawned through the tunnel reporting
`HOST=Linux` and the host's home with exit status 7, then a second preparation finding everything
in place. Two findings changed the code:

- **A multiplexed `ssh` is not a tunnel.** Lima's `ssh.config` sets `ControlMaster`/`ControlPersist`;
  with it, `ssh -N -L` handed the forward to the master and exited 0 immediately, which read as a
  dead tunnel. The tunnel now runs with `ControlMaster=no` and `ControlPath=none`. Bounded commands
  still use the person's multiplexing, which is what makes them fast.
- **An old instance on other paths is not in the way.** The spike's own daemon was still running
  with `--default-locations`. Nothing answered for it at this rendezvous, so it shares no state
  directory and holds no lock this build needs; it is left running rather than stopped, because it
  may hold agents.

**Where a project runs is on the project, and visible.** The first version read project-to-host
assignments from a hidden `defaults` key. That was replaced the same day, because a setting that
decides which machine an agent runs on must not be one a person can forget is set: it is now
`Project.executionHost`, saved with the project and edited from the project row's **Remote Host…**
item (also a command, `project.remoteHost`, in the View menu and the palette). The editor keeps an
unusable host — a destination `ssh` would read as an option, a relative path — from being saved.
Wherever the project shows, it says so: a server mark on the project row and on each of its session
rows, "Runs on <host>" in the session hover card and the row tooltip, and one journal line naming
the host on every launch or reattach it routes. `RemoteExecutionHostRoute` is the single decision:
local, remote, or **refused** — a public build, or an invalid record, stops the launch with a reason
and never runs the agent on this Mac instead. A public build still offers the menu item while a host
is set, so the host can be removed there. Only the binary directory remains a hidden developer key,
and a wrong value can only make preparation fail.

**Trying it.** Build the Linux binaries (`scripts/test-ptyd-linux.sh --arch all`), point the
developer key at them, then choose **Remote Host…** on a project:

```bash
defaults write codes.threading developerRemoteHostBinaryDirectory -string "$PWD/build/linux"
```

The SSH host is anything `ssh` accepts non-interactively (`BatchMode`); the SSH config field takes a
config outside `~/.ssh/config`, such as `~/.lima/<vm>/ssh.config`. The folder must already exist on
the host and `claude` must be signed in there. The first launch of a session in that project
prepares the host (the upload is ~57 MB, ~22 MB compressed); later launches reuse it.

**Reattach.** A remote launch asks the prepared host's daemon what it holds before it spawns
anything. A session still running there on a pseudo-terminal is taken back with a remote
placement instead of being spawned again — spawning replaces the incarnation, which would end an
agent that has been working since the app last quit. The same check covers the startup relaunch and
a plain selection, so no path can replace a running remote agent. A held session that has *ended*
is resumed from its transcript. Measured by
`RemoteExecutionHostLiveTests/testASessionOutlivesEveryTunnelAndIsTakenBackAfterwards`: a session
spawned, every tunnel closed, five seconds with no Mac connected, then a new preparation's survey
still holding it and an attach replaying the line it wrote while nobody was connected.

**Stranded tunnels.** Each tunnel writes its `ssh` pid and kernel start time beside its socket,
and the next tunnel to that socket ends a recorded process that is still the one recorded, so a
crashed app does not leave one `ssh -N` per crash. Measuring this found a wider bug: `SIGTERM`
reached no child `ChildProcessSpawn` started, because children inherited a dispatch worker's
blocked signal mask. Fixed at the spawn for every child; see
[`sessions.md`](../architecture/sessions.md).

**A lost connection is not an exit.** On the Lima VM a killed tunnel left the agent running while
the app showed "Agent exited". A remote link that closes with no exit status now goes to
`TerminalSessionDelegate.terminalSessionDidLoseRemoteHost` instead of the termination path (a
signalled exit also has no status, but it arrives without a close cause, which is how the two
differ). The session view shows a `TerminalStatusBanner` ("Reconnecting to <host>…") and retries
with `RemoteReconnectDefaults` backoff (1, 2, 5, 10, 20, then every 30 s). A reconnect attempt is
**reattach-only**: it takes the session back if the host still runs it, finishes as ended with the
held exit if it ended meanwhile, and never spawns. Stopping the session cancels the retries.
Measured by `PTYHostSessionTests` for the routing; the retry loop is exercised by hand against the VM.

**Older instances are disabled for boot.** The unit template is shared, so an instance left
enabled comes back at the next boot on whatever paths the template names by then. On the VM the
spike's instance did exactly that, and a binary older than the state-directory lock took the
rendezvous. The probe now reports `default.target.wants` entries, and once this build's instance
runs every other enabled instance is `systemctl --user disable`d — without `--now`, so nothing
running is stopped. Instance names read off the host are held to `[A-Za-z0-9._-]`, because they go
back into a command run there.

**No standing openings.** The new-chat opening text from Settings asks for Threading's tools
(`set_session_name`), which a remote session does not have until slice 4, so
`NewChatOpeningMessage.compose(prompt:for:settings:)` sends only the chat's own task to a project on
a remote host. The Remote Host editor says so.

**Not yet.** Noticing Mac sleep or a network change before `ssh` exits (`ServerAlive` bounds it),
bundling the binaries in the app, hooks and MCP (slice 4).

## Remote-session spike, 2026-09-17

A by-hand end-to-end run of the slice 2 path before building it: the static arm64 binary from
slice 1 installed on a Debian 12 VM (Lima, Apple Virtualization, kernel 6.1), its socket forwarded
to the Mac with system OpenSSH, and a throwaway client on `ThreadingPTYHostKit` driving it. The VM
sits on the same Mac, so every latency below is the cost of ssh, the forward and the daemon, **not**
of a real network — add the path's round-trip time. Nothing from the spike is in the repository;
the client and scenario scripts were scratch.

### What was measured

| Question | Result |
| --- | --- |
| Does the unchanged protocol run over a forwarded socket? | Yes. `ssh -N -L <mac>.sock:<box>/ptyd.sock` with `StreamLocalBindUnlink=yes`, `ExitOnForwardFailure=yes`, `ServerAliveInterval=5`. The Mac-side socket is created `0600`. No frame, client or daemon change. |
| Connect + `hello` | 2–6 ms warm, 37 ms first, against 0.6–6 ms on a local socket. |
| Keystroke echo (one byte into `cat` on a pty, 300 samples, two runs) | Remote median 0.91 / 1.14 ms, p99 1.72 / 5.57 ms, max 18.6 ms. Local median 0.14 / 0.27 ms. |
| Output throughput | 23.0 MiB/s over the forward (64 MiB). The macOS local daemon measured 9.3 MiB/s, limited by Darwin's small pty buffers. Neither is near an agent's output rate. |
| `SIGWINCH` on resize | Delivered; the child reported the new size. |
| Clean detach, tunnel down 5 s, reattach | `exact(fromOffset:)`: 1,702 replay bytes = the 1,698 missed plus the 4-byte seed. The replay began at the line after the last one the first watcher saw (L182 → L183), no gap, no duplicate. |
| Tunnel killed while attached, reattach | `cut` with the whole ring tail, which contained every missed line. The daemon saw an ordinary close. |
| ssh frozen (`SIGSTOP`) 25 s under maximum output | The daemon stopped queueing at its 4 MiB bound and closed that watcher (`backpressureClosed`); the child never blocked. Reattach after resume was a `cut`. |
| Daemon memory | 35 MB RSS idle, almost all pages of the 57 MB static binary; flat after 200 MB through a detached session. |
| A Mac-composed launch (`/bin/zsh -lc …`) | `spawnRefused(executableUnavailable)` on Debian. |
| Agent `PATH` | A login `bash -lc` found `~/.local/bin/claude` (official installer) through Debian's `~/.profile`; a plain `bash -c` did not. The remote home was `/home/david.guest`, not the Mac's. |
| Logout with linger off | The last session ending stopped `user@.service` and killed the daemon **and the agent under it**. The next daemon reported the session `lostSession / processGone`. |
| Logout with linger on | Zero sessions, same daemon pid, agent still running and reattachable. `loginctl enable-linger` for oneself needed no sudo on Debian 12. |
| `systemctl --user restart` with an agent running | **Killed the agent** — systemd ends the unit's whole control group — and the new daemon reported it lost. |
| Retire, then a second generation started while the first still held a live agent | The new daemon's startup recovery read the shared `sessions.jsonl`, took the live agent for a crashed predecessor's orphan, and **`SIGKILL`ed its group** (`lostSessionStillRunning / groupKilled`). |
| The daemon's generation on Linux | `? (?)`: it is read from `Info.plist`, which a Linux binary does not have. |

Not covered: a real network path (Wi-Fi, cellular, a VPS region away), true Mac sleep, a Raspberry
Pi's slower storage and CPU, `x86_64` hardware, and non-Debian login-shell layouts.

### What it decides

1. **System OpenSSH is the execution transport** for the first release, not an SSH library. It
   forwards unix sockets both ways, reuses the person's keys, agent, `known_hosts` and
   `~/.ssh/config` (jump hosts, `Include`, hardware keys), and needed no code here. The app owns
   one `ssh -N` per host with the options above, a Mac-side socket in its own `0700` directory, and
   `ExitOnForwardFailure` so a failed forward is a process exit it can report. This decouples the
   SSH draft's library choice from execution: the library question stays open for SFTP and for a
   later host-key UI, and the SSH draft's "never import `~/.ssh/config`" stance has to be
   revisited for execution, where the person's config is the point.
2. **Reconnect needs no new protocol.** A dropped tunnel is a close; a deliberate disconnect sends
   `detach` with seeds first and gets an exact replay. The app must detect a dead tunnel from the
   `ssh` process exiting or the socket reaching end of file, because the watcher's own writes
   succeed into a local socket for a while after the far side is gone.
3. **The launcher composes per host from host facts.** Before any launch the app asks the host,
   over the same ssh: architecture (`uname -m`), `$HOME`, the login shell (`getent passwd`), and
   which agent CLIs a login shell resolves. Launches are `<login shell> -lc <command>` with the
   remote home and a remote checkout path. Nothing Mac-side — paths, `/bin/zsh`, account
   directories — is sent.
4. **Install requires linger.** The installer runs `loginctl enable-linger` for the user and
   refuses to report the host ready without it, because the failure it prevents is an agent
   killed at the moment its person logs out.
5. **One systemd unit per generation, never a restart.** Install `threading-ptyd@.service` with
   `ExecStart=%h/.local/lib/threading/%i/threading-ptyd --default-locations` and enable
   `threading-ptyd@<generation>`. An upgrade follows the macOS policy in
   [`pty-host.md`](../architecture/pty-host.md#retiring-a-daemon-the-last-bundle-left-behind)
   exactly: retire only a daemon holding **zero** active sessions, wait for its confirmed exit,
   then disable its instance and enable the new one. A busy host keeps its compatible older
   daemon and upgrades after its last session ends.
6. **Two daemon fixes before any remote install ships — both done, 2026-09-17**; the durable
   decisions are in [`pty-host.md`](../architecture/pty-host.md#failure-model):
   - **Generation.** The Linux build compiles the generation in: the lane defines
     `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and `THREADING_SOURCE_REVISION` for the C shim
     (defines rather than a generated source file, so the read-only source tree stays untouched),
     and `hello` carries them. Whatever later embeds the Linux binaries in the app passes the same
     three values it passes Xcode.
   - **One daemon per state directory.** The daemon takes an exclusive `flock` on `ptyd.lock` in
     its state directory before touching anything and exits 75 when another daemon holds it. This
     hardening applies to macOS unchanged. Reproduced first: with the lock disabled, the new test's
     second daemon killed the owner's agent exactly as the spike saw. Verified on macOS (125 hosted
     PTY-host tests through Xcode, 31 through SwiftPM) and on Linux arm64 and x86_64 (77 kit, 32
     package and 27 static-binary tests each, the static binary reporting `0.0.0 (0.0.0) @<rev>`).

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

1. ~~SSH dependency or system `ssh`~~ — system OpenSSH for execution; see the spike. Still open:
   how Threading presents host trust when it relies on the person's `known_hosts`, and whether
   the SSH draft's refusal to read `~/.ssh/config` is lifted for execution hosts.
2. Minimum kernel. Exit events use `pidfd_open` (5.3); older kernels fall back to polling, so
   the practical floor is whatever the Swift static runtime accepts. Decide whether to state one.
3. Whether the first release ships `x86_64` or only `aarch64`.
4. Whether a project is bound to one host, or a session may choose.
