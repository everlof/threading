#!/usr/bin/env bash
#
# The grammar of a release tag, the ordering rule between the channels it names, and the
# changelog section that becomes its public release notes.
#
# A library rather than inline `case` statements in scripts/publish_release.sh, because this is
# the part of publishing that decides *what gets built and who receives it* from a string
# somebody typed once, and a rule that only exists inside a CI script is a rule nobody can run.
# scripts/tests/test_release_tag_policy.py drives it through the CLI at the bottom.
#
#   v0.2.0        a stable release          channel `release`, version 0.2.0
#   beta-v0.1.9   a beta of what follows    channel `beta`,    version 0.1.9
#
# The prefix carries the channel rather than a suffix on the version, because the version has to
# stay dotted digits: Sparkle orders updates with SUStandardVersionComparator, which reads
# nothing else. `v0.2.0-beta1` would parse as a version Sparkle cannot compare.
#
# ## Why a beta version is strictly below the stable it precedes
#
# CFBundleVersion and the marketing version are the same dotted string (scripts/release.sh), so
# a beta published as 0.2.0 is *equal* to the eventual stable 0.2.0 — and equal is not newer.
# Sparkle would never offer that tester the stable build that supersedes their own, and they
# would sit on a prerelease forever. So a beta of the upcoming 0.2.0 ships as 0.1.9x: above
# every stable already out, below the one it is a beta of.
#
# Only half of that is checkable at the moment a beta is published, because the stable it
# precedes does not exist yet. Both halves are checked at the moment they *can* be:
#
#   publishing a beta    it must be strictly above the newest published stable, or nobody
#                        running stable is ever offered it
#   publishing a stable  it must be strictly above every published beta, or the testers who
#                        took that beta are stranded on a build that outranks its own successor
#
# Together those close the loop without anyone having to remember the convention.

set -euo pipefail

readonly RELEASE_TAG_PATTERN='^v[0-9]+(\.[0-9]+)*$'
readonly BETA_TAG_PATTERN='^beta-v[0-9]+(\.[0-9]+)*$'

# Prints "<channel> <version>" for a tag, or fails naming what was wrong.
release_tag_describe() {
    local tag="${1:-}"
    if [[ "$tag" =~ $RELEASE_TAG_PATTERN ]]; then
        printf 'release %s\n' "${tag#v}"
        return 0
    fi
    if [[ "$tag" =~ $BETA_TAG_PATTERN ]]; then
        printf 'beta %s\n' "${tag#beta-v}"
        return 0
    fi
    printf "error: tag '%s' is neither v<dotted digits> nor beta-v<dotted digits>\n" "$tag" >&2
    return 1
}

