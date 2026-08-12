# Production issue-reporting setup TODO

This is the release-blocking checklist for the private developer inbox. None of these boxes is
checked merely because the binding or code exists in the repository; check one only after the
production Cloudflare account has been inspected.

## Storage and service

- [ ] Create `threading-private-issue-reports` in the production account and bind it as
  `ISSUE_REPORTS`.
- [ ] Keep R2 public access, `r2.dev`, custom domains, public credentials, and CORS disabled.
- [ ] Install a mandatory 30-day lifecycle for `reports/v1/` and verify deletion with an aged
  staging object.
- [ ] Create production D1, replace the checked-in placeholder ID, and apply migration
  `0007_issue_report_quota.sql`.
- [ ] Allocate distinct production namespaces for every checked-in rate-limit binding.
- [ ] Generate an independent random `REPORT_PICKUP_TOKEN` of at least 32 bytes, install it with
  `wrangler secret put`, and store the operator copy in the team secret manager—not an app,
  script argument, shell history, or repository file.
- [ ] Deploy through `npm run deploy`; verify `/ready` and confirm Worker logs contain metadata
  only.

## Abuse and availability

- [ ] Add a Cloudflare zone rule limiting request body size and request rate for
  `POST /v1/reports` before Worker execution.
- [ ] Alert well before the D1 daily ceiling of 2,000 and on sustained 429, 5xx, or R2 write
  failure rates. Route the alert to an owned on-call channel.
- [ ] Configure Worker/R2 spend alerts and document the emergency intake-disable procedure.
- [ ] Load-test source rotation against the global admission ceiling. Record the acceptable
  legitimate-report reserve and add authenticated reserved capacity when account credentials are
  available on both apps.
- [ ] Treat optional client proof-of-work or iOS App Attest only as cost multipliers; neither is a
  universal identity boundary for the macOS client.

## Developer pickup and triage

- [ ] Verify unauthenticated and incorrect-token calls to `GET /v1/developer/reports` fail, while
  the correct developer token can list metadata and retrieve one exact UUID.
- [ ] Put the pickup credential in a protected operator/triage client and rotate it on staff or
  device changes. Never distribute it with Threading.
- [ ] Configure a metadata-only notification for new R2 objects (for example R2 event
  notification to a private Queue/Worker that alerts the triage channel). Do not include the
  description or screenshot in the alert.
- [ ] Document who owns the inbox, its response expectation, and the sanitization review required
  before creating any public GitHub issue.
- [ ] Exercise a release-candidate report from macOS manual, macOS inspector, macOS post-crash,
  and iOS; verify receipt, private pickup, retry after a forced outage, and 30-day deletion.

## Privacy audit

- [ ] Confirm stored objects contain no raw logs, `.ips` body, stack frames, terminal output,
  prompts, paths, notification text, credentials, or stable device/account names.
- [ ] Confirm inspector upload strips its temporary PNG path and carries only the bounded JPEG
  preview the reporter saw.
- [ ] Re-run the diagnostic coverage review in
  `docs/architecture/issue-report-diagnostics.md` whenever the public DTO changes.
