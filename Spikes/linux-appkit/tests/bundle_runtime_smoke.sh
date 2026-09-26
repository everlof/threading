#!/usr/bin/env bash
# Run only the extracted artifact and a test fixture in an Ubuntu runtime image.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq >/dev/null
apt-get install -y -qq libsqlite3-0 libsdl2-2.0-0 libpangocairo-1.0-0 \
  libatk-bridge2.0-0t64 zenity fonts-dejavu-core xvfb xauth xdotool \
  xclip imagemagick python3 util-linux >/dev/null

if command -v swift >/dev/null; then
  echo 'bundle smoke: runtime unexpectedly has Swift' >&2
  exit 1
fi
tar -xzf /archive.tar.gz -C /tmp
bundle=/tmp/threading-linux-preview-ubuntu24.04-arm64
grep -Eq '^source_revision=[0-9a-f]{40,64}$' "$bundle/BUNDLE-MANIFEST"
grep -Eq '^source_dirty=(true|false)$' "$bundle/BUNDLE-MANIFEST"
for executable in "$bundle/bin/WindowHarness" "$bundle/bin/LinuxHost" "$bundle/bin/threading-ptyd"; do
  if ldd "$executable" | grep -q 'not found'; then
    ldd "$executable" >&2
    exit 1
  fi
done

fixture=$(mktemp -d /tmp/threading-bundle.XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p /evidence/out
ln -s /evidence/out /tmp/out
cd /tmp
xvfb-run -a python3 /test.py "$bundle/run-app.sh" "$bundle/bin/LinuxHost" \
  "$bundle/bin/threading-ptyd" "$bundle/bin" "$fixture" --bundled
