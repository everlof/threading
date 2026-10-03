#!/usr/bin/env bash
# Build both preview artifacts, then exercise them in a Swift-free Ubuntu image.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
./vendor-core.sh --verify
mkdir -p out/bundle-smoke
# A linked worktree's .git pointer may lead outside the Docker mount.
source_revision=${THREADING_LINUX_SOURCE_REVISION:-}
source_dirty=${THREADING_LINUX_SOURCE_DIRTY:-}
if [[ -z $source_revision && -z $source_dirty ]]; then
  source_revision=$(git -C ../.. rev-parse HEAD)
  source_status=$(git -C ../.. status --porcelain)
  source_dirty=$([[ -z $source_status ]] && echo false || echo true)
fi
if [[ ! $source_revision =~ ^[0-9a-f]{40,64}$ || ( $source_dirty != true && $source_dirty != false ) ]]; then
  echo 'bundle-smoke: valid source revision and dirty status are required' >&2
  exit 1
fi

docker run --rm -i --platform linux/arm64 \
  -e "THREADING_LINUX_SOURCE_REVISION=$source_revision" \
  -e "THREADING_LINUX_SOURCE_DIRTY=$source_dirty" \
  -v "$PWD/../..:/repo" \
  -w /repo/Platforms/Linux swift:6.3.2-noble bash -s <<'BUILD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq >/dev/null
apt-get install -y -qq libsqlite3-dev libsdl2-dev libpango1.0-dev libatk-bridge2.0-dev >/dev/null
./package-app.sh
out/threading-linux-preview-ubuntu24.04-arm64/bin/WindowHarness --project-row-layout-fixture
out/threading-linux-preview-ubuntu24.04-arm64/bin/WindowHarness --session-row-layout-fixture
out/threading-linux-preview-ubuntu24.04-arm64/bin/WindowHarness --terminal-row-layout-fixture
# Exercise the same Release emulator/client modules before leaving the build container.
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product CoreSliceHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product PortablePTYClientHarness
contract_bin=$(swift build -c release --show-bin-path)
timeout 120 "$contract_bin/CoreSliceHarness"
contract_fixture=$(mktemp -d /tmp/threading-contracts.XXXXXXXX)
out/threading-linux-preview-ubuntu24.04-arm64/bin/threading-ptyd \
  --socket "$contract_fixture/pty.sock" --state "$contract_fixture/daemon" >"$contract_fixture/daemon.log" 2>&1 &
contract_daemon=$!
trap 'kill "$contract_daemon" 2>/dev/null || true; wait "$contract_daemon" 2>/dev/null || true; rm -rf -- "$contract_fixture"' EXIT
for ((attempt=0; attempt<100; attempt++)); do
  [[ -S "$contract_fixture/pty.sock" ]] && break
  kill -0 "$contract_daemon" || { cat "$contract_fixture/daemon.log"; exit 1; }
  sleep .1
done
timeout 30 "$contract_bin/PortablePTYClientHarness" "$contract_fixture/pty.sock"
# Run the cleanup trap without depending on the container CLI forwarding stdin EOF.
exit 0
BUILD

grep -Fxq "source_revision=$source_revision" out/threading-linux-preview-ubuntu24.04-arm64/BUNDLE-MANIFEST
grep -Fxq "source_dirty=$source_dirty" out/threading-linux-preview-ubuntu24.04-arm64/BUNDLE-MANIFEST

docker run --rm -i --platform linux/arm64 \
  -v "$PWD/out/threading-linux-preview-ubuntu24.04-arm64.tar.gz:/archive.tar.gz:ro" \
  -v "$PWD/out/threading-linux-preview-ubuntu24.04-arm64.deb:/preview.deb:ro" \
  -v "$PWD/tests/app_startup_smoke.py:/test.py:ro" \
  -v "$PWD/tests/live_reinstall_smoke.py:/live-reinstall-test.py:ro" \
  -v "$PWD/tests/terminal_restart_smoke.py:/terminal_restart_smoke.py:ro" \
  -v "$PWD/tests/terminal_catalogue_smoke.py:/terminal_catalogue_smoke.py:ro" \
  -v "$PWD/tests/terminal_catalogue_limits_smoke.py:/terminal_catalogue_limits_smoke.py:ro" \
  -v "$PWD/tests/terminal_directory_smoke.py:/terminal_directory_smoke.py:ro" \
  -v "$PWD/tests/terminal_directory_identity_smoke.py:/terminal_directory_identity_smoke.py:ro" \
  -v "$PWD/tests/workspace_smoke.py:/workspace_smoke.py:ro" \
  -v "$PWD/tests/agent_catalogue_smoke.py:/agent_catalogue_smoke.py:ro" \
  -v "$PWD/tests/provider_marks_smoke.py:/provider_marks_smoke.py:ro" \
  -v "$PWD/tests/account_picker_rows_smoke.py:/account_picker_rows_smoke.py:ro" \
  -v "$PWD/tests/project_count_smoke.py:/project_count_smoke.py:ro" \
  -v "$PWD/tests/project_actions_smoke.py:/project_actions_smoke.py:ro" \
  -v "$PWD/tests/project_create_menu_smoke.py:/project_create_menu_smoke.py:ro" \
  -v "$PWD/tests/add_project_button_smoke.py:/add_project_button_smoke.py:ro" \
  -v "$PWD/tests/actions_smoke.py:/actions_smoke.py:ro" \
  -v "$PWD/tests/actions_mark_contract.py:/actions_mark_contract.py:ro" \
  -v "$PWD/tests/saved_terminal_child.py:/saved_terminal_child.py:ro" \
  -v "$PWD/tests/saved_terminal_refusal_smoke.py:/saved_terminal_refusal_smoke.py:ro" \
  -v "$PWD/tests/bundle_runtime_smoke.sh:/runner.sh:ro" \
  -v "$PWD/tests/desktop_entry_smoke.sh:/desktop-test.sh:ro" \
  -v "$PWD/tests/provider_path_smoke.sh:/provider-path-test.sh:ro" \
  -v "$PWD/out/bundle-smoke:/evidence" ubuntu:24.04 bash /runner.sh
