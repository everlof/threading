# Linked Workrooms

> Draft, 2026-10-09. Product direction and rollout plan. A controller-backed local trial now covers unlinked rooms, typed links, bound work, named questions and answers, structured question context and PDF snapshots. Hosted access, reviewed rich presentation and external publication remain planned.

## Problem and intended contract

A coding agent can inspect code, documents and tickets, but the missing facts may live with a
domain expert, customer or project owner. A conversation in one agent session is a poor shared
inbox: other agents cannot reliably see which questions remain open, who can answer, which answer
was accepted, or what decision it affected. A comment on one external item is durable but does
not itself provide question ownership, answer admission, a useful visual explanation, or a safe
continuation for waiting work.

Create a **Linked Workroom** around an objective or decision. It has its own stable identity and
can begin without any external link. Later it can link to one or more Jira issues, support cases,
PRs, repositories, documents, prototypes or other references. Those links provide context and
destinations; no ticket owns the room or is required to create it. Agents reach the room through
scoped MCP tools; people use an authenticated web page. The room holds a short brief, questions,
answers, decisions, previews, evidence and links to execution. One person has an inbox across
rooms. A room may have several agents or work attempts, but its accepted facts do not depend on
any agent transcript surviving.

For Sonda, `SONDA-123` can be one link on a room. Jira remains the source of truth for its
engineering lifecycle; Sonda's own support ticket remains the source of truth for any customer
conversation (see `sonda/docs/support-ticket-jira-link-contract.md` in the separate Sonda repo;
check it again at implementation). The room owns the collaboration record. It links either
system where appropriate and may publish a concise, attributed decision summary to Jira through
a separately authorized adapter. It never copies an internal question into a customer thread
merely because a support ticket and Jira issue are linked.

This is different from Sonda's exploratory `mcp.sonda.se` strategy for exposing classification
tools to Sonda customers. Here MCP is the agent interface to human collaboration; the portal is
the human interface to the same records.

