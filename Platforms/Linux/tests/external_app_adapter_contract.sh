#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fixture=$(mktemp -d /tmp/threading-open-in.XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/data/applications" "$fixture/config" "$fixture/project ; touch INJECTED"
project=$fixture/'project ; touch INJECTED'
capture=$fixture/captured-path
cat > "$fixture/opener.py" <<'PY'
#!/usr/bin/python3
import pathlib
import sys
pathlib.Path(sys.argv[2]).write_text(sys.argv[1], encoding='utf-8')
PY
chmod +x "$fixture/opener.py"
cat > "$fixture/data/applications/threading-test-open.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Threading Test Opener
Exec=$fixture/opener.py %f $capture
Icon=threading-test-icon
MimeType=inode/directory;
Terminal=false
EOF
cat > "$fixture/data/applications/threading-test-file.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Threading File Only
Exec=$fixture/opener.py %f $capture
MimeType=text/plain;
Terminal=false
EOF
cat > "$fixture/data/applications/mimeinfo.cache" <<EOF
[MIME Cache]
inode/directory=threading-test-open.desktop;
text/plain=threading-test-file.desktop;
EOF
cat > "$fixture/config/mimeapps.list" <<EOF
[Default Applications]
inode/directory=threading-test-open.desktop;
[Added Associations]
inode/directory=threading-test-open.desktop;
EOF
export XDG_DATA_HOME=$fixture/data XDG_CONFIG_HOME=$fixture/config
clang -Wall -Wextra -Werror tests/external_app_adapter_contract.c \
  Sources/LinuxWindowBridge/ExternalApps.c -I Sources/LinuxWindowBridge/include \
  $(pkg-config --cflags --libs gio-2.0) -o "$fixture/contract"
"$fixture/contract" "$project" "$fixture/missing"
for attempt in {1..50}; do
  [[ -f "$capture" ]] && break
  sleep .1
done
[[ -f "$capture" ]]
[[ $(cat "$capture") == "$project" ]]
[[ ! -e INJECTED && ! -e "$fixture/INJECTED" ]]
echo 'external app adapter: discovery and literal directory launch pass'
