---
title: Remote hosts and autonomous work
description: Run agents on a Linux machine you own, interactively from the Mac or unattended under a host-side controller, and operate it safely.
group: Connect
order: 75
---

# Remote hosts and autonomous work

Threading can run agents on a Linux machine you own: a VPS, a workstation, a Raspberry Pi. There
are two separate ways to use such a machine, and they share one execution component:

- **Interactive remote chats.** A Mac project is assigned to a remote host, and its sessions run
  there. The Mac stays the authority for projects, sessions, policy and every surface; the host only
  runs processes. The agent keeps working while the Mac sleeps or quits.
- **Autonomous workers.** A controller on the host owns a durable work queue, schedules, trigger
  sources, questions, deliveries, memory and mail. It starts agents with no Mac involved at all. The
  Mac (or another application) administers it over SSH.

This page is the operator's guide: what runs where, how to install, connect, upgrade, back up and
recover it, and what its security boundaries really are. The rationale behind each rule lives in the
architecture notes linked throughout, chiefly [The PTY host](../architecture/pty-host.md) and
[Autonomous host controller](../architecture/autonomous-controller.md).

> **Status.** The controller, its host bundle and `threading-ptyd` on Linux are built and tested on
> macOS and Ubuntu 24.04 (arm64 and x86_64) by the repository's own suites. Interactive remote chats
> are available only in developer and internal builds of the Mac app, and only for Claude terminal
> sessions; a public build refuses to route a project to a remote host. Live provider execution under
> the controller depends on your provider login on the host and is your deployment's to verify.

## The model: what runs where

```
  Mac (Threading.app)                               Linux execution host
  +-------------------------+                       +-----------------------------------------------+
  | projects, sessions,     |  ssh -L  ptyd.sock    | threading-ptyd                                |
  | policy, every surface   | --------------------> |   owns each agent's PTY / pipes, ring, exit   |
  |                         |                       |   ^ spawn, attach, inventory, receipts        |
  | MCP server  <-----------| <-------------------- |   |                                           |
  |                         |  ssh -R  mcp.sock     | threading-mcp-bridge  (interactive chats only)|
  |                         |                       |   |                                           |
  | Remote page, mail sync  |  ssh "<ctl> owner-rpc"| threading-controller supervise                |
  | usage, automations  ----| --------------------> |   SQLite store, resident supervisor,          |
  |                         |  ssh "<ctl> mail-rpc" |   agent tool broker (agent.sock) <------+     |
  | threading-triggerd      |                       |   probe sources, mail peers, usage      |     |
  | (Mac-local sources)     |                       |                                         |     |
  +-------------------------+                       |   agent process (spawned via ptyd) -----+     |
                                                    |     "<ctl> agent-mcp" / "agent-notice"        |
                                                    +-----------------------------------------------+
```

### The components

| Component | Runs on | What it owns | What it never owns |
|---|---|---|---|
| **Threading.app** | Mac | Projects, sessions, permission policy, presentation, the Mac's own automations and triggers | Remote processes; the controller's store |
| **`threading-ptyd`** (PTY host) | Mac and Linux | Each spawned child, its PTY or three pipes, an output ring, the last window size, its exit, and retained exit receipts | Projects, policy, transcripts, accounts, any database |
| **`threading-controller`** | Linux (or macOS) | The durable work store: workers, policies, work, executions, questions, deliveries, memory, knowledge, automations, sources, triggers, mail, usage receipts. Its `supervise` command is the resident loop; the same binary is the owner CLI, `owner-rpc`, `mail-rpc`, and the agent-side `agent`/`agent-mcp`/`agent-notice` clients | Terminal rendering, provider logins, destination systems |
| **Agent tool broker** | Inside `supervise` | A Unix socket (`agent.sock`) through which agents use their execution-scoped tools without opening the store | Any owner operation |
| **`threading-mcp-bridge`** | Linux, interactive chats only | A stdio-to-socket bridge so a remote Claude reaches the Mac's MCP server through the reverse-forwarded socket | Anything on the host |
| **`threading-triggerd`** | Mac | Polling the Mac's own trigger sources and handing events to the app | Launching agents; the controller |
| **Controller probe sources** | Linux, inside `supervise` | Polling approved probe executables on the same contract as the Mac's | None |

The PTY host is the one execution protocol. The Mac reaches a remote `threading-ptyd` through a
forwarded Unix socket; the controller reaches it through its local socket. Neither scrapes a TUI.

### Two uses, compared

| | Interactive remote chat | Autonomous worker |
|---|---|---|
| Who decides what runs | A person in the Mac app | The controller's queue, under owner-authored policy |
| Needs the Mac to start work | Yes | No |
| Survives the Mac sleeping or quitting | The agent keeps running; hooks fired while no Mac is connected are lost | Entirely independent of any Mac |
| Tools the agent gets | A scoped subset of Threading's MCP tools, through the bridge back to the Mac | Execution-scoped controller tools (work, memory, knowledge, mail) through the broker |
| Installed by | The Mac (Settings ▸ Remote Hosts) | You, with the controller host bundle |
| Builds | Developer and internal Mac builds | Any build of the controller |

