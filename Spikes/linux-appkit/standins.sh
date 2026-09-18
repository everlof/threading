#!/usr/bin/env bash
#
# Builds the one stand-in the core slice needs, by *extracting* rather than rewriting.
#
# `Project` persists a `TerminalThemeID`. That identifier is a Foundation-only string wrapper —
# but it is declared in `Models/TerminalTheme.swift`, whose first two lines are `import AppKit`
# and `import SwiftTerm`, because the same file also holds the theme's colours and its
# `asSwiftTermColors()` bridge. So the persistence layer's transitive closure reaches a terminal
# emulator and a UI framework through an identifier that needs neither, and the closure stops dead
# there on Linux.
#
# `application-structure.md` already says where this belongs: "ThreadingDomain owns typed project,
# session, terminal, transcript, and account identities". `TerminalThemeID` is a terminal identity
# living outside it. Splitting the file is a small, ordinary change on master and it is what this
# script stands in for — the lines below are lifted verbatim, so when the real split happens this
# stand-in is deleted rather than reconciled.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source_file="../../Sources/Threading/Models/TerminalTheme.swift"
destination="Sources/CoreSlice/TerminalThemeID.swift"

# The identity half of the file: from the "Identity" mark to the end of TerminalThemeNames.
first=$(grep -n '^// MARK: - Identity' "${source_file}" | head -1 | cut -d: -f1)
last=$(grep -n '^public enum TerminalThemeNames' "${source_file}" | head -1 | cut -d: -f1)
last=$(awk -v start="${last}" 'NR >= start && /^}/ { print NR; exit }' "${source_file}")

{
  echo "// EXTRACTED, NOT WRITTEN. Lines ${first}-${last} of Sources/Threading/Models/TerminalTheme.swift,"
  echo "// verbatim, under a Foundation-only import. Regenerate with ./standins.sh; see its header for"
  echo "// why this exists and what should replace it."
  echo ""
  echo "import Foundation"
  echo ""
  sed -n "${first},${last}p" "${source_file}"
} > "${destination}"

rm -f Sources/CoreSlice/TerminalTheme.swift
echo "extracted lines ${first}-${last} into ${destination}"

# The second split, and the same shape as the first.
#
# `Project` persists a `LimitRecoveryPolicy`; that file posts an `AppSettingsDidChange`; that event
# is declared in `Core/Settings/SettingsEvents.swift` — a 31-line file that also declares
# `ProfileDidChange`, whose payload is a `TerminalProfile`, which imports AppKit. So four lines at
# the bottom of one file put AppKit in the transitive closure of saving a project.
#
# The fix on master is to move `ProfileDidChange` beside the type it carries. Everything above it
# is Foundation-only and is taken verbatim here.
events_source="../../Sources/Threading/Core/Settings/SettingsEvents.swift"
events_destination="Sources/CoreSlice/SettingsEvents.swift"
profile_line=$(grep -n '^public struct ProfileDidChange' "${events_source}" | head -1 | cut -d: -f1)
keep=$((profile_line - 1))

{
  echo "// EXTRACTED, NOT WRITTEN. Lines 1-${keep} of Sources/Threading/Core/Settings/SettingsEvents.swift,"
  echo "// verbatim — everything except ProfileDidChange, whose TerminalProfile payload is the only"
  echo "// thing in the file that needs AppKit. Regenerate with ./standins.sh."
  echo ""
  sed -n "1,${keep}p" "${events_source}"
} > "${events_destination}"

rm -f Sources/CoreSlice/TerminalProfile.swift
echo "extracted lines 1-${keep} into ${events_destination} (dropped ProfileDidChange)"
