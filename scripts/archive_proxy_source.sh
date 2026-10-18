#!/bin/bash
#
# Archives threading-proxyd's complete corresponding source at one commit, for publication beside
# the Threading release built from it.
#
# The helper is GPL-3.0-only and Threading.app does not carry its source: the upstream archives it
# is built from were 27% of the download. GPLv3 §6(d) lets the source be offered from the same
# place as the object code instead, so release.sh writes this archive next to the zip, every
# publisher (publish_release.sh, .github/workflows/nightly.yml) attaches the two together, and the
# app's Legal/THIRD_PARTY_NOTICES.md says where to find it. See docs/architecture/releasing.md,
# "The proxy helper's source".
#
# The archive is the committed Targets/ProxyHost tree, which is what a clean checkout builds. The
# helper's own offline provenance test runs on the extracted copy, so an archive missing a
# dependency, or holding a stub where one should be, is refused rather than published.
#
# Usage: scripts/archive_proxy_source.sh <commit> <version> <output directory>
# Prints the archive's path.

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <commit> <version> <output directory>" >&2
    exit 64
fi

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
commit="$1"
name="threading-proxyd-source-$2"
output_directory="$(cd "$3" && pwd)"
archive="$output_directory/$name.tar.gz"
check_directory="$(mktemp -d "$output_directory/.proxy-source-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT

git -C "$repository_root" archive --format=tar.gz --prefix="$name/" -o "$archive" \
    "$commit:Targets/ProxyHost"
tar -xzf "$archive" -C "$check_directory"
if ! python3 -I "$check_directory/$name/tests/provenance.py" >&2; then
    rm -f "$archive"
    echo "error: the proxy source archived from $commit does not verify against its manifest" >&2
    exit 1
fi
echo "$archive"
