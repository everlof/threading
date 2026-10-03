#!/usr/bin/env python3
"""Reports each new regular file in DROP_DIRECTORY once. Cursor: the names already reported,
bounded to the newest 1,000 so the cursor stays small."""
import json, os, sys

request = json.loads(sys.stdin.readline() or "{}")
directory = os.environ.get("DROP_DIRECTORY")
if not directory or not os.path.isdir(directory):
    print("DROP_DIRECTORY is not a directory", file=sys.stderr)
    sys.exit(1)
seen = json.loads(request.get("cursor") or "[]")
known = set(seen)
entries = sorted((e for e in os.scandir(directory) if e.is_file(follow_symlinks=False)), key=lambda e: (e.stat().st_mtime, e.name))
emitted = 0
for entry in entries:
    if entry.name in known or emitted >= request.get("limit", 50):
        continue
    stat = entry.stat()
    with open(entry.path, "rb") as handle:
        head = handle.read(4096).decode("utf-8", "replace")
    print(json.dumps({"event": {"id": entry.name, "fields": {"name": entry.name, "size": stat.st_size,
                                                          "extension": os.path.splitext(entry.name)[1].lstrip(".")},
                                "evidence": head}}))
    seen.append(entry.name)
    emitted += 1
print(json.dumps({"cursor": json.dumps(seen[-1000:])}))