You can use both on one machine. A remote chat on a host that also runs a controller can be given a
host-local mailbox (see [Mail between agents and hosts](#mail-between-agents-and-hosts)).

## Identity and state

### Identities

| Identity | Minted by | Stable across | Notes |
|---|---|---|---|
| **Controller host** (`HostID`) | The store, once, on first open | Restarts, upgrades, backups | `threading-controller --database DB host` prints it. The name defaults to the machine's host name; change it with `host-set-name`. A restored backup keeps the same host ID, so never run two live copies. |
| **Worker** (`WORKER_UUID`) | You (`worker-add WORKER_UUID NAME`) | Everything; a hosted agent is identified by (host ID, worker ID) | Memory, budgets, mail address and policy hang off it. Choose the UUID yourself and keep it in your deployment configuration. |
| **Work item** | The store, deduplicated by `SOURCE_KEY` | Retries | The same key returns the same work. |
| **Execution** | One per claim | None | Also the PTY identity in ptyd and the Claude session ID when a recipe passes `${THREADING_EXECUTION_ID}`. A continuation after an answer is a new execution. |
| **Mail address** | Derived | None | `HOST_UUID/worker/WORKER_UUID` or `HOST_UUID/session/SESSION_UUID`. The host part is where the agent's process runs. |
| **ptyd generation** | The build | None | `MARKETING_VERSION (CURRENT_PROJECT_VERSION)@revision`, compiled in. Reported in `hello`; never an admission condition. |
| **Remote host record** (Mac) | You, in Settings ▸ Remote Hosts | None | Name, SSH destination, optional SSH config file, default checkout folder, and once connected, the controller's executable and database paths. |

### Where state lives on the host

The controller host bundle installs into the service account's home:

| Path | Contents | Mode |
|---|---|---|
| `~/.local/lib/threading/hosts/<generation>/` | `threading-controller`, `threading-ptyd`, `host-state.py`, `install-host.py`, and (when it installs ptyd) the `.threading-managed-by` marker reading `external:threading-host-bundle`. `<generation>` is the SHA-256 of the bundle manifest, so every build gets its own directory. | `0700` dir and files, marker `0600` |
| `~/.local/state/threading/controller/controller.db` (+ `-wal`, `-shm`) | The controller's SQLite store | `0600` in a `0700` directory |
| `~/.local/state/threading/controller/controller.db.supervisor.lock` | The resident supervisor's exclusive lock (never unlinked) | `0600` |
| `~/.local/state/threading/controller/agent.sock` | The agent tool broker (default location) | `0660` |
| `~/.local/state/threading/controller/secrets/` | One file per `secret-set` name; never read back by any command | `0700` / `0600` |
| `~/.local/state/threading/controller/sources/<id>/` | Each probe source's private working directory | `0700` |
| `~/.local/state/threading/pty/ptyd.sock` | The ptyd rendezvous | `0600` (or `0660` with `--group-socket`) |
| `~/.local/state/threading/pty/host/` | ptyd's state directory: `sessions.jsonl`, `ptyd.lock`, `ptyd-*.jsonl` journal (7 days) | `0700` |
| `~/.config/systemd/user/threading-ptyd.service`, `threading-controller.service` | The two user units | `0600` |

The Mac's own installer for interactive chats uses different directories in the same tree:
`~/.local/lib/threading/<id>/threading-ptyd` and `~/.local/lib/threading/bridge/<id>/`, a templated
unit `threading-ptyd@<id>.service`, state in `~/.local/state/threading/pty/`, the reverse-forwarded
`~/.local/state/threading/bridge/mcp.sock`, and per-session settings files under
`~/.local/state/threading/sessions/`. See [Two installers on one account](#two-installers-on-one-account)
before mixing them.

### What survives what

| Event | Running agents | Controller state | What you do |
|---|---|---|---|
| Mac sleeps, quits or loses network | Keep running | Unaffected | Nothing. Hooks a remote chat fires meanwhile are lost; mail for the Mac waits on the host. |
| `threading-controller` restarts | Keep running (ptyd owns them) | Durable; running work stays running | Nothing. The supervisor reconciles from ptyd inventory and retained receipts. |
| `threading-ptyd` crashes and is restarted | The new daemon finds the old children by pid and start time, **kills their process groups**, and records each as `lost` | Retained receipts survive in `sessions.jsonl`; the controller records `failure {stage: host, reason: lost}` and interrupts the work | Inspect, then `retry` what should run again. |
| `systemctl --user stop threading-ptyd` | **All ended**: the unit uses systemd's default `control-group` kill mode | As above, once the daemon is back | Stop ptyd only when `threading-ptyd sessions` is empty. |
| Host reboot | Gone. A reboot cannot restore PTY processes. | Durable (WAL, full synchronous commits). On start ptyd reports every unfinished child as `lost`. | Linger must be on for units to start without a login. Then retry interrupted work. |
| Controller upgrade with a newer schema | Keep running | Migrated forward on first open; an older binary then refuses to write (`unsupported_schema`) | Back up first; there is no downgrade. |
| ptyd state directory lost or replaced | Unknown to the new daemon | Launches stay unresolved | Fenced repair commands; see [Recovery](#recovery-and-operations). |

What a restart never does: restore a previous process, reassign work on a timeout, or treat a
missing inventory entry as proof that a process stopped.

## Installing a controller host on Ubuntu

### What you need

- A Linux build machine (or container) with the pinned Swift toolchain: the `swift:6.3.2-noble`
  image, plus `libsqlite3-dev`, `pkg-config` and `python3`. The build downloads the pinned Swift
  Static Linux SDK by checksum. Build on the **same architecture** as the target host
  (`aarch64` or `x86_64`); the installer refuses any other.
- A target running systemd with user sessions, `python3`, and the SQLite runtime library
  (`libsqlite3-0` on Ubuntu). The controller links the host's glibc and SQLite dynamically, so build
  on a release no newer than the target (the pinned image is Ubuntu 24.04). `threading-ptyd` is a
  static musl binary and needs nothing installed.
- A dedicated, non-root service account. Its home path must contain only `A–Z a–z 0–9 / _ -`
  (no dots); the installer refuses anything else.

### Build the host bundle

`scripts/build-controller-host.sh ABSOLUTE_OUTPUT_DIRECTORY` runs inside a Linux Swift toolchain.
It runs the whole controller test suite, builds the static, stripped, generation-stamped
`threading-ptyd` and runs the daemon suite against that exact file, builds a release
`threading-controller` (static Swift runtime, stripped), writes `manifest.json`, and finally runs the
installer against a throwaway home as a self-check. For example, from a checkout:

```bash
docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  -v "$PWD":/src -v /absolute/out:/out -w /src swift:6.3.2-noble \
  bash -c 'apt-get update && apt-get install -y libsqlite3-dev pkg-config python3 git \
           && git config --global --add safe.directory /src \
           && scripts/build-controller-host.sh /out'
```

The output directory holds exactly four files plus the manifest (and a `build/` scratch directory
you can discard):

```
threading-controller   threading-ptyd   host-state.py   install-host.py   manifest.json
```

`manifest.json` records the system and machine, the controller's own `--version` answer, and the
SHA-256 of each of the four files. **Do not strip, sign, compress-in-place or otherwise rewrite any
bundle file after the manifest is written**; the installer refuses a digest mismatch.

The ptyd generation is stamped from `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and
`THREADING_SOURCE_REVISION` when set, otherwise `0.0.0`, `0.0.0` and the checkout's `HEAD` (left out
when the daemon's sources differ from `HEAD`).

### Run the installer

Copy the bundle to the host, then run the installer **as the service account**:

```bash
python3 /path/to/bundle/install-host.py /path/to/bundle            # verify and write; start nothing
python3 /path/to/bundle/install-host.py /path/to/bundle --start    # also daemon-reload and enable --now
```

| Option | Meaning |
|---|---|
| `BUNDLE` (positional) | The bundle directory |
| `--home PATH` | Install into another home owned by the current user (default: your home). `--start` requires it to be your own home and a non-root user. |
| `--start` | `systemctl --user daemon-reload` and `enable --now` the units it wrote. Intended for a new installation. |
| `--role all\|controller\|ptyd` | Which units this account runs: both (default), or one half of a separate-agent-user host |
| `--agent-socket PATH` | `--role all` or `controller`: serve the broker at this absolute path instead of `agent.sock` beside the store |
| `--agent-binary PATH` | `--role all` or `controller`: the controller executable agents run their tools with, passed to `supervise --agent-binary`. It must be an absolute path to an existing executable; you create it (see mode B) |
| `--ptyd-socket PATH` | `--role all` or `ptyd`: listen here. With `--role ptyd` it also adds `--group-socket` and `UMask=0027` |

Before writing anything it checks that the manifest matches this system and machine, that every file
matches its digest, and that the controller's live `--version` equals the manifest's. When it
installs ptyd it also says `hello` to whatever is at the ptyd socket path: a live daemon there that is
not this installation's own (its `--state` is not `~/.local/state/threading/pty/host`) is refused with
`ptyd_socket_in_use`, naming its pid, build and state directory, and nothing is written. A leftover
socket nothing listens on is not a conflict. It then copies the files into
`~/.local/lib/threading/hosts/<generation>/`, marks that directory `external:threading-host-bundle`
when it installs ptyd (so the Mac never retires, disables or prunes it), creates the state
directories `0700`, and writes the units. It prints one JSON line: `generation`, `schema`,
`servicesStarted`, `units`; a refusal prints `install-host: <reason>` on standard error and exits 1.

It deliberately does **not**: create users, groups or directories outside the account's home, copy
the agent binary anywhere, enable linger, restart an existing service,
overwrite a unit whose text differs (`existing_service_requires_explicit_upgrade`), delete older
generations, or write any SSH configuration.

Refusals you may see: `incompatible_bundle`, `invalid_manifest`, `bundle_digest_mismatch`,
`controller_capability_mismatch`, `installed_digest_mismatch`, `owned_service_home_required`,
`invalid_socket_path`, `option_does_not_apply_to_role`, `agent_binary_must_be_an_absolute_executable_path`,
`ptyd_socket_in_use`, `install_directory_marked_by_another_installer`,
`start_requires_current_nonroot_service_account`.

### The units

For `--role all` the installer writes, in the service account's user manager:

```
threading-ptyd.service        <gen>/threading-ptyd --socket ~/.local/state/threading/pty/ptyd.sock
                                                   --state  ~/.local/state/threading/pty/host
threading-controller.service  <gen>/threading-controller --database ~/.local/state/threading/controller/controller.db
                                                          supervise 2000 [--agent-socket PATH] [--agent-binary PATH]
```

Both use `Restart=on-failure` (10 s delay, at most 5 starts in 300 s), `NoNewPrivileges=yes`,
`UMask=0077` (ptyd `0027` in the separate-user form), and resource ceilings: ptyd `MemoryMax=8G`,
`TasksMax=512`; controller `MemoryMax=512M`, `TasksMax=128`. Agents are children of ptyd, so ptyd's
ceilings are the agents' ceilings; size them for your workers.

### Enable linger

Without linger, systemd ends a user's units, and every agent with them, when that user's last login
session closes. Turn it on once, as root:

```bash
sudo loginctl enable-linger threading
```

`systemctl --user` needs that user's own manager. Log in as the service account over SSH, or use
`sudo machinectl shell threading@`; a bare `sudo -u threading systemctl --user …` has no user bus.

### Check the installation

```bash
G=~/.local/lib/threading/hosts/<generation>
DB=~/.local/state/threading/controller/controller.db
systemctl --user status threading-ptyd threading-controller
$G/threading-controller --version                 # protocol, schema, features; opens no database
$G/threading-controller --database $DB host       # host id and name; agentSocket while the broker answers
$G/threading-ptyd status --socket ~/.local/state/threading/pty/ptyd.sock --state ~/.local/state/threading/pty/host
journalctl --user -u threading-controller -n 50   # supervisor reports; idle passes print nothing
```

A convenient habit is a stable symlink you own, such as `~/.local/bin/threading-controller`, pointed
at the current generation and switched as part of each upgrade. The installer never creates one.

### Deployment mode A: one Unix account

`--role all` from one account. ptyd, the controller and every agent run as the same user.

What it guarantees: the store and secrets are owner-only (`0600`/`0700`); agents get their tools
through the broker with a per-execution credential and are never handed the store path; the owner
CLI refuses a database directory that is group- or world-accessible.

What it does **not** guarantee: an agent's shell has the owner's file permissions. It can open the
store, read `secrets/`, run the owner CLI, read other executions' environments (and so their
credentials), stop the units, and connect to ptyd to spawn anything. In this mode the broker is
scoped routing, not a security boundary. Use it only for agents you would trust with the account.

### Deployment mode B: agents as a separate Unix user

The broker is what lets agents run without the controller's file permissions. Install twice from the
same bundle. The accounts, the shared group, the shared directories, the agent-binary copy and
linger are manual steps: the installer does none of them. Do them first, as root:

```bash
groupadd threading-agents
useradd -m -s /bin/bash threading                      # controller account
useradd -m -s /bin/bash agent                          # agent account; in no other group of threading's
usermod -aG threading-agents threading
usermod -aG threading-agents agent
install -d -o threading -g threading-agents -m 2750 /srv/threading/broker   # setgid: socket takes the group
install -d -o agent     -g threading-agents -m 2750 /srv/threading/pty
install -d -m 0755 /opt/threading
install -m 0755 bundle/threading-controller /opt/threading/threading-controller   # agents run their tools with this copy
loginctl enable-linger threading
loginctl enable-linger agent
```

Then, as each account:

```bash
# as agent
python3 bundle/install-host.py bundle --role ptyd --ptyd-socket /srv/threading/pty/ptyd.sock --start
# as threading
python3 bundle/install-host.py bundle --role controller --agent-socket /srv/threading/broker/agent.sock \
    --agent-binary /opt/threading/threading-controller --start
```

**Why `--agent-binary`.** Agents run the controller executable for their tools (`agent-mcp`,
`agent-notice`), but the controller's own copy sits in its `0700` home, which the agent user cannot
enter. `--agent-binary` puts the `/opt` copy on the supervisor's command line, and the supervisor
hands that path to every agent. The installer checks that the path exists and is executable but
never creates or updates it, so replace the `/opt` copy with the new bundle's on every upgrade.

Recipes on this host must name `"socketPath": "/srv/threading/pty/ptyd.sock"` and a `directory` the
agent user owns. Provider homes declared under `usage.accounts` belong to the agent user, but the
controller's usage collector reads their transcripts as the controller user, so they must be
group-readable: the ptyd unit's `0027` umask covers files created with default modes; where a
provider creates files more tightly, add a default ACL such as
`setfacl -d -m g:threading-agents:rX <home>`. A provider that writes transcripts `0600` explicitly
cannot be collected and shows up as a coverage gap, never as a silent zero.

What mode B guarantees: an agent's shell cannot open, copy or replace the store, the secrets or the
supervisor lock, and cannot run owner commands against them; its tools still work through the broker
with its own credential; the broker records the connecting uid on the work's history
(`launch.agent_peer`). What it does not: agents of the same agent user can read each other's
processes, environments (credentials) and files; the controller user can spawn anything as the
agent user through ptyd, by design; and there is no network, cgroup or container isolation. Use one
agent user (or a container) per mutually distrusting worker.

### Two installers on one account

A host can have two installers: the Mac's Remote Hosts setup and the controller bundle (or another
deployment tool). The Mac acts only on what it can prove it installed:

- Each Mac-installed directory carries `<install dir>/.threading-managed-by` containing
  `threading-mac`, and its unit template carries `X-Threading-Managed-By=threading-mac`. Another
  installer writes `external:<name>` (a consuming application's configuration management, for
  example). **A directory with no marker reads as external.**
- The Mac retires, disables at boot or prunes only its own generations, re-reading the marker at
  removal time. Every Mac client sets `retiresOlderDaemon: false` on a remote daemon.
- A compatible daemon answering at the Mac's rendezvous that the Mac did not install is used as it
  is. An incompatible one makes the host show **Managed elsewhere** ("managed by <name>; upgrade it
  there"), and the Mac starts nothing beside it.

Failing safe costs a manual upgrade; failing open would cost somebody's running agents. To hand an
unmarked generation back to the Mac, write `threading-mac` into its marker.

**Mixing the controller bundle with Mac-prepared chats on one account.** The bundle's ptyd listens at
`~/.local/state/threading/pty/ptyd.sock`, the same rendezvous the Mac uses, but keeps its state in
`pty/host/` while a Mac-installed daemon keeps it in `pty/`. While the bundle's daemon answers, the
Mac sees an external daemon and uses it. What keeps the two apart:

- `install-host.py` marks its ptyd install directory `external:threading-host-bundle`, so nothing
  the Mac does to its own generations can reach the bundle's.
- **Only one daemon can hold the socket.** A ptyd that finds another live daemon answering at its
  socket path refuses to start (it names the other daemon's pid and build on standard error and
  exits 73) instead of taking the path over; only a leftover socket nothing listens on is replaced.
  `install-host.py` refuses up front, with `ptyd_socket_in_use`, to write a ptyd unit for a socket
  another daemon answers.

So if the Mac prepares the host while the bundle's ptyd is down, the Mac's daemon owns the socket
and the bundle's unit fails to start (`systemctl --user status threading-ptyd` shows why) rather than
stranding the Mac's sessions. Keep the bundle's ptyd running on such hosts, or give one of them its
own account or its own `--ptyd-socket`.

## Connecting from the Mac

### Remote hosts and interactive chats

Settings ▸ Remote Hosts lists machines: a name, what `ssh` connects to, an optional SSH config file
and a default checkout folder. **Check** prepares the host now. A project then chooses a host through
**Remote Host…** on its row (also the `project.remoteHost` command); its rows show a server mark and
"Runs on <host>".

The Mac uses the system OpenSSH in `BatchMode`, with your keys and `known_hosts`. It never answers a
host-key prompt for you: connect once in a terminal first. Preparing a host, off the main thread and
one job per host:

1. reads the host's facts over `ssh … sh -s` (architecture, login shell, systemd, linger, installed
   generations and their markers, `claude` and `curl` on the login `PATH`, whether
   `~/.claude/.credentials.json` is readable);
2. uploads the digest-verified static `threading-ptyd` and `threading-mcp-bridge` (about 22 MB
   compressed each) into content-named directories, marked `threading-mac`;
3. writes the templated unit, enables linger, starts this build's instance, and retires an older
   Mac-installed instance (see below);
4. opens a dedicated `ssh -N` tunnel (no connection multiplexing) forwarding the daemon's socket to
   the Mac and the Mac's MCP rendezvous back to `~/.local/state/threading/bridge/mcp.sock`.

A refusal says what to fix: host-key verification, `Permission denied`, a missing systemd user
session, or `claude` missing or signed out (`ssh -t <host> claude`). A host without `curl` gets no
lifecycle hooks and falls back to output inference.

A lost connection is not an exit: the session shows "Reconnecting to <host>…" and retries with
backoff (1, 2, 5, 10, 20 s, then every 30 s). A reconnect only reattaches; it never spawns. When the
app relaunches, a session still running on the host is taken back, not replaced.

### The controller over SSH

The Mac talks to a controller only through its owner protocol, over the same SSH destination:

```
ssh <destination> '<controller executable>' --database '<database>' owner-rpc     # one JSON request on stdin
ssh <destination> '<controller executable>' --database '<database>' mail-rpc --peer <Mac host id>
```

In Automations ▸ Remote, choose the host, enter the controller's **absolute** executable and
database paths, and **Connect**. The paths are saved on the host record once a connection succeeds;
remote automations, agent usage, mail sync and remote session mailboxes all use them. Connecting
installs nothing, configures no worker and starts no service: the controller must already be
installed and its supervisor running. The path names a generation, so after an upgrade update it (or
point it at your stable symlink).

Because the Mac also prepares hosts and runs `mail-rpc` over this destination, it needs an ordinary
SSH login as the controller's account. That login is owner authority over the store.

**Consuming applications** should use a dedicated key restricted to the owner protocol, for example
in the service account's `~/.ssh/authorized_keys`:

```
command="/home/threading/.local/bin/threading-controller --database /home/threading/.local/state/threading/controller/controller.db owner-rpc",restrict ssh-ed25519 AAAA… ops-console
```

`owner-rpc` reads one request of at most 256 KiB, `{"command": "...", "arguments": [{"value": "..."} | {"text": "..."}]}`
with at most 16 arguments. A `value` is a literal (≤ 4 KiB); a `text` becomes a private temporary
file for commands that take a file argument, removed afterwards. It answers one JSON line, or an
error on stderr with a nonzero exit. Only an allowlist of bounded commands is accepted; it cannot
start a supervisor, launch or claim work, run `mail-sync`/`mail-rpc`, or write knowledge grants or
content (`knowledge-grant`, `knowledge-put` are local-CLI only). Never expose it as an HTTP endpoint
or as an agent's tool.

### Version and feature negotiation

```bash
threading-controller --version
```

```json
{"protocol":"1","schema":"10","capabilities":"work,mail,triggers,memory,usage,capacity,transcript-binding",
 "features":["work","mail","triggers","memory","usage","capacity","transcript-binding","launch-repair",
  "host-receipts","launch-failure","launch-occupancy","schema-fence","usage-accounts","usage-waive",
  "capacity-hold","work-dependencies","memory-forget","retention","launch-secrets",
  "mail-credential-rotate","mail-outbound-cancel","agent-broker","credential-digest"]}
```

`--version` opens no database. `version` and `host` (both also on `owner-rpc`) report the same
`protocol`, `schema` and `features`; `host` adds the host ID, name and, only while the broker answers,
`agentSocket`. `capabilities` keeps its original string for installers that pinned it. A client
checks a feature before relying on it; for example the Mac hands a remote chat the broker socket
only when `host` lists `agent-broker` with an `agentSocket`, and otherwise falls back to the store
path for that same-account case.

### Compatibility rules

| Pair | Gate | When they differ |
|---|---|---|
| Mac ↔ ptyd | The PTY host protocol pair (`current`, `minimumSupported`) in `hello`. The generation string is reported, never compared for admission. | A compatible older daemon keeps serving. If the Mac's own generation is too old to speak to, the Mac retires it; if the daemon is newer than the Mac, the Mac refuses and leaves it alone. Another installer's incompatible daemon shows **Managed elsewhere**. A hosted launch never silently falls back to running on the Mac. |
| Mac or consumer ↔ controller | Owner protocol `1` plus `features` | A command the controller does not know is refused (`rpc_command`); feature-gated behaviour is skipped by the client. |
| Controller ↔ ptyd | The same protocol pair, plus ptyd's `hello` features | Retained exit receipts require a ptyd that lists `retainedReceipts`; an older daemon keeps exits only for its ordinary window. Install both from one bundle. |
| Controller binary ↔ store | Exactly one schema per build (currently 10) | A newer binary migrates the store forward on first open; every write re-checks the schema, so an older process still running stops writing (`unsupported_schema`) and a resident supervisor exits. No downgrade. |

**Retire on upgrade (ptyd).** `retire` makes a daemon stop accepting, close and unlink its socket at
once so a new build can bind, keep serving what is attached, and exit 0 when its last session ends.
A daemon never exits on its own just because it is idle. The Mac sends `retire` only to a generation
it installed. The controller bundle's ptyd is never retired by anyone; it is upgraded by the
procedure under [Upgrades](#upgrades-and-schema).

## The lifecycle of autonomous work

All commands below are `threading-controller --database DB COMMAND …`. They print JSON on stdout;
failures print one token on stderr and exit nonzero. Text arguments are paths to bounded UTF-8 files
(32 KiB; FIFOs, devices, symlinks and invalid UTF-8 are refused). Most mutations take an
`EXPECTED_REVISION` (compare-and-swap); revision `0` creates, and a stale revision is `conflict`.
Lists take an optional cursor and return `{"items": […], "next": N}`.

### Workers and policy

```bash
threading-controller --database $DB worker-add  $W triage
threading-controller --database $DB worker-configure $W 0 2 recipe.json   # MAX_CONCURRENT 1–8; always leaves it paused
threading-controller --database $DB worker-set-sources $W 0 request,schedule,event
threading-controller --database $DB worker-enable $W 1
```

A **recipe** is the owner-authored launch spec; nothing in work text, mail or an event can become
one. It is at most 32 KiB, 64 arguments and 128 environment entries, and **no parent environment is
inherited**, so set `HOME`, `PATH` and the provider's config directory yourself:

```json
{
  "socketPath": "/home/threading/.local/state/threading/pty/ptyd.sock",
  "executable": "/home/threading/worker/run-triage.sh",
  "arguments": ["--session-id", "${THREADING_EXECUTION_ID}"],
  "environment": {"HOME": "/home/threading", "PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/srv/agents/claude-work"},
  "secrets": {"API_TOKEN": "triage-token"},
  "directory": "/home/threading/work/triage",
  "recipients": ["person:owner"],
  "destination": "triage-report",
  "usage": {"runtime": "claude", "accounts": [{"account": "work", "home": "/srv/agents/claude-work"}]}
}
```

- The executable here is your own wrapper that starts the provider CLI non-interactively with its
  MCP configuration and hooks; the controller does not know provider flags. Prefer noninteractive
  provider turns for unattended work.
- An argument exactly equal to `${THREADING_EXECUTION_ID}` is replaced with the execution UUID at
  dispatch; nothing else is substituted and no shell is involved.
- `environment` values are stored in plain text in every policy and launch row, and therefore in
  backups. Put credentials in `secrets` (environment name → secret name, at most 16) and store them
  with `secret-set NAME FILE`. They are resolved at dispatch; a missing secret fails the dispatch and
  leaves the intent prepared.
- The runtime adds `THREADING_EXECUTION_ID`, `THREADING_EXECUTION_CREDENTIAL`,
  `THREADING_CONTROLLER_AGENT_SOCKET` and `THREADING_CONTROLLER_BIN` (the controller, or the
  `--agent-binary` copy). Configure the provider to run `<controller> agent-mcp` as an MCP server and
  `<controller> agent-notice post-tool-use|stop|session-start` as hooks. The hook is required for
  Codex usage attribution and for mail notices; it always exits 0.
- `recipients` are who a question goes to (`person:ID`, `group:ID`); `destination` is an opaque
  routing key for results, not a grant.

`worker-configure` and `worker-reconcile` both take a recipe. Use **`worker-reconcile WORKER REV
RECIPE`** from automation: it replaces the recipe while preserving the enabled/paused intent and
concurrency, and an identical recipe is a no-op. Configure-then-enable can strand a worker or
override a human pause if a response is lost between the two.

`worker-set-sources` restricts admission to `request` (owner enqueues), `schedule` (automations) and
`event` (triggers and mail wakes). A worker with no sources record keeps its legacy behaviour; set it
explicitly. `worker-pause` stops future admission only; running executions keep their scope and can
finish, ask or be stopped. `worker-archive` pauses the worker, pauses every trigger feeding it,
clears wake on its open mail and refuses new mail; it is refused while work, unresolved launches or
enabled schedules remain. `worker-policy`, `worker-sources`, `workers` and `active-launches` read
state without printing recipe arguments, environment or secrets.

### Requests and dependencies

```bash
threading-controller --database $DB enqueue $W nightly-2026-10-04 instruction.txt
threading-controller --database $DB enqueue-request $W ticket-4711 instruction.txt request.json  "$DEP1,$DEP2"
```

`SOURCE_KEY` is the idempotency key: repeating it returns the original work or refuses changed
content. `enqueue-request` stores an immutable request envelope with the instruction. The optional
last argument lists up to 16 work UUIDs that must **complete** first; each must exist and not be
cancelled, so the graph is acyclic. An interrupted dependency keeps its dependents waiting until it
is retried and completes; cancelling work cancels its queued dependents transitively
(`dependency_cancelled: <id>`).

`work-message WORK MESSAGE_UUID PERSON FILE` appends an attributed follow-up to unfinished work;
agents read it with `work_messages` and acknowledge each with `work_message_consumed`. `work-cancel`
keeps history and closes an unanswered question, but refuses running work: stop the process first.
`work`, `works`, `work-history` and `work-messages` read it.

### The state machine

```
queued -> running -> waiting -> queued -> running -> completed
                 \-> interrupted (exit without a result, loss, refusal)  --retry-->  queued
```

Each claim creates a new execution. The resident supervisor prepares a launch intent and claims the
work in one transaction, then dispatches exactly one spawn to ptyd with the execution's private
credential. An exit, even exit 0, without `work_finish` interrupts the work and never invents a
result; failed work stays interrupted until you `retry` it.

### Automations

An automation is a host-owned schedule that enqueues work for an existing worker. It cannot change
the worker's recipe or scope.

```json
{"name": "Morning sweep", "workerID": "…", "instruction": "Summarise overnight failures.",
 "schedule": {"kind": "weekdays", "timeZone": "Europe/Stockholm", "hour": 7, "minute": 30, "days": [2,3,4,5,6]},
 "missedPolicy": "latest", "archiveOnSuccess": true}
```

```bash
threading-controller --database $DB automation-configure $A 0 spec.json   # always paused
threading-controller --database $DB automation-enable $A 1
threading-controller --database $DB automation-run $A 2 manual-2026-10-04 # run now; the key makes it idempotent
threading-controller --database $DB automation-runs $A
```

- `kind` is `daily`, `weekdays`, `weekly` or `interval`; `days` uses Sunday = 1;
  `intervalMinutes` with an optional ISO-8601 `anchor` (intervals advance from the anchor, never from
  when a run finished). `timeZone` is an IANA identifier. A null `schedule` makes a run-now or
  event-driven automation.
- **DST.** In a repeated hour the first occurrence runs, once; a nonexistent local time advances
  within its day. The calendar code is shared with the Mac's automations.
- **Missed runs.** A late schedule records one `missed` receipt (`skip`) or queues one catch-up
  labelled with the most recent occurrence it replaces (`latest`), then advances past now. It never
  expands every missed period into work.
- **One slot.** Queued, running or waiting work, or an unresolved launch, suppresses the next
  occurrence. An occurrence that cannot be admitted (for example the worker no longer accepts
  `schedule`) is recorded `refused` with its reason and is not retried.
- `archiveOnSuccess` marks a run archived only when its work completed, every delivery is confirmed
  and no launch is unresolved.

The Mac's Automations ▸ Remote page edits, enables, pauses, runs and deletes these over `owner-rpc`.
An agent on the Mac using `manage_automation` can do the same through the saved paths only; its
remote enable and run wait for your approval sheet.

### Trigger sources (probes)

A source is any executable on the probe contract: one JSON request (`cursor`, `limit`) on stdin,
JSON event lines and exactly one final cursor line on stdout, exit 0, 75 (back off) or 77
(authentication needed). Examples ship in `Packages/ThreadingController/Examples/Probes`
(`file_drop.py`, `http_json.py`, `imap_unseen.py`, `rss.py`). The Mac's `threading-triggerd` runs
probes on the same contract, so one probe works in both places; the Mac's daemon polls only while
the Mac is awake and logged in, the controller's on the host.

```bash
threading-controller --database $DB source-configure $S 0 source.json   # paused, approval cleared; prints "hash"
threading-controller --database $DB source-approve   $S 1 <sha256 you reviewed>
threading-controller --database $DB trigger-configure $T 0 trigger.json # paused
threading-controller --database $DB trigger-enable   $T 1
threading-controller --database $DB source-enable    $S 2
```

A source spec names `executable`, optional `script` (hashed with it), `arguments`, `environment`,
`secrets`, `intervalSeconds` (60 s – 1 day) or a calendar `schedule`, `timeoutSeconds` and `limit`.
A trigger is a typed AND rule over one source's event fields (`equals`, `notEquals`, `prefix`,
`notPrefix`, `contains`, `exists`, `absent`; up to 16 clauses) plus a host-authored instruction; the
event travels as the work's immutable request.

- **Approval pins content.** The poller hashes before running anything; an edited file is never run
  and the source shows `changed` until approved again. A probe is not sandboxed: it runs with the
  controller account's authority, in its own process group, with only its configured environment.
- **Enable triggers before the source polls.** An event is stored once per (id, revision) and gets a
  receipt per enabled trigger at that time (`queued`, `notMatched`, `refused` with a reason). An
  event that arrived while no trigger was enabled is not re-admitted later.
- **Bounds.** At most 100 tasks admitted per poll (the rest are redelivered from an unmoved cursor),
  a backlog of 50 queued tasks per trigger (`refused: backlog`), 100 enabled triggers per source, two
  concurrent polls. Failures back off to an hour without moving the cursor.
- `source-poll S` polls once now (needs approval, not enabling). `source-events S` lists events and
  their receipts.

### Questions, answers and continuations

An agent asks with `work_ask`; the question, a checkpoint and the yielded execution commit together,
and only that work waits. Questions go to the recipe's recipients (1–32 people or groups); one
authorized answer resolves it.

```bash
threading-controller --database $DB open-questions $W
threading-controller --database $DB answer $Q person:alice group:ops answer.txt   # PERSON, GROUPS_CSV or "-", file
```

The owner attests who answered; that is attribution, not authentication of the person. The answer
requeues the work, and the supervisor launches a **new execution** that reads the checkpoint and
answer, once any previous launch of that work is confirmed stopped. Answers supply information,
never execution or connector permissions.

### Deliveries and receipts

`work_finish` means the computation finished and a delivery was durably queued. **The controller
does not send anything to the destination**; an adapter you run (or a consuming application) does:

```
pending -> sending -> delivered          (delivery-begin, then delivery-ack with the attempt id)
           sending -> uncertain          (delivery-uncertain)
           uncertain -> pending          (delivery-confirm-absent, only with evidence of absence)
```

Begin before the external call and use the stable delivery ID as the destination's idempotency key.
Only that attempt can acknowledge it. A `sending` record after a crash is unresolved, never
automatically retried, and a timeout is not proof of absence. `pending-deliveries`,
`work-deliveries` and `delivery` read the outbox.

### Memory and shared knowledge

Each worker has private, revisioned text memory (`memory_list`, `memory_get`, `memory_put`,
`memory_delete` for its agent; the owner has `memory-list/get/put/history/delete/forget`).

- Every revision records host-attested provenance: `actor` (`owner` or `agent`), the agent's
  `executionID`, and `at`.
- `memory-delete WORKER KEY REV` writes a tombstone; history stays reviewable.
  `memory-forget WORKER KEY` blanks every stored revision's body with secure delete and truncates the
  WAL, so the text leaves the live database files. **Earlier backups and provider transcripts still
  contain it.**
- Quotas: 1,000 active keys and 4 MiB of active text per worker and per knowledge space
  (`memory_key_quota`, `memory_byte_quota`); shrinking writes always succeed.

Shared knowledge spaces are opaque UUIDs with per-worker grants:
`knowledge-grant SPACE WORKER REV none|read|write` (local CLI). Revocation takes effect on the
agent's next call. Memory and knowledge are untrusted context: they never grant permission, select
an executable or override policy.

### Mail between agents and hosts

Durable, addressed messages between workers and sessions, on one host or across hosts.

- **Grants live on the recipient's host.** `mail-grant-set RECIPIENT SENDER_PATTERN REV
  none|notify|wake|ask normal|interrupt [CHAIN_TOKEN_BUDGET]`. Patterns are an exact address,
  `HOST_UUID/*` or `*`, most specific first. `notify < wake < ask`; `none` revokes. A reply to mail
  the recipient sent needs no grant, unless the owner explicitly revoked that sender: an effective
  `none` refuses replies too, and answers that worker's open questions to the sender with
  "Undeliverable: … revoked" so the work continues.
- **Sending is storing.** `mail_send` succeeds once the message is in this host's inbox or outbound
  queue. Reading is not acknowledging: an unacknowledged `interrupt` blocks `work_finish`.
- **Wake.** Mail under a `wake` or `ask` grant may start an idle worker that accepts `event`: one
  coalesced task per worker, keyed by the newest open message. The claim re-checks authority, so a
  revocation, a spent chain budget or an emptied inbox withdraws the task (`mail.wake_withdrawn`).
- **Chains bound loops.** A message continues the chain of what it replies to or what its execution
  read, acknowledged or was woken by; the depth limit is 4. Per chain on a host: 50 messages and 16
  wakes; 20 sends a minute per sender; 1,000 open messages per inbox. A grant's chain token budget
  stops that chain waking the recipient (mail is still delivered). A person's new prompt in a Mac
  session starts a fresh chain.
- **Between hosts**, `mail-rpc --peer HOST` is the forced command of a per-peer SSH key; it can only
  push a batch or pull after a cursor, and every response names the answering host. Each side must
  name the other with `mail-peer-set HOST REV NAME PEER_JSON` (`{"transport": [argv] | null, "push":
  bool, "pull": bool}`). The resident supervisor syncs every 15 s; `mail-sync` runs one pass by
  hand. The Mac sits behind NAT, so it initiates both directions over its own SSH while connected;
  the host's peer entry for the Mac has no transport.
- **Outbound mail ends.** Undelivered peer mail bounces to its sender after seven days or on
  `mail-outbound-cancel MESSAGE`.
- **Moving a mailbox.** `mail-forward-set OLD NEW REV` forwards mail still arriving for the old
  address once; on the new host the same record lets it accept forwarded copies from the old host
  for seven days (renew by rewriting). Forwarded copies are vouched only for senders the old host
  can vouch for, and stay under the new store's own grants. `mail-move OLD NEW` moves unacknowledged
  mail with ids kept. An explicit revocation on the receiving store stands against forwarded copies.
- **Session mailboxes** (Mac remote chats) are registered with `mail-register`; `mail-credential`
  issues a credential for each launch and stores only its digest, so issuing again (or
  `mail-credential-rotate`) revokes the previous one immediately.

Mail carries information, never authority. Every message is shown with a host-vouched header, but
its body is text another agent wrote: treat it as untrusted input.

### Usage receipts, budgets and capacity holds

When a launch is confirmed stopped, the controller owes a usage receipt. The supervisor writes it
from the transcripts in the recipe's declared `usage.accounts` homes (Claude or Codex), using the
same parser and pricing catalogue as the Mac's Usage page; `usage-collect EXECUTION` writes one by
hand. Receipts are `complete`, `partial` (with a named gap) or `failed`; a launch that never spawned
settles as zero with `never_spawned`.

```bash
threading-controller --database $DB worker-budget-set $W 0 2000000   # budget tokens per UTC day, or "none"; 0 creates
threading-controller --database $DB worker-capacity $W              # ready | paused | usageNotConfigured | usageUnsettled | dailyBudget | capacityHeld
threading-controller --database $DB usage-summary 2026-10-01 2026-10-04
```

- **Budget tokens** are uncached input + cache writes + output; cached reads are excluded.
- Budgets act **at admission only**: nothing running is stopped. Unknown, partial or pending usage
  holds new admissions for that worker for the UTC day; a budgeted recipe with no usage source is
  held. Manual `launch` passes the same check; `--override-budget` admits anyway and is recorded.
- `usage-waive EXECUTION REASON` releases one stopped execution's unsettled hold when no transcript
  can settle it. It is audited, and a transcript that appears later is still counted.
- `capacity-hold-set ACCOUNT UNTIL_ISO8601 REASON` defers workers whose declared accounts are
  **all** held (for example during a provider cooldown); `capacity-hold-list`, `capacity-hold-clear`.
  Holds are owner input, never inferred.

## Recovery and operations

### Reading the supervisor

The resident supervisor logs JSON reports to the journal (`journalctl --user -u
threading-controller`); idle passes print nothing. `supervisor-tick` runs one bounded pass for
diagnosis and prints the same report, but it takes the same lock, so it answers `conflict` while the
resident supervisor runs; stop the unit first. Without a resident supervisor there is no broker, so
a tick prepares launch intents and leaves them prepared (`agent_broker_unavailable`). Report fields:

| Field | Meaning |
|---|---|
| `started`, `stopped`, `observed`, `receipts`, `requeued` | Launch activity this pass |
| `held: [{workerID, reason}]` | Queued work admission is holding back: `host_unavailable`, `global_capacity`, `host_capacity`, `worker_capacity`, `quarantined`, or a `worker-capacity` reason such as `usageUnsettled`. Printed whenever the set changes. |
| `issues`, `workerIssues` | Per-item failures (`observe_failed`, `agent_broker_unavailable`, …); that item backs off 30 s doubling to 15 min and the pass continues |
| `tickIssues` | A busy store; retried next pass |
| `usageIssues`, `sourceIssues`, `automationIssues`, `expiredMail`, `woken`, `scheduled` | The other duties of the pass |

Each pass reads at most eight unresolved launches and eight policies and sends at most two spawns. A
ptyd socket that refuses or fails inventory is backed off (5 s doubling to 5 min). The supervisor
exits only when it can no longer trust or write the store (corrupt, read-only, full, I/O failure, or
migrated by a newer build); systemd restarts it up to five times in five minutes, after which the
unit is `failed` until `systemctl --user reset-failed threading-controller`.

### Capacity

| Limit | Value | Applies to |
|---|---|---|
| Per worker | `MAX_CONCURRENT`, 1–8 | Every unresolved launch, including manual and uncertain ones |
| Per ptyd socket | 16 unresolved launches | Automatic admission |
| Store-wide | 32 unresolved launches | Automatic admission |

`launch-occupancy` prints unresolved launches by host and state with both limits. An explicit
manual `launch` may exceed the scheduling limits but still occupies slots.

### Inspecting a launch

```bash
threading-controller --database $DB active-launches
threading-controller --database $DB launch-status $E    # running | stopped | absent, from ptyd's inventory
threading-controller --database $DB launch-record $E    # durable record, including failure and redacted tail
threading-ptyd sessions --json --socket $SOCK --state $STATE
threading-ptyd attach <execution-id-prefix> --socket $SOCK      # watch; add --input deliberately to type
threading-ptyd journal 100 --socket $SOCK --state $STATE
```

A failed launch's record carries a bounded `failure` (`stage`: `exit`, `host`, `owner`, …) and, for
a non-zero, signalled or early exit, a 2 KiB output tail with control sequences removed and recipe
argument/environment values and credential-shaped tokens redacted. Redaction is best effort; treat
the tail as an owner-only diagnostic. Recipe faults (`executableUnavailable`, `unsupportedChannel`)
interrupt the work and pause that policy revision; host faults (`retiring`, `capacity`, a fork
failure) return the work to the queue.

### Uncertain launches and fenced repair

Stop evidence, strongest first: a retained ptyd receipt; an exited inventory entry; the current
daemon's `lost` report. An **absent entry with no receipt** leaves the launch unresolved, because
omission from inventory proves nothing. A pid that differs from the recorded one is reported as
`process_identity_mismatch` and never recorded.

| Situation | Command | Fence |
|---|---|---|
| Stop a running execution and record it | `launch-stop E` | Waits for the exit receipt; a timeout leaves it unresolved |
| You have independent proof the process is gone (rebooted, ptyd state replaced) | `launch-confirm-stopped E EXPECTED_STATE` | `EXPECTED_STATE` is the state you saw: `prepared`, `dispatching` or `running`. Optional locally, **required over `owner-rpc`** (`rpc_fence_required`); a moved launch is `conflict`. Missing inventory is not proof. |
| Record that an execution stopped, then retry | `interrupt E`, then `retry WORK` | `interrupt` records a fact and sends no signal; it is refused while the launch is unresolved, so confirm the launch first (which interrupts it) |
| A connection failed before the spawn was sent | `launch-dispatch E` | Only a still-`prepared` intent. A lost spawn response leaves `dispatching`, which can never be dispatched again. |
| A delivery attempt is uncertain and you proved the destination has no result | `delivery-confirm-absent DELIVERY ATTEMPT` | Names the attempt reconciled; a timeout is not evidence |

The resident supervisor cancels a prepared intent whose policy revision is no longer enabled and
requeues its work, since no spawn was sent.

### Retention

`prune --before DATE [--after CURSOR]` (also over `owner-rpc`) deletes journal events and the
activity of completed or cancelled work older than `DATE`, and drops the fields and evidence of old
source events while keeping their dedupe keys and receipts. Work, questions, deliveries, launches,
usage receipts, automation runs, mail and memory are never pruned. The most recent day is refused
(`prune_too_recent`). One call examines at most 10,000 rows; repeat with `next` while `more` is true.
ptyd prunes its own journal after seven days and keeps at most 256 retained receipts (oldest
evicted, journalled).

### Backup

`host-state.py capture DATABASE SNAPSHOT_DIR` (in the bundle) writes a new owner-only (`0700`)
directory holding:

- `controller.db`: an online, read-only SQLite backup, integrity-checked;
- `secrets/`: a copy of the store's `secrets/` directory, each file keeping its owner-only mode;
- `snapshot.json`: the snapshot format, the store's schema and the number of secrets.

It accepts every schema the bundle's `threading-controller` reports it can open (its `--version`),
so it never needs editing for a new schema; pass `--controller PATH` to use another binary. It
refuses to overwrite anything, and refuses (leaving nothing behind) a `secrets/` that is a symlink,
contains a symlink, is not owner-only, holds a file another user owns or a file group- or
world-readable, or holds more than 4096 secrets or one over 16 KiB. The destination's parent must be
an owner-only directory:

```bash
install -d -m 700 ~/backups
python3 $G/host-state.py capture ~/.local/state/threading/controller/controller.db ~/backups/controller-$(date +%F)
```

It is safe while the supervisor runs. Back up, as sensitive material:

- the snapshot directory (it contains recipes, including plain `environment` values, memory, mail,
  history and every secret in clear text);
- the bundle you installed (its `manifest.json` identifies the generation), the `/opt` agent-binary
  copy if you use one, and any `authorized_keys` forced commands and ACLs you added.

ptyd's state is not worth backing up: it describes processes that a restore cannot bring back.

### Restore

`host-state.py restore SNAPSHOT DATABASE` writes a **disarmed** copy of the store at `DATABASE`
(a new file): every worker policy, automation, source and trigger is disabled (revision bumped), mail
peers stop pushing and pulling, and due schedules are cleared. Identity and records are preserved;
it never launches a restored execution, clears uncertainty, or starts a service. It restores the
snapshot's secrets as `secrets/` beside `DATABASE`, with their modes, and refuses
(`secrets_destination_exists`) before writing anything when a `secrets/` is already there. A
single-file snapshot from an older `host-state.py` still restores; it carries no secrets.

To test a backup, restore into an isolated private directory and inspect it with the CLI. Never
run a restored copy alongside the original: it has the same host ID and the same work.

To recover a host:

1. `systemctl --user stop threading-controller`; move the damaged store, its `-wal`/`-shm` and
   `secrets/` aside.
2. Restore the snapshot to `controller.db` in the `0700` controller directory (this also restores
   `secrets/`), and start the controller.
3. Reconcile launches: `active-launches`, then `launch-status`. Executions from before the incident
   that no ptyd knows are confirmed with `launch-confirm-stopped E STATE` once you know they are
   gone, then retried as appropriate.
4. Re-arm deliberately: read each revision (`worker-policy`, `automation`, `source`, `trigger`) and
   `worker-enable`, `automation-enable`, `source-enable`, `trigger-enable`; re-enable mail peers with
   `mail-peer-set` and `"push": true, "pull": true`.

### Upgrades and schema

There is no downgrade: a new binary migrates the store forward on first open, and the old binary
then refuses it. Plan:

1. Build and copy the new bundle; read its `threading-controller --version` to see the schema.
2. Quiesce: pause what should not start during the switch (`worker-pause`, `automation-pause`), then
   `systemctl --user stop threading-controller`. Running agents are unaffected.
3. Back up with `host-state.py capture`.
4. Move the two unit files aside (the installer refuses to overwrite a unit whose text differs), run
   the new installer without `--start` (with the same `--role`, socket and `--agent-binary` options),
   `systemctl --user daemon-reload`, and update the `/opt` agent-binary copy, your stable symlink,
   consumers' forced commands and the Mac's saved
   executable path.
5. `systemctl --user start threading-controller`; check `--version`, `host`, the journal and
   `launch-occupancy`; re-enable what you paused.
6. **ptyd** keeps running the old binary until restarted, which is fine while the protocol pair is
   compatible. Restart it only when `threading-ptyd sessions` is empty, since stopping the unit ends
   every held agent.
7. Remove an old `hosts/<generation>/` directory once nothing runs from it. Nothing removes it for
   you.

Rollback means restoring the pre-upgrade snapshot under the old bundle, losing changes made since.

## Security model

**Owner authority** is the Unix account that owns the store. Whoever can run the controller CLI as
that account (a shell, the Mac's SSH login, an `owner-rpc` forced-command key) can configure
recipes, enable work, answer questions as anyone (answers are owner-attested), read every record and
repair launches. Protect it like the account's SSH keys. It is never an HTTP service or an agent tool.

**Execution-scoped agent authority** is what a running agent gets: its execution ID and a private
credential (244 random bits, stored only as a `sha256:` digest), used through the broker. It can read
its work's context, questions, messages and history, checkpoint, ask, finish, use its own worker's
memory, the knowledge it is granted, and mail under the recipient's grants. It cannot claim, answer,
retry, stop, acknowledge deliveries, choose a destination, configure policy or reach another worker's
memory. A stopped launch revokes every call. The broker records the peer uid but never trusts it;
the credential is the authentication.

**Peer authority** (`mail-rpc`) can only push and pull mail for its own host's senders.

What this does not protect, stated plainly:

- In **same-account mode** an agent's shell has owner authority in practice (see
  [Mode A](#deployment-mode-a-one-unix-account)). The broker then limits what the agent's *tools*
  can do, not what its shell can do.
- In **separate-user mode** agents of one agent user are not isolated from each other; the
  controller user can run anything as the agent user; usage receipts are computed from transcripts
  the agent's account can write, so they are accounting, not tamper-proof evidence.
- Agents and probes have unrestricted network access and no cgroup or container boundary beyond the
  unit's limits. ptyd signals each agent's process group; a descendant that starts its own session
  (`setsid`) escapes that group kill.
- Probe sources run unsandboxed with the controller account's authority; approval pins their
  content, not their behaviour.
- `environment` values in recipes and the redacted failure tails are stored in the database and in
  backups. Provider logins and transcripts on the host are outside the controller and are as
  exposed as the account that owns them.
- Mail bodies, memory, shared knowledge, work messages and probe evidence are untrusted text. They
  may contain mistaken or malicious instructions and **never** grant a permission.

## Troubleshooting

| Symptom | Likely cause | What to run |
|---|---|---|
| Installer: `bundle_digest_mismatch` | A bundle file was modified after the build (strip, transfer mode, editor) | Re-copy the bundle byte for byte; never post-process it |
| Installer: `incompatible_bundle` | Built on another architecture or OS | Build on the target's architecture |
| Installer: `owned_service_home_required` | Home path has a dot or other character, is a symlink, or is not yours | Use a plain home path owned by the service account |
| Installer: `existing_service_requires_explicit_upgrade` | A unit from another generation exists | Follow [Upgrades](#upgrades-and-schema): move the old units aside first |
| Any command: `database_directory_requires_owner_only_access` | The store's directory is not `0700` and owned by you | `chmod 700` the directory; run as the owning account |
| Units stop when you log out; nothing runs after reboot | Linger is off | `sudo loginctl enable-linger <user>` |
| `systemctl --user`: "Failed to connect to bus" | No user manager session in this shell | Log in as the account over SSH, or `sudo machinectl shell <user>@` |
| ptyd exits 75 at start | Another daemon holds that state directory's lock | `threading-ptyd status`; stop the duplicate unit |
| `held: … host_unavailable` | ptyd socket missing, refusing or backing off | `systemctl --user status threading-ptyd`; check the recipe's `socketPath` |
| `held: … global_capacity` / `host_capacity` | 32 store-wide or 16 per-socket unresolved launches | `launch-occupancy`; resolve stale launches with `launch-status` and the fenced repairs |
| `held: … usageUnsettled` / `worker_capacity` | A stopped execution's usage is not settled, or the budget is spent | `worker-capacity W`; `usage-receipt E`; `usage-collect E`; `usage-waive E REASON` |
| Manual `launch`: `agent_broker_unavailable` | No resident supervisor is serving the broker | Start `threading-controller.service`; the legacy store-path mode (`THREADING_CONTROLLER_LEGACY_AGENT_DATABASE=1`) is for same-account testing only |
| Supervisor issue `agent_broker_unavailable` after `supervisor-tick` | One-shot tick without a resident supervisor; the intent stays prepared | Start the resident supervisor; it dispatches the intent if the same policy revision is still enabled |
| Work stays `running`, process long gone | Launch unresolved: no receipt and no inventory (e.g. ptyd state lost) | `launch-status E`; `launch-confirm-stopped E running` with evidence; `retry WORK` |
| `interrupt` refused | The launch is unresolved | Confirm the launch first; that interrupts the work |
| `owner-rpc`: `rpc_fence_required` | `launch-confirm-stopped` without the expected state | Pass the state you observed |
| `owner-rpc`: `rpc_command` | Command not on the allowlist (or not in this version), or more than 16 arguments | Check `host` features; run local-only commands in a shell |
| Any write: `unsupported_schema`; supervisor exits | A newer binary migrated the store; an old process is still running | Stop old processes; run the new generation everywhere |
| `conflict` on a mutation | Stale `EXPECTED_REVISION`, or a launch moved since you looked | Re-read the record and retry with its revision |
| Launch failed with `failure.stage = exit` | The agent exited without `work_finish` | `launch-record E` for the redacted tail; fix the recipe or provider login; `retry` |
| Dispatch fails, intent stays `prepared` | A secret named in the recipe is missing | `secret-set NAME FILE`, then the supervisor or `launch-dispatch E` |
| Source shows `changed` and never polls | Executable or script changed since approval | `source S` to see the new hash; review; `source-approve S REV HASH` |
| A source event created no work | No trigger was enabled when it arrived, the worker does not accept `event`, or `refused: backlog` | `source-events S` receipts; `worker-sources W`; enable triggers before polling |
| Automation run `refused` | Worker archived or no longer accepts `schedule` | `automation-runs A`; `worker-set-sources` |
| Mail not delivered across hosts | Peer not configured on both sides, transport fails, or response from the wrong host | `mail-peers`; `mail-outbound HOST`; `mail-sync`; check the forced-command key |
| Mail delivered but worker never woke | Grant is `notify`, worker lacks `event`, or chain budget/depth reached | `mail-grants ADDRESS`; `worker-sources W`; `mailbox ADDRESS` |
| Mac: host shows **Managed elsewhere** | An incompatible ptyd the Mac did not install holds the rendezvous | Upgrade that installer's daemon (for the bundle: a new bundle) |
| Mac: host refuses with host-key verification | The host is not in your `known_hosts` | Connect once in a terminal: `ssh <host>` |
| Mac Remote page: connection fails after an upgrade | The saved controller executable path names the old generation | Update the path on the Remote page (or use a stable symlink) |
| Mac remote chat keeps "Reconnecting…" | Tunnel cannot reach the host, or the daemon was replaced | `ssh <host> true`; on the host `threading-ptyd status` |

## Further reading

- [The PTY host](../architecture/pty-host.md): protocol, retire, receipts, the Linux build, failure model.
- [Autonomous host controller](../architecture/autonomous-controller.md): state machine, broker,
  separate-user layout, mail, sources, usage, hardening.
- [Triggers](../architecture/triggers.md): the Mac's automations, probe sources and the Remote page.
- [Remote execution hosts](../feature-drafts/remote-execution-hosts.md) and
  [Agent mail](../feature-drafts/agent-mail.md): the plans these features grew from, with their
  measurements.
- [Remote companion](remote-companion.md): pairing an iPhone or browser, which is a different
  feature from remote execution.