Current MCP has useful adjacent features, but they do not supply this record model. [Elicitation
in the 2026-07-28 protocol](https://blog.modelcontextprotocol.io/posts/2026-07-28/)
collects input during a client request; it does not route a durable question to another named
person days later. [MCP Apps](https://apps.extensions.modelcontextprotocol.io/api/documents/overview.html)
can render sandboxed interactive HTML inside a supporting agent client and may become an optional
view of a room. The authenticated portal remains the cross-agent, cross-person inbox and
source of answer truth. Threading's app MCP server currently declares `2025-06-18`; the
controller's `agent-mcp` supports through `2025-11-25`. The first slice should work with today's
tools and explicit room IDs, without making a protocol upgrade or client UI support a gate.

## Places this helps

- **An unlinked design decision:** start a room for a proposed Sonda classification flow, ask
  the domain expert which interpretation is correct, show an interactive comparison, save the
  accepted reasoning, then link implementation tickets after the decision is made.
- **Several related tickets:** keep one room for a shared product question, link each affected
  issue, and record exactly which issues the accepted answer applies to. Each issue keeps its own
  engineering status and implementation work.
- **A deliverable or client discussion:** link a draft document, prototype and eventual PDF. Give
  an external participant access only to the question and presentation intended for them. Link a
  resulting support case or engineering issue if one is later created.

Backlog grooming is a workflow over many rooms and linked issues, not the definition of a room.

## Example: groom `SONDA-123`

1. An agent reads the Jira issue, linked PRs and commits, current code, deployment evidence and
   related work. It opens or finds the linked room and drafts an assessment: what is already done,
   what is uncertain, what acceptance evidence is missing, and whether the ticket appears ready
   to implement. Each claim links to evidence; inferred status is labelled as an inference.
2. The agent drafts two questions: a domain decision for the named expert and a technical choice
   for the owner. The portal shows the relevant code-independent explanation, an optional
   interactive comparison, and an exportable PDF brief. The agent can select only recipients
   allowed for this room; a server-owned directory resolves their identities and permissions.
3. Each recipient sees the question in one inbox with room, reason, deadline if set, choices,
   a free-text answer and the consequence of each choice. They can answer, request clarification,
   or say they are not the right person. Their authenticated identity and the answer revision are
   recorded. A question is resolved only by an eligible answer under its declared resolution
   rule; an answer is information, not approval to deploy or widen an agent's permissions.
4. The dependent work resumes from its saved checkpoint. Unrelated tickets continue. The agent
   proposes an updated acceptance criterion or decision summary; the owner reviews publication
   to Jira. Jira state changes follow Sonda's existing evidence rules, rather than the agent's
   assertion that work is done.
5. Later agents see the resolved decision, provenance and scope. They do not re-ask the same
   question unless new evidence or a changed assumption makes it stale.

The useful output of backlog grooming is a **review queue**, not an automatic bulk rewrite:
likely done with missing proof, ready to build, waiting for a named person, blocked by a
dependency, duplicate, or needs investigation. Each proposed ticket change is reviewable
individually or in a bounded batch. The agent must not equate a merged PR, a deployed build and
a verified or released ticket.

## Records and behavior

- **Identity:** a room has a stable ID, owner scope, title and optional description. It can exist
  without an external reference. A room's own collaboration state is separate from every linked
  issue, document or execution state. Renaming or unlinking an external item does not replace the
  room or erase its history.
- **Links:** zero or more typed references with provider, tenant/site where applicable, opaque
  external ID, display label, relationship (`context`, `source`, `output` or `affected`), audience
  and verification time. One may be chosen as the display anchor; it is not an authority source.
  Add, remove and change-scope operations are attributed and revision checked. A connector
  rechecks visibility before fetching or changing an external item. The same external item may
  appear in more than one room, so agents propose a join or reuse instead of silently merging
  rooms by URL or title.
- **Assessment:** revisioned, attributed observations with source references and freshness.
  Keep facts, inferences and proposed changes distinguishable. A stale assessment remains
  history, never a current readiness badge.
- **Question:** stable ID, room, optional author execution, exact prompt and revision, intended
  audience, eligible recipient set or group, resolution rule, state, optional due time, optional
  work dependency, and attached presentation artifact versions. An unanswered question can be
  clarified or withdrawn without silently replacing the original prompt. Reassignment is a
  visible event with an authorized actor.
- **Answer and decision:** immutable answer revisions, authenticated human principal, timestamp,
  optional evidence, and explicit acceptance or supersession. A decision names its scope: this
  room, particular linked items, a set of rooms, or a reusable project rule. Reusing an answer
  elsewhere is a proposal until someone grants that wider scope.
- **Artifact:** versioned brief, bounded interactive HTML or PDF with content hash, audience,
  origin and source links. The question points to an exact artifact version, so an answer is not
  later paired with a different explanation. PDF is a readable snapshot/export of the same
  underlying brief; it does not become the only record of an answer.
- **Execution link:** optional work item, agent/session and checkpoint IDs connect collaboration
  to the existing controller. Room progress can have several attempts. Read-only assessments may
  run in parallel under a bounded concurrency budget. Write agents either use separate,
  explicitly enabled [managed workspaces](../architecture/managed-workspaces.md) or run
  serially on a shared checkout; one work item is reviewed before another depends on it.
  Dependency edges and a visible merge/review queue prevent two agents from silently editing the
  same checkout or treating a conflicting branch as integrated work.
- **Publication:** when a room has a supported destination link, an outbox records a proposed or
  approved update, external idempotency key, attempt and receipt. A timeout has an uncertain
  outcome until reconciled. Room history and an external destination may disagree temporarily;
  the UI names that state instead of claiming sync succeeded.

The default question resolution is one eligible person answering. A question that genuinely
needs both the domain expert and technical owner uses two questions with separate dependencies,
or a later explicit multi-party rule. Do not make `@name` text the access check. Notifications
are delivery hints; the authenticated inbox is the durable source of truth.

## MCP and human API boundary

The model-visible catalogue should be small and room-scoped. A host grants an agent access to a
specific room or bounded set of rooms. Proposed semantic operations are:

| Tool | Result or effect |
| --- | --- |
| `workroom_find` | Bounded lookup within the caller's granted scope, including exact external-link identity. |
| `workroom_create` | Open a room with a title and purpose when the host has granted creation in that scope. |
| `workroom_context` | Room identity, visible links, assessment, open questions, accepted decisions and bounded history. |
| `workroom_assess` | Propose a revisioned, evidence-linked assessment; it does not change an external item's state. |
| `workroom_questions` | List current questions and answer revisions for this room. |
| `workroom_ask` | Create a question using an allowed recipient ID/group, resolution rule and optional checkpoint dependency. |
| `workroom_present` | Propose a versioned brief or HTML/PDF artifact for human review and publication. |
| `workroom_propose_link` | Suggest a typed external reference or a connection to another room for human/host validation. |
| `workroom_propose_update` | Draft a change to a supported linked destination with evidence and its expected revision. |

The server derives the allowed room set and execution identity from the MCP credential and current
binding. A room ID or external link supplied by the model is a selector, never a grant. Room
creation needs a separate host-authored grant and is not required for the first pilot. The server
returns typed statuses, pagination and idempotent receipts. Human
answer, recipient grants, room access, publication, external state transitions and deployment
approval are human/host operations, absent from agent tools.
The authenticated web API and MCP adapter call the same domain operations and enforce the same
revision checks, but use different principals and grants. Never put the controller owner CLI
behind public HTTP or hand its credential to the browser.

The existing `ThreadingController` already has durable work, one blocking question per work item,
authorized answer and continuation, work dependencies, messages and delivery receipts
([architecture](../architecture/autonomous-controller.md)). Its execution-scoped `work_ask`
derives recipients from an immutable owner recipe. The workroom needs a host-authored recipient
policy/directory, linked questions across one room, nonblocking questions, rich artifacts and
an authenticated human adapter. Extend the controller's portable records where their semantics
fit; keep external link adapters, people/groups, hosted authentication and publication outside
the portable core. Do not create a second, competing work scheduler or infer answer authority
from text.

## Presentation and access

Start with semantic content blocks: paragraphs, source citations, comparison rows, images and
answer controls rendered by the portal. Offer interactive HTML only for cases that need it,
such as a map, parameter comparison or sequence diagram. Untrusted agent-authored HTML must be
reviewed before sharing and rendered on an isolated origin with a restrictive sandbox and CSP,
without portal cookies, credential access or arbitrary network calls. A control inside a preview
cannot submit an answer; the portal's own form commits the authenticated answer. PDFs are
generated from the published brief, carry version and date, and get text/accessibility review.

Access is per room and audience: owner, technical collaborator, domain expert, and later an
external client. Internal code/evidence, public explanation and customer data are separate
visibility classes. A recipient can see only the questions and artifacts addressed to them,
plus the minimal room context needed to answer. Revocation is checked on every read/write,
not only when a link is issued. The interface names who can see a draft before publication.
Question/answer retention and export must be deliberate because domain answers may become
long-lived product decisions.

Before implementation, apply the new-surface customization gate. This proposal treats the
authenticated inbox, question form, answer attribution and publication status as **host-only**:
Threading must retain identity, access, resolution, visibility and receipt truth. Presentational
brief blocks could later be extension components with versioned semantic inputs, provided an
extension cannot change those facts or answer on someone's behalf. Apply the UI theme boundary
and design system to any native Threading surface. The hosted portal needs its own design and
accessibility review. Inbox, room and linked-item lists must use indexed, bounded pages and
stable row updates; never materialize all rooms, questions or previews to render one page.

## Rollout and acceptance

1. **Contract and synthetic pilot:** one room linked to a Sonda-shaped Jira fixture and one room
   begun without a ticket, two named people, a domain question and a technical question. Prove
   links can be added later without changing room identity. Prove the human API and MCP caller
   cannot impersonate each other, cross rooms or publish externally. Prove answer, restart,
   continuation and revocation on the real controller path. No live Jira writes.
2. **Private workroom:** authenticated owner and domain expert, text/structured briefs, one
   question inbox across rooms, answer and clarification, optional durable links to controller
   work, and read-only Jira assessment for linked issues. Exercise one real ticket and one
   unlinked decision with publication still manual.
3. **Reviewed publication:** explicit draft/approve flow for supported linked destinations,
   starting with Jira decision summaries and acceptance criteria, with idempotent delivery and
   uncertain-outcome reconciliation. Add PDF export and bounded, sandboxed interactive HTML when
   a concrete question needs them.
4. **Backlog grooming and multiple agents:** bounded linked-item scan, evidence-based status
   suggestions, deduped questions, per-workspace write lanes, dependency view and concurrency/spend
   limits. A shared answer can be promoted to broader project knowledge only after scope review.
5. **External clients:** add only after identity, visibility, retention and customer/support
   ownership are tested with real roles. Do not expose internal workrooms through a chat guest
   invitation or assume a Jira account is a portal login.

Acceptance for the first real pilot: a person can create a room without a ticket, link a
`SONDA-*` issue later, and keep the room's identity and answer history. An agent can assess the
linked issue, address a question to the domain expert, show enough context for an answer, wait
without holding a process, resume only dependent work after an authenticated answer, and leave
a reviewable proposed Jira update with correct evidence and no unapproved external write. Two
simultaneous rooms must keep their identities, answers and artifacts separate.

## Decisions still needed

- First audience: only the technical owner and domain expert, or external clients from day one?
- Hosting and identity: which existing service will own human accounts and workroom access?
- Which link kinds and relationship names are needed for the first real rooms? The core should
  allow more than Jira without promising connectors for every URL.
- How should a Sonda Jira issue link to a Sonda support ticket when both exist, and what exact
  content is allowed to cross that boundary?
- Which real question needs interactive HTML first? Its required interaction should determine
  the artifact contract instead of building a general arbitrary web-app host upfront.
