# Report alerts

The owned, authenticated receiver at `alerts.threading.codes/v1/report-alert` forwards bounded
metadata to Pushover. Existing report/crash notifications carry the report reference, source,
trigger and byte count. `threading.service-failure.summary` carries only a fixed API route family,
HTTP status, count and 15-minute window start. Neither event contains report text or screenshots.

Required secrets: `REPORT_ALERT_WEBHOOK_TOKEN`, `PUSHOVER_APP_TOKEN`, `PUSHOVER_USER_KEY`.
The webhook token must match the control plane. Credentials are never shipped in the app.

Bodies are streamed under a 4096-byte ceiling. Failure summaries have exact keys and bounded
values; the alert ID must match their window, route, status and count. Cache API deduplication is
best effort per Cloudflare location and recorded only after successful forwarding. Failed
forwards return 502 so the control plane retains/retries them. Existing report Queue retries are
unchanged. Failure summaries use normal priority; crash reports retain high priority.

`npm run check` checks this receiver. Its request authentication, rejection, forwarding and dedup
behavior is exercised by `Service/ThreadingControlPlane/test/service-failure-alerts.test.ts`.
Deploy this receiver before a control plane that emits a new alert event.
