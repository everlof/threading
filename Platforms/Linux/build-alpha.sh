#!/usr/bin/env bash
# Build the Intel alpha against Noble; alpha-smoke.sh checks its Ubuntu 26.04 runtime.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
revision=$(git -C ../.. rev-parse HEAD)
status=$(git -C ../.. status --porcelain)
dirty=$([[ -z $status ]] && echo false || echo true)
digest=$(python3 source-fingerprint.py)
mkdir -p out
evidence=$(mktemp -d "$PWD/out/alpha-build.XXXXXXXX")
printf 'Alpha build evidence: %s\n' "$evidence"
printf '%s\n' "$digest" > "$evidence/source.sha256"
git -C ../.. diff --binary HEAD > "$evidence/source.patch"
printf '%s\n' "$revision" > "$evidence/source-base.txt"
python3 - "$evidence" <<'SNAPSHOT'
from pathlib import Path
import subprocess, sys, tarfile
root = Path.cwd().parents[1]
paths = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=root)
with tarfile.open(Path(sys.argv[1]) / 'new-source-files.tar.gz', 'w:gz') as archive:
    for name in paths.decode().split('\0'):
        if name:
            archive.add(root / name, arcname=name, recursive=False)
SNAPSHOT
builder=swift:6.3.2-noble@sha256:d02671b53bebdf3be9dd82f51d2912d462fc9a017535272a266480c016e27f07
docker run --rm -i --init --platform linux/amd64 \
  -e "THREADING_LINUX_SOURCE_REVISION=$revision" -e "THREADING_LINUX_SOURCE_DIRTY=$dirty" \
  -e "THREADING_LINUX_SOURCE_DIGEST=$digest" -e "THREADING_LINUX_BUILD_JOBS=${THREADING_LINUX_BUILD_JOBS:-2}" \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux "$builder" bash -s <<'BUILD' 2>&1 | tee "$evidence/build.log"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
test "$(uname -m)" = x86_64
apt-get update -qq
apt-get install --no-install-recommends -y -qq libsqlite3-dev libsdl2-dev libpango1.0-dev libatk-bridge2.0-dev \
  libglib2.0-dev libgdk-pixbuf-2.0-dev librsvg2-common zlib1g-dev python3
./package-app.sh
BUILD
[[ $(python3 source-fingerprint.py) == "$digest" ]] || {
  echo 'alpha build: source inputs changed during the build; do not distribute this package' >&2
  exit 1
}
package=out/threading-linux-preview-ubuntu24.04-amd64.deb
shasum -a 256 "$package" > "$evidence/package.sha256"
printf 'Built: %s\nNext: ./alpha-smoke.sh\n' "$PWD/$package"
