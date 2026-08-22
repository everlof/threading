#!/usr/bin/env bash
#
# Thins every Mach-O inside an app bundle to one architecture.
#
# Threading ships for Apple silicon only (docs/architecture/releasing.md, "Apple silicon only").
# The project builds its own targets arm64-only, but two embedded products arrive prebuilt and
# universal from Swift packages — WebRTC.xcframework and Sparkle.xcframework — and the build
# copies what it is given. release.sh runs this on the archive's app *before* export: the export
# re-signs every nested binary with the Developer ID identity, so the seals thinning breaks are
# replaced anyway, and the export verification then proves each binary carries exactly one slice.
#
# Usage: scripts/thin_app_architectures.sh <Threading.app> <arch>
#
# Exits non-zero if any Mach-O in the bundle lacks the requested slice: a binary that cannot be
# thinned to the product's architecture is a binary the product cannot run.

set -euo pipefail

app="${1:?usage: thin_app_architectures.sh <app> <arch>}"
arch="${2:?usage: thin_app_architectures.sh <app> <arch>}"
[[ -d "$app" ]] || { echo "error: no bundle at $app" >&2; exit 1; }

already_thin=0
removed_bytes=0
# -type f skips the Versions/Current symlinks in frameworks, so each binary is visited once.
while IFS= read -r binary; do
    file -b "$binary" | grep -q "Mach-O" || continue
    architectures="$(lipo -archs "$binary")"
    if [[ "$architectures" == "$arch" ]]; then
        already_thin=$((already_thin + 1))
        continue
    fi
    [[ " $architectures " == *" $arch "* ]] \
        || { echo "error: ${binary#"$app"/} has no $arch slice (found: $architectures)" >&2; exit 1; }

    before="$(stat -f %z "$binary")"
    thinned="$binary.thin.$$"
    lipo "$binary" -thin "$arch" -output "$thinned"
    chmod "$(stat -f %OLp "$binary")" "$thinned"
    mv -f "$thinned" "$binary"
    after="$(stat -f %z "$binary")"
    removed_bytes=$((removed_bytes + before - after))
    echo "  thinned ${binary#"$app"/}: $architectures → $arch, -$(( (before - after) / 1024 )) KB"
done < <(find "$app" -type f -perm +111)

echo "  $already_thin binaries were already $arch-only; removed $((removed_bytes / 1024)) KB of other slices"
