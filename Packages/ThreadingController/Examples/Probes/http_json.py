#!/usr/bin/env python3
"""Reports new objects from a JSON array at JSON_URL, identified by JSON_ID_FIELD. Sends the
last ETag so an unchanged endpoint costs one 304. Optional bearer token from secret JSON_BEARER."""
import json, os, sys, urllib.error, urllib.request

request = json.loads(sys.stdin.readline() or "{}")
url, id_field = os.environ.get("JSON_URL"), os.environ.get("JSON_ID_FIELD", "id")
if not url:
    print("JSON_URL is required", file=sys.stderr); sys.exit(1)
state = json.loads(request.get("cursor") or '{"etag": null, "seen": []}')
headers = {"Accept": "application/json"}
if state.get("etag"): headers["If-None-Match"] = state["etag"]
if os.environ.get("JSON_BEARER"): headers["Authorization"] = "Bearer " + os.environ["JSON_BEARER"]
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as response:
        items, etag = json.loads(response.read(2_000_000)), response.headers.get("ETag")
except urllib.error.HTTPError as error:
    if error.code == 304:
        print(json.dumps({"cursor": json.dumps(state)})); sys.exit(0)
    sys.exit(77 if error.code in (401, 403) else 75)
except Exception as error:
    print(f"fetch failed: {error}", file=sys.stderr); sys.exit(75)
known, emitted = set(state["seen"]), 0
for item in items if isinstance(items, list) else []:
    identity = str(item.get(id_field, "")) if isinstance(item, dict) else ""
    if not identity or identity in known or emitted >= request.get("limit", 50):
        continue
    fields = {k: v for k, v in item.items() if isinstance(v, (str, int, float, bool)) and len(str(v)) <= 1000
              and k.replace("_", "").replace("-", "").replace(".", "").isalnum()}
    print(json.dumps({"event": {"id": identity[:256], "fields": dict(list(fields.items())[:32]),
                                "evidence": json.dumps(item)[:16000]}}))
    state["seen"].append(identity); emitted += 1
state["seen"], state["etag"] = state["seen"][-1000:], etag
print(json.dumps({"cursor": json.dumps(state)}))
