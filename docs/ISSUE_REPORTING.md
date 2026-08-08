# iOS issue-report intake

Threading has three explicit report destinations. They share one consent screen, but they do not
share credentials or transport semantics.

1. **Send report** writes a bounded report to a protected iOS outbox and posts it to
   `https://threading.codes/api/reports`. The hosted intake creates an issue in a private GitHub
   feedback repository. Failed network and 5xx deliveries remain in the outbox and retry when the
   app launches or becomes active.
2. **Send to my Threading** appears only for a paired owner whose Mac exposes a project named
   `Threading` (or its historical `AnotherTerminal` checkout name). It creates a real agent task in
   that checkout through the existing authenticated `POST /api/session` route. It does not pass
   through the public service.
3. **Share files…** preserves the system share sheet and exports the full JSON report, optional
   note, and original PNG. The user chooses the destination.

Report creation uses HTTP because it is a durable, idempotent mutation. A WebSocket is useful for
later `received`, `triaged`, or `fixed` status notifications, but it must not be the only record of
submission: iOS suspends sockets and either endpoint can disappear after committing the mutation.

## Public wire contract

`ThreadingRemoteKit/PublicIssueReporting.swift` is the native contract. The hosted endpoint
revalidates every field independently because public input is untrusted.

- The description is required and capped at 10 KiB.
- Diagnostics use the existing content-free event and field allowlists. At most 250 of the newest
  records are retained and the encoded diagnostics are capped at 24 KiB.
- An opted-in screenshot becomes an at-most-12-KiB JPEG preview. The full PNG is available only
  through **Share files…**.
- The whole request is capped at 64 KiB.
- The report UUID is both the outbox key and idempotency key.

The private issue includes the description and diagnostics as inert fenced text. A screenshot
preview is stored as a base64 machine payload in a hidden issue-body comment. This deliberately
avoids making an authenticated attachment public. An agent can decode the preview; a later object
store can replace this representation without changing the app contract.

## GitHub App setup

Create a private repository dedicated to feedback. Do not target the public source repository:
screenshots and descriptions may contain private customer material.

Create and install a GitHub App on that one repository with **Issues: read and write** repository
permission. The deployed Next.js service needs these secrets:

```text
THREADING_REPORT_GITHUB_APP_ID
THREADING_REPORT_GITHUB_INSTALLATION_ID
THREADING_REPORT_GITHUB_PRIVATE_KEY
THREADING_REPORT_GITHUB_REPOSITORY=owner/private-feedback-repository
THREADING_REPORT_APP_TOKEN=<random high-entropy deployment token>
```

The private key can be a PEM value or a single-line secret with `\n` escapes. The service mints a
short-lived installation token for each intake operation. No GitHub credential is present in the
iOS binary.

Set these iOS build settings in the release environment:

```text
THREADING_REPORT_INTAKE_URL=https://threading.codes/api/reports
THREADING_REPORT_INTAKE_TOKEN=<same value as THREADING_REPORT_APP_TOKEN>
```

The URL defaults to the production value. The app token is an abuse barrier rather than a secret
identity—the value can ultimately be recovered from a distributed app. Production deployment
must also enforce an edge request/body limit and per-IP rate limit. The route has a small
per-process limiter as defense in depth; it is not sufficient across serverless instances.

## Agent pickup

The paired-Mac shortcut is immediate: creating the session launches the selected local agent with
the report as its initial task. The prompt explicitly treats every reporter value as untrusted
evidence, so prose in a report cannot become agent instructions.

Public issues are the durable inbox for reports from real users. Give the triage agent read access
to the private feedback repository and let it claim issues by assignee or a `triaging` label before
starting work. A single claimer must own that transition; WebSocket notifications may wake agents,
but GitHub remains the source of truth for ownership and state.

## Privacy and operations

- Submission happens only after the reporter reviews the selected fields and taps a destination.
- The diagnostic base excludes messages, prompts, paths, notification text, device names, and
  credentials. Additional device context remains separately opt-in and has no stable identifier.
- Pending public reports use complete iOS file protection and the outbox refuses more than 20
  reports rather than deleting an older unsent report.
- Configure retention and deletion policy on the private feedback repository. Treat every issue as
  customer data; never mirror it into a public issue automatically.
- Intake logs contain only bounded server/GitHub error summaries, never request bodies.
