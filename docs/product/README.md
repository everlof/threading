# Product documentation

These Markdown files are the public source of truth for the product website.
They are intentionally useful in two places:

- GitHub renders them as normal repository documentation.
- `web/scripts/sync-public-docs.mjs` turns the same files into the website docs.

Do not edit `web/app/docs/generated-docs.ts` by hand. Run:

```sh
cd web
npm run docs:sync
```

The generator records a source digest, and `npm run docs:check` fails when the
checked-in website copy is stale.

The documents explain supported product behavior. Maintainer rationale and
load-bearing implementation rules still belong in `docs/architecture/`.

## Contents

1. [Overview](overview.md)
2. [Getting started](getting-started.md)
3. [Sessions and attention](sessions-and-attention.md)
4. [Conversations, permissions, and subagents](conversations-permissions-subagents.md)
5. [Browser and execution audit](browser-and-audit.md)
6. [Git review](git-review.md)
7. [Managed work and recovery](managed-work-and-recovery.md)
8. [Accounts](accounts.md)
9. [Remote companion](remote-companion.md)
10. [Extensions](extensions.md)
11. [Themes](themes.md)
