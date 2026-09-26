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

The application-menu launch inherits the desktop session's `PATH`, which can omit CLI installs in
`~/.local/bin` or a shell-managed Node directory. If an installed provider is missing from the
window, use the installed launcher from a terminal with an explicit path, for example
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
together: the window uses its sibling host for project-folder import. Closing the window leaves
live children with the daemon; running `./run-app.sh` again can reattach the selected agent or
open a saved terminal from its project's picker.
