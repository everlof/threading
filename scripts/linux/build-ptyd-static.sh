#!/usr/bin/env bash
#
# Build the shipping Linux `threading-ptyd` — static musl, stripped, generation-stamped — and run
# the daemon suite against that exact file.
#
#   build-ptyd-static.sh <repository> <absolute scratch> <absolute output directory>
#
# Runs inside a Linux Swift toolchain: the container scripts/test-ptyd-linux.sh starts, or the
# Linux build host scripts/build-controller-host.sh runs on. It is the one place the release
# daemon is built, so the binary a remote execution host is handed and the one a Rindabox host
# installs come out of the same command line.
#
# The generation comes from GENERATION_SHORT_VERSION, GENERATION_BUNDLE_VERSION and
# GENERATION_SOURCE_REVISION (see scripts/linux/ptyd-generation.sh). An empty value is not
# defined, so it reads as absent exactly as a missing Info.plist key does on macOS.
#
# The binary is stripped at link, so <output>/threading-ptyd is final: anything that hashes it
# hashes the bytes a host runs, and nothing may rewrite it afterwards (a later `strip` would
# invalidate every digest taken here).
set -euo pipefail

repository="${1:?usage: build-ptyd-static.sh REPOSITORY SCRATCH OUTPUT}"
scratch="${2:?usage: build-ptyd-static.sh REPOSITORY SCRATCH OUTPUT}"
output="${3:?usage: build-ptyd-static.sh REPOSITORY SCRATCH OUTPUT}"
for path in "${scratch}" "${output}"; do
  case "${path}" in /*) ;; *) echo "build-ptyd-static: ${path} must be absolute" >&2; exit 64 ;; esac
done
[[ "$(uname -s)" == Linux ]] || { echo "build-ptyd-static: Linux required" >&2; exit 64; }

# shellcheck source=toolchain.sh
source "${repository}/scripts/linux/toolchain.sh"
package="${repository}/Targets/PTYHost"
watchdog="${repository}/scripts/linux/xctest-watchdog.sh"
expected_skips="${repository}/scripts/linux/ptyd-expected-skips.txt"
case "$(uname -m)" in
  aarch64|arm64) sdk_triple="aarch64-swift-linux-musl" ;;
  x86_64|amd64) sdk_triple="x86_64-swift-linux-musl" ;;
  *) echo "build-ptyd-static: unsupported architecture $(uname -m)" >&2; exit 64 ;;
esac
mkdir -p "${scratch}" "${output}"

echo "--- static release build (${sdk_triple})"
if ! swift sdk list --swift-sdks-path "${scratch}/sdks" 2>/dev/null | grep -q static-linux; then
  swift sdk install "${threading_static_sdk_url}" --checksum "${threading_static_sdk_checksum}" \
    --swift-sdks-path "${scratch}/sdks"
fi
# Stripped at link: debug info is two thirds of the unstripped file (149 MB against 57 MB on arm64,
# measured), and the stripped binary is the one a host is handed.
static=(--package-path "${package}" --scratch-path "${scratch}/static"
  --swift-sdks-path "${scratch}/sdks" --swift-sdk "${sdk_triple}" -c release -Xlinker -s)
# The generation, for the C shim (`threading_build_*`).
for pair in SHORT_VERSION="${GENERATION_SHORT_VERSION:-}" \
  BUNDLE_VERSION="${GENERATION_BUNDLE_VERSION:-}" \
  SOURCE_REVISION="${GENERATION_SOURCE_REVISION:-}"; do
  [[ -n "${pair#*=}" ]] || continue
  static+=(-Xcc "-DTHREADING_PTYD_${pair%%=*}=\"${pair#*=}\"")
done
swift build "${static[@]}" --product threading-ptyd
install -m 0755 "$(swift build "${static[@]}" --show-bin-path)/threading-ptyd" "${output}/threading-ptyd"

if ldd "${output}/threading-ptyd" >/dev/null 2>&1; then
  echo "build-ptyd-static: ${output}/threading-ptyd links dynamically" >&2
  ldd "${output}/threading-ptyd" >&2
  exit 1
fi

echo "--- daemon tests against the static binary"
swift build --package-path "${package}" --scratch-path "${scratch}/debug" --build-tests
tests="$(swift build --package-path "${package}" --scratch-path "${scratch}/debug" --show-bin-path)/ThreadingPTYHostPackageTests.xctest"
env THREADING_PTYD_EXECUTABLE="${output}/threading-ptyd" \
  MARKETING_VERSION="${GENERATION_SHORT_VERSION:-}" \
  CURRENT_PROJECT_VERSION="${GENERATION_BUNDLE_VERSION:-}" \
  THREADING_SOURCE_REVISION="${GENERATION_SOURCE_REVISION:-}" \
  "${watchdog}" --expected-skips "${expected_skips}" "${tests}" \
  ThreadingPTYHostTests.PTYHostDaemonTests ThreadingPTYHostTests.PTYHostCLITests
echo "--- generation ${GENERATION_SHORT_VERSION:-} (${GENERATION_BUNDLE_VERSION:-})${GENERATION_SOURCE_REVISION:+ @${GENERATION_SOURCE_REVISION}}, asserted by testHelloCarriesTheGenerationTheBuildWasGiven"
ls -l "${output}/threading-ptyd"
