#!/usr/bin/env bash
# Verify an already-built amd64 package in a clean Ubuntu 26.04 runtime.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
package=${1:-$PWD/out/threading-linux-preview-ubuntu24.04-amd64.deb}
[[ -f $package ]] || { echo "alpha-smoke: missing package: $package" >&2; exit 1; }
package=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$package")
mkdir -p out
evidence=$(mktemp -d "$PWD/out/alpha-smoke.XXXXXXXX")
printf 'Alpha evidence: %s\n' "$evidence"
runtime_image=ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
docker run --rm --init --platform linux/amd64 \
  -v "$package:/preview.deb:ro" -v "$PWD/tests:/tests:ro" -v "$evidence:/evidence" \
  "$runtime_image" bash /tests/alpha_runtime_smoke.sh 2>&1 | tee "$evidence/test.log"
