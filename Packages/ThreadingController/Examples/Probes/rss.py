#!/usr/bin/env python3
"""Reports new items of the RSS or Atom feed at FEED_URL. Cursor: ids already reported (newest
500). A network failure asks the host to back off rather than failing the source."""
import json, os, sys, urllib.request, xml.etree.ElementTree as ET

request = json.loads(sys.stdin.readline() or "{}")
url = os.environ.get("FEED_URL")
if not url:
    print("FEED_URL is required", file=sys.stderr); sys.exit(1)
try:
    with urllib.request.urlopen(url, timeout=20) as response:
        root = ET.fromstring(response.read(2_000_000))
except Exception as error:
    print(f"fetch failed: {error}", file=sys.stderr); sys.exit(75)
atom = "{http://www.w3.org/2005/Atom}"
items = []
for item in root.iter("item"):
    items.append((item.findtext("guid") or item.findtext("link") or "", item.findtext("title") or "",
                  item.findtext("link") or "", item.findtext("description") or ""))
for entry in root.iter(atom + "entry"):
    link = entry.find(atom + "link")
    items.append((entry.findtext(atom + "id") or "", entry.findtext(atom + "title") or "",
                  link.get("href", "") if link is not None else "", entry.findtext(atom + "summary") or ""))
seen = json.loads(request.get("cursor") or "[]")
known, emitted = set(seen), 0
for identity, title, link, summary in reversed(items):
    if not identity or identity in known or emitted >= request.get("limit", 50):
        continue
    print(json.dumps({"event": {"id": identity[:256], "fields": {"title": title[:1000], "link": link[:1000]},
                                "evidence": summary[:16000]}}))
    seen.append(identity); emitted += 1
print(json.dumps({"cursor": json.dumps(seen[-500:])}))
