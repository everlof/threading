# Reclaimable storage outside projects

> Status: **shipped** (2026-08-14). This draft was implemented in full — the `xcodeDerivedData`
> kind recognized by Xcode's own manifest rather than by name, `scanScratch(roots:)` over
> `/private/tmp` and the per-user temporary directory, the scratch scope's second store file and
> its broader busy rule, the Storage page's read-time attribution into the three tiers, and both
> MCP tools covering the new scope.
>
> The durable decisions live in
> [`storage-and-stats.md`](../architecture/storage-and-stats.md) — the replaced-not-relaxed
> necessary gate and the `.git`-less `rsync` copies that forced it, recognition by shape with
> `DerivedDataManifest`, the three tiers and the one that is never offered, the roots/depth/prune
> bounds and the measurements behind each, the second `RecoverableFileStore` file, read-time
> attribution and existence filtering, and the ENOSPC instruction's two scopes. This pointer
> replaces the draft per this directory's rule.

Two research questions were open when it shipped and are not answered by the code, kept here
verbatim so the investigation is not lost:

- Does Codex leave a comparable manifest? Its scratch layout was not examined here;
  `codex-browser-use` is present in `/tmp` but was not measured. The same manifest rule should be
  applied rather than a path pattern, and if Codex writes nothing self-describing then its trees
  stay tier 3.
- Swift's `.build` outside a repository has `Package.swift` beside it but no manifest of its own.
  It is probably tier 3 for the same reason the repo copies are, but a `.build` in a scratch
  directory with no sources beside it may deserve its own reading.
