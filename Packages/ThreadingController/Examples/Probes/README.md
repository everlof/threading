# Example trigger-source probes

A probe is any executable that follows the contract in
[`portable-trigger-sources.md`](../../../../docs/feature-drafts/portable-trigger-sources.md):

- **stdin**: one JSON object, `{"cursor": <string or null>, "limit": <max events>}`.
- **stdout**: JSON lines — `{"event": {"id", "revision"?, "occurredAt"?, "fields"?, "evidence"?}}`
  for each event, then exactly one `{"cursor": "<string>"}` line, last.
- **exit**: 0 healthy, 75 back off, 77 authentication needed, anything else failed. Stderr is a
  bounded diagnostic shown on the source's health, never to an agent.
- **environment**: only what the source configures, plus `THREADING_SOURCE_ID` and
  `THREADING_SOURCE_REVISION`; secrets arrive as environment variables named in the source.
  The working directory is a private per-source state directory.

These run no model and cost nothing until one of their events matches a trigger. Copy one, edit
it, and configure it as a source; the approval records its SHA-256, and editing the file pauses
the source until the new content is approved. A probe runs with your account's authority and is
not sandboxed.

| Probe | Watches | Configure |
|---|---|---|
| `file_drop.py` | new files in a directory | `DROP_DIRECTORY` |
| `rss.py` | new items in an RSS or Atom feed | `FEED_URL` |
| `imap_unseen.py` | new messages in an IMAP folder | `IMAP_HOST`, `IMAP_USER`, secret `IMAP_PASSWORD`, optional `IMAP_FOLDER` |
| `http_json.py` | a JSON endpoint whose array of objects grows | `JSON_URL`, `JSON_ID_FIELD`, optional secret `JSON_BEARER` |
