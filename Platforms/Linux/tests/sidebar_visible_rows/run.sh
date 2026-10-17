#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build -c release --product SidebarVisibleRowsHarness
bin=$(swift build -c release --show-bin-path)
"$bin/SidebarVisibleRowsHarness"
