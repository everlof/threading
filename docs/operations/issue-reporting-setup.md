# Production issue-reporting setup TODO

This is the release-blocking checklist for the private developer inbox. None of these boxes is
checked merely because the binding or code exists in the repository; check one only after the
production Cloudflare account has been inspected.

## Storage and service

- [ ] Apply `Service/ThreadingControlPlane/infra/` and verify it created
  `threading-private-issue-reports`, the report Queue, dead-letter Queue and R2 event notification.
- [ ] Keep R2 public access, `r2.dev`, custom domains, public credentials, and CORS disabled.
- [ ] Verify Terraform's mandatory 30-day lifecycle for `reports/v1/` by deleting an aged
  staging object.
- [ ] Verify Terraform created production D1; run the guarded deploy and confirm migration
  `0007_issue_report_quota.sql`. The deploy renders D1's output into a temporary config; do not
  replace the checked-in placeholder.
- [ ] Allocate distinct production namespaces for every checked-in rate-limit binding.
- [ ] Generate an independent random `REPORT_PICKUP_TOKEN` of at least 32 bytes, install it with
  `wrangler secret put`, and store the operator copy in the team secret manager—not an app,
  script argument, shell history, or repository file.
- [ ] Install `REPORT_ALERT_WEBHOOK_URL` and an independent 32-byte-or-longer
  `REPORT_ALERT_WEBHOOK_TOKEN`; confirm the URL has HTTPS, no embedded credential/query/fragment,
  and is owned by the team.
- [ ] Deploy through `npm run deploy`; verify `/ready` and confirm Worker logs contain metadata
  only.
- [ ] Set `ThreadingReportIntakeURL` in the shipping app's Info.plist to the deployed intake URL,
  and confirm a release build reports a receipt rather than **saved**. There is deliberately no
  compiled-in fallback: a build that states no endpoint writes its record and posts nothing, so
  omitting this key ships an app whose reports never leave the user's Mac.

## Abuse and availability

- [ ] Verify Terraform's zone rule rate-limits the exact report host/path before Worker execution.
  Cloudflare's lower plans cannot match method or body size in rate-limit rules; the Worker must
  retain its exact POST route and streaming 64-KiB ceiling rather than claiming a nonexistent WAF
  body-size gate.
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
- [ ] Exercise the Terraform R2 event notification and Worker Queue consumer. Confirm the webhook
  receives only report ID/reference, `report|crash|diagnostics` kind, trigger, source, receipt time
  and size. Force five failures, inspect the 14-day dead-letter Queue, and redrive after recovery.
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
