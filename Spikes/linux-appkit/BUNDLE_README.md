# Threading Linux preview

This bundle runs the native Linux window and PTY daemon without a Swift toolchain or source
checkout. It currently targets Ubuntu 24.04 on arm64. It is a preview of the Linux host, not the
full macOS product UI or a system-installed desktop application. The graphical path has been
validated under Xvfb/X11; other desktop sessions remain unverified.

Install the Ubuntu runtime packages, then run `./run-app.sh [PROJECT_DIRECTORY]` from the
extracted bundle:

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

The `bin/` directory contains the window, store host and PTY daemon. Keep all three binaries
together: the window uses its sibling host for project-folder import. Closing the window leaves
live children with the daemon; running `./run-app.sh` again can reattach the selected agent or
open a saved terminal from its project's picker.
