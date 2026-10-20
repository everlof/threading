#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
clang -O2 -I Sources/LinuxWindowBridge/include \
  tests/clipboard_selection_contract.c Sources/LinuxWindowBridge/ClipboardSelection.c \
  -lX11 -o "$test_dir/clipboard-contract"
head -c 2100000 /dev/urandom > "$test_dir/large-image"
printf 'file:///tmp/threading%%20image.png\r\n' > "$test_dir/uri-list"
export TEST_DIR="$test_dir"
xvfb-run -a bash -c '
  set -e
  xclip -selection clipboard -t image/png -i "$TEST_DIR/large-image"
  sleep .2
  "$TEST_DIR/clipboard-contract" image/png "$TEST_DIR/large-image"
  xclip -selection clipboard -t text/uri-list -i "$TEST_DIR/uri-list"
  sleep .2
  "$TEST_DIR/clipboard-contract" text/uri-list "$TEST_DIR/uri-list"
  echo "clipboard-selection: PASS"
'
