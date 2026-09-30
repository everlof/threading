# Threading Linux preview

The archive and `.deb` run the native Linux window and PTY daemon without a Swift toolchain or
source checkout. They currently target Ubuntu 24.04 on arm64. This is a preview of the Linux host,
not the full macOS product UI. The graphical path has been validated under Xvfb/X11; Wayland and
other desktop sessions remain unverified.

Install the `.deb` with `sudo apt install ./threading-linux-preview-ubuntu24.04-arm64.deb`, then
open **Threading Linux Preview** from the desktop application menu. The package installs the
runtime dependencies, launcher, binaries and icon. To open a particular directory directly, run
`/opt/threading-linux-preview/run-app.sh [PROJECT_DIRECTORY]`.

For the standalone `.tar.gz` archive, install the Ubuntu runtime packages, then run
`./run-app.sh [PROJECT_DIRECTORY]` from the extracted bundle:

```bash
sudo apt update
sudo apt install libsdl2-2.0-0 libpangocairo-1.0-0 libatk-bridge2.0-0t64 \
  libsqlite3-0 zenity fonts-dejavu-core util-linux
```

With no project, the first launch opens an empty project list with **Add project folder**. The app
keeps its store under `${XDG_DATA_HOME:-$HOME/.local/share}/threading-linux-spike` and its daemon
socket under `${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/threading-linux-spike`. Set
`THREADING_LINUX_CODEX` or `THREADING_LINUX_CLAUDE` to an absolute executable path to enable a
provider, or to an empty value to disable it.

The launcher asks the configured login shell for its `PATH` once per start, using the same
`-l -c` mode as provider launches. It adds those directories ahead of the desktop session's
inherited `PATH`, so both the CLI and an `/usr/bin/env` interpreter such as Node can resolve.
A slow or failing shell profile falls back to the inherited `PATH`. Explicit
`THREADING_LINUX_CODEX` and `THREADING_LINUX_CLAUDE` values still take precedence, including an
empty value to disable a provider. If a provider is configured only by an interactive shell
profile, use the installed launcher with an explicit path, for example
`THREADING_LINUX_CODEX="$HOME/.local/bin/codex" /opt/threading-linux-preview/run-app.sh`.
For an application-menu override, copy
`/usr/share/applications/threading-linux-preview.desktop` to
`~/.local/share/applications/threading-linux-preview.desktop` and set its `Exec` to:

```ini
Exec=env PATH=/absolute/node/bin:/home/you/.local/bin:/usr/local/bin:/usr/bin:/bin THREADING_LINUX_CODEX=/home/you/.local/bin/codex /opt/threading-linux-preview/run-app.sh
```

Set the `PATH` to include the CLI's interpreter (for example, Node) as well as the CLI. Use
absolute paths in the desktop entry: it does not expand `$HOME`.

The `bin/` directory contains the window, store host and PTY daemon. Keep all three binaries
and the `LinuxAppKitSpike_WindowHarness.resources` folder together: the window uses its sibling host for project-folder import. Closing the window leaves
live children with the daemon; running `./run-app.sh` again reattaches the selected live agent or
standalone terminal. An exited or absent standalone terminal returns to the project list; saved
terminals are also available from their project's picker.
Opening a saved terminal explicitly starts a fresh shell if its prior child has exited or is
absent. The saved terminal keeps its identity and settings. Its recorded working directory is
used when available, with the owning project as fallback.
Live shells update that directory through local OSC 7 reports or one-second process sampling.
A shell without OSC 7 that changes directory and exits between samples may retain its previous
directory. Busy storage can also leave the last saved directory; the shell keeps running.
Shells created in this window appear in the saved-terminal picker immediately. Opening the same
shell from its project or saved row reuses its retained runtime.

The project navigator remains beside the terminal. Ctrl+Shift+P focuses it, and Tab returns to
the terminal; clicking a pane focuses it too. Up/Down and Enter select/open a project or saved
runtime without sending those keys to the shell. From the focused project list, Ctrl+Shift+P
opens the folder chooser. Escape backs out of a picker or returns focus to the terminal.
Alt+F4 closes the window while running children remain with the daemon.

Saved Claude and Codex sessions show their provider marks beside the title. If artwork is
unavailable, the row shows the provider name instead. Accessible labels retain the provider,
account and session identity. Custom account badges and themes are not available in this preview.

The sidebar's **Actions** button opens the supported commands for the selected project: open or
replace a shell, create Claude/Codex sessions, choose their accounts, browse saved runtimes and
add a project folder. Ctrl+Shift+Space opens it from either pane. Arrow keys select an action,
Enter invokes it, and Escape or Close returns to the previous pane. Unavailable commands remain
visible with a reason; opening the picker never launches a child. Availability and the selected
project are checked again when an action runs.