# Prints -1, 0 or 1 for a<b, a==b, a>b. Dotted digits only, compared component by component
# with a missing component read as 0, so 1.2 and 1.2.0 are the same version.
release_version_compare() {
    local left="${1:-}" right="${2:-}"
    local pattern='^[0-9]+(\.[0-9]+)*$'
    [[ "$left" =~ $pattern ]] || { printf "error: '%s' is not dotted digits\n" "$left" >&2; return 2; }
    [[ "$right" =~ $pattern ]] || { printf "error: '%s' is not dotted digits\n" "$right" >&2; return 2; }

    local -a a b
    IFS='.' read -r -a a <<< "$left"
    IFS='.' read -r -a b <<< "$right"

    local count=$(( ${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]} ))
    local index left_part right_part
    for (( index = 0; index < count; index++ )); do
        # 10#… so a zero-padded component is read as decimal rather than octal.
        left_part=$(( 10#${a[index]:-0} ))
        right_part=$(( 10#${b[index]:-0} ))
        if (( left_part < right_part )); then printf '%s\n' -1; return 0; fi
        if (( left_part > right_part )); then printf '%s\n' 1; return 0; fi
    done
    printf '%s\n' 0
}

# True when `left` is strictly newer than `right`.
release_version_is_above() {
    [[ "$(release_version_compare "$1" "$2")" == "1" ]]
}

# Whether `<channel> <version>` may be published, given what already is.
#
# Reads the published releases on stdin as `<isPrerelease><tab><tag>` lines — the shape
# `gh release list --json isPrerelease,tagName` produces — and reads what is *served* rather
# than local tags, because a tag nobody pushed strands nobody. Tags this grammar does not
# recognise are skipped: the nightly feed lives at a rolling `nightly` tag and has nothing to
# do with this ordering.
#
# Sparkle compares one number across both channels, so a new build has to outrank everything
# already served whichever channel it belongs to. What differs is who gets hurt when it does
# not, which is why the two collisions are reported separately.
release_version_is_publishable() {
    local channel="${1:-}" version="${2:-}" current_tag="${3:-}"
    local newest_stable="" newest_prerelease=""
    local is_prerelease tag description published_version

    while IFS=$'\t' read -r is_prerelease tag; do
        [[ -n "$tag" ]] || continue
        # A publish is deliberately resumable. GitHub release creation and feed upload are
        # separate remote writes, so the process can fail after the release exists but before
        # appcast.xml lands beside it. Ignore only this exact tag on a retry; another tag that
        # allocated the same version remains a collision and must still fail closed.
        [[ -n "$current_tag" && "$tag" == "$current_tag" ]] && continue
        description="$(release_tag_describe "$tag" 2>/dev/null)" || continue
        read -r _ published_version <<< "$description"
        if [[ "$is_prerelease" == "true" ]]; then
            if [[ -z "$newest_prerelease" ]] \
                || release_version_is_above "$published_version" "$newest_prerelease"; then
                newest_prerelease="$published_version"
            fi
        else
            if [[ -z "$newest_stable" ]] \
                || release_version_is_above "$published_version" "$newest_stable"; then
                newest_stable="$published_version"
            fi
        fi
    done

    printf 'newest published stable: %s\n' "${newest_stable:-none}" >&2
    printf 'newest published beta:   %s\n' "${newest_prerelease:-none}" >&2

    if [[ -n "$newest_stable" ]] && ! release_version_is_above "$version" "$newest_stable"; then
        if [[ "$channel" == "beta" ]]; then
            printf "error: beta %s is not above the published stable %s, so Sparkle would offer it to nobody. Allocate a version between %s and the stable this beta precedes.\n" \
                "$version" "$newest_stable" "$newest_stable" >&2
        else
            printf "error: stable %s is not above the published stable %s, so nobody would be offered it.\n" \
                "$version" "$newest_stable" >&2
        fi
        return 1
    fi

    if [[ -n "$newest_prerelease" ]] && ! release_version_is_above "$version" "$newest_prerelease"; then
        if [[ "$channel" == "release" ]]; then
            printf "error: stable %s is not above the published beta %s, so every tester on that beta would be stranded on a build that outranks its own successor.\n" \
                "$version" "$newest_prerelease" >&2
        else
            printf "error: beta %s is not above the published beta %s, so the people already testing would not be offered it.\n" \
                "$version" "$newest_prerelease" >&2
        fi
        return 1
    fi
}

# Prints the body of one exact `## [version]` changelog section.
#
# Compare headings as strings, not regular expressions. Besides avoiding special meaning for
# dotted versions, this works identically in BSD awk on the release Mac and other awk variants.
release_notes_for_version() {
    local version="${1:-}" changelog="${2:-}"
    [[ -n "$version" && -f "$changelog" ]] || return 2
    awk -v heading="## [$version]" '
        $0 == heading { printing = 1; next }
        printing && substr($0, 1, 4) == "## [" { exit }
        printing { print }
    ' "$changelog"
}

# The CLI half, so the rules above are exercisable from a test without sourcing bash into it.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        describe) release_tag_describe "${2:-}" ;;
        compare) release_version_compare "${2:-}" "${3:-}" ;;
        publishable) release_version_is_publishable "${2:-}" "${3:-}" "${4:-}" ;;
        notes) release_notes_for_version "${2:-}" "${3:-}" ;;
        *)
            printf 'usage: %s describe <tag> | compare <a> <b> | publishable <channel> <version> [current-tag] < releases | notes <version> <changelog>\n' "$0" >&2
            exit 2
            ;;
    esac
fi
