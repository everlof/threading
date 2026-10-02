#!/usr/bin/env bash
#
# Build and run the vendored persistence slice on Linux.
# Use --sqlite for the independent production SQLite wrapper contracts.
#
# The per-file sweep (`sweep-core.sh`) answered "would this file type-check alone". This answers
# the two questions it structurally cannot: do the files compile *together*, and does the code
# then *work*. A cross-file break and a runtime failure are both invisible to a one-file
# type-check, and persistence is exactly where a silent behavioural difference would hurt.
#
# libsqlite3-dev is installed into the container each run rather than baked into an image, so the
# script stays self-contained. The disposable container does not retain the apt install.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

product=CoreSliceHarness
log_prefix=coreslice
configuration=debug
run_arg=
case "${1:-}" in
  "") [[ $# -eq 0 ]] || { echo "unexpected empty argument" >&2; exit 64; } ;;
  --sqlite)
    [[ $# -eq 1 ]] || { echo "usage: $0 [--sqlite|--navigation-stress]" >&2; exit 64; }
    product=SQLiteHarness
    log_prefix=sqlite
    # Verify the target consumes the checked copies, not an independently edited wrapper.
    for name in SQLiteDatabase ThreadingLogger; do
      cmp "Sources/SQLiteHarness/${name}.swift" "Sources/CoreSlice/${name}.swift"
    done
    ;;
  --navigation-stress)
    [[ $# -eq 1 ]] || { echo "usage: $0 [--sqlite|--navigation-stress]" >&2; exit 64; }
    configuration=release
    run_arg=--navigation-stress
    log_prefix=navigation-stress
    ;;
  *) echo "usage: $0 [--sqlite|--navigation-stress]" >&2; exit 64 ;;
esac

./vendor-core.sh --verify
mkdir -p out

# The whole repository is mounted, not just this directory, because the slice takes a real package
# dependency on ../../Packages/ThreadingDomain. That is deliberate: ThreadingDomain claims to be
# Foundation-only with no dependencies, and building it on Linux is the cheapest possible test of
# that claim.
docker run --rm -i --platform linux/arm64 -v "$PWD/../..:/repo" -w /repo/Platforms/Linux -e SPIKE_PRODUCT="$product" -e SPIKE_LOG_PREFIX="$log_prefix" -e SPIKE_CONFIGURATION="$configuration" -e SPIKE_RUN_ARG="$run_arg" swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
if ! dpkg -s libsqlite3-dev >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq libsqlite3-dev >/dev/null 2>&1
fi
echo "architecture: $(uname -m)"
echo "sqlite3: $(pkg-config --modversion sqlite3 2>/dev/null || echo 'header only')"
# Drain the complete output: head can SIGPIPE the compiler and discard the actual frontier.
build_args=()
# CoreSliceHarness uses @testable to exercise internal production APIs. Debug enables this by
# default; the opt-in Release measurement must request it explicitly for the same harness.
if [[ "${SPIKE_CONFIGURATION}" == release ]]; then build_args+=(-Xswiftc -enable-testing); fi
swift build -c "${SPIKE_CONFIGURATION}" --product "${SPIKE_PRODUCT}" "${build_args[@]}" 2>&1 | tee "out/${SPIKE_LOG_PREFIX}-build.log"
echo "--- run ---"
run_args=()
if [[ -n "${SPIKE_RUN_ARG}" ]]; then run_args+=("${SPIKE_RUN_ARG}"); fi
swift run --skip-build -c "${SPIKE_CONFIGURATION}" "${SPIKE_PRODUCT}" "${run_args[@]}" 2>&1 | tee "out/${SPIKE_LOG_PREFIX}-run.log"
INNER
