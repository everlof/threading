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
  -w /repo/Spikes/linux-appkit swift:6.3.2-noble bash -s <<'BUILD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq >/dev/null
apt-get install -y -qq libsqlite3-dev libsdl2-dev libpango1.0-dev libatk-bridge2.0-dev >/dev/null
./package-app.sh
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
  -v "$PWD/tests/saved_terminal_child.py:/saved_terminal_child.py:ro" \
  -v "$PWD/tests/saved_terminal_refusal_smoke.py:/saved_terminal_refusal_smoke.py:ro" \
  -v "$PWD/tests/bundle_runtime_smoke.sh:/runner.sh:ro" \
  -v "$PWD/tests/desktop_entry_smoke.sh:/desktop-test.sh:ro" \
  -v "$PWD/tests/provider_path_smoke.sh:/provider-path-test.sh:ro" \
  -v "$PWD/out/bundle-smoke:/evidence" ubuntu:24.04 bash /runner.sh
