# Linked Workrooms local trial

This is the first browser slice of [Linked Workrooms](../../docs/feature-drafts/linked-workrooms.md).
A room can begin without a ticket, then collect typed links to issues, documents, PRs or other
references. Controller work bound to the room can ask named people questions. Their answers are
stored in the controller and make waiting work eligible to resume.

## Start a fresh trial

From the repository root:

```sh
swift build --package-path Targets/Controller
python3 -m pip install -r Service/LinkedWorkrooms/requirements.txt
mkdir -p .build/linked-workrooms-demo
chmod 700 .build/linked-workrooms-demo
node Service/LinkedWorkrooms/server.mjs \
  --database "$PWD/.build/linked-workrooms-demo/controller.db" \
  --scope demo
```

Open the printed **owner link** in a browser on this Mac. Keep the server running. Create a room,
add an optional link, and use **Invite someone** with the person ID the agent addressed (for
example, `expert` for `person:expert`). A guest link lasts 24 hours while this server process
runs. The guest sees only their addressed questions in that room and can submit an answer.
An agent can add background, possible paths and source notes to a question through `work_ask`.
The portal renders those fields as text and offers a PDF snapshot. Source notes still need
human verification.
The browser service listens on `127.0.0.1` only; its links cannot be opened from another device.

The current browser page does not start agent work. A controller-managed worker must enqueue
work in the room and ask through its execution-scoped MCP tools (`workroom_context`,
`workroom_links`, `workroom_questions`, and the existing `work_ask`). The owner CLI has
`room-enqueue`, `room-works`, `room-questions`, and `room-questions-for` for a local integration
trial. `npm test` in this directory builds the CLI and exercises the complete HTTP/controller
question and answer path in an isolated private database.

This trial uses owner-created, in-memory bearer invitations. They are access to the named
recipient's questions, so treat them as private. It has no hosted sign-in, revocation UI,
cross-device reachability, Jira/SONDA connector, interactive agent-authored HTML, durable PDF artifacts,
or external publication. Use a fresh trial database: opening an older controller store with this
build migrates it to schema v11, which older controller binaries cannot open.
