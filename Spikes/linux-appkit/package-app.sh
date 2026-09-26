#!/usr/bin/env bash
# Build a source-tree-independent preview for the Ubuntu Noble arm64 validation target.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 || $(uname -m) != aarch64 ]]; then
  echo 'package-app: build inside Ubuntu 24.04 arm64 (swift:6.3.2-noble)' >&2
  exit 1
fi

./vendor-core.sh --verify
if [[ -n ${THREADING_LINUX_SOURCE_REVISION:-} || -n ${THREADING_LINUX_SOURCE_DIRTY:-} ]]; then
  revision=${THREADING_LINUX_SOURCE_REVISION:-}
  dirty=${THREADING_LINUX_SOURCE_DIRTY:-}
else
  revision=$(git rev-parse HEAD) || { echo 'package-app: source revision unavailable' >&2; exit 1; }
  status=$(git status --porcelain) || { echo 'package-app: source status unavailable' >&2; exit 1; }
  dirty=$([[ -z $status ]] && echo false || echo true)
fi
if [[ ! $revision =~ ^[0-9a-f]{40,64}$ || ( $dirty != true && $dirty != false ) ]]; then
  echo 'package-app: valid source revision and dirty status are required' >&2
  exit 1
fi
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product WindowHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product LinuxHost
swift build --package-path ../../Targets/PTYHost -c release --static-swift-stdlib \
  --product threading-ptyd

bin_dir=$(swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --show-bin-path)
daemon_dir=$(swift build --package-path ../../Targets/PTYHost -c release \
  --static-swift-stdlib --show-bin-path)
name=threading-linux-preview-ubuntu24.04-arm64
mkdir -p out
staging=$(mktemp -d "$PWD/out/.bundle.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT
bundle=$staging/$name
mkdir -p "$bundle/bin"
install -m 0755 run-app.sh "$bundle/run-app.sh"
install -m 0755 "$bin_dir/WindowHarness" "$bundle/bin/WindowHarness"
install -m 0755 "$bin_dir/LinuxHost" "$bundle/bin/LinuxHost"
install -m 0755 "$daemon_dir/threading-ptyd" "$bundle/bin/threading-ptyd"
install -m 0644 BUNDLE_README.md "$bundle/README.md"
cat > "$bundle/BUNDLE-MANIFEST" <<EOF
format=threading-linux-preview-1
target=ubuntu-24.04-aarch64
source_revision=$revision
source_dirty=$dirty
EOF

output=$PWD/out/$name
rm -rf -- "$output"
mv -- "$bundle" "$output"
tar -C out -czf "out/$name.tar.gz" "$name"
echo "package-app: $output"
echo "package-app: $PWD/out/$name.tar.gz"
