#!/usr/bin/env python3
"""Reports messages that arrived in an IMAP folder since the last poll, by UID. The password
comes from a secret the source names (IMAP_PASSWORD); a login failure exits 77 so the source
shows "authentication needed" instead of retrying forever. The cursor is UIDVALIDITY:UID."""
import email, email.policy, imaplib, json, os, sys

request = json.loads(sys.stdin.readline() or "{}")
host, user, password = os.environ.get("IMAP_HOST"), os.environ.get("IMAP_USER"), os.environ.get("IMAP_PASSWORD")
folder = os.environ.get("IMAP_FOLDER", "INBOX")
if not (host and user and password):
    print("IMAP_HOST, IMAP_USER and the IMAP_PASSWORD secret are required", file=sys.stderr); sys.exit(1)
try:
    connection = imaplib.IMAP4_SSL(host, timeout=20)
except Exception as error:
    print(f"connect failed: {error}", file=sys.stderr); sys.exit(75)
try:
    connection.login(user, password)
except imaplib.IMAP4.error:
    print("login refused", file=sys.stderr); sys.exit(77)
status, data = connection.select(folder, readonly=True)
if status != "OK":
    print(f"cannot open {folder}", file=sys.stderr); sys.exit(1)
validity = connection.response("UIDVALIDITY")[1][0].decode()
prior_validity, _, prior_uid = (request.get("cursor") or ":0").partition(":")
last = int(prior_uid or 0) if prior_validity == validity else 0
if last == 0 and not request.get("cursor"):
    # First poll: start from now rather than reporting the whole mailbox.
    status, data = connection.uid("search", None, "ALL")
    uids = [int(u) for u in data[0].split()] if status == "OK" and data[0] else []
    print(json.dumps({"cursor": f"{validity}:{max(uids, default=0)}"})); sys.exit(0)
status, data = connection.uid("search", None, f"UID {last + 1}:*")
uids = sorted(int(u) for u in (data[0].split() if status == "OK" and data[0] else []) if int(u) > last)
for uid in uids[: request.get("limit", 50)]:
    status, parts = connection.uid("fetch", str(uid), "(BODY.PEEK[])")
    if status != "OK" or not parts or not isinstance(parts[0], tuple):
        continue
    message = email.message_from_bytes(parts[0][1], policy=email.policy.default)
    body = message.get_body(preferencelist=("plain",))
    text = body.get_content() if body is not None else ""
    print(json.dumps({"event": {"id": f"{validity}:{uid}", "occurredAt": str(message.get("Date", ""))[:64],
                                "fields": {"from": str(message.get("From", ""))[:1000], "to": str(message.get("To", ""))[:1000],
                                           "subject": str(message.get("Subject", ""))[:1000], "folder": folder},
                                "evidence": text[:16000]}}))
    last = uid
connection.logout()
print(json.dumps({"cursor": f"{validity}:{last}"}))
