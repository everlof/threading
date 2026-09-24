import re
import statistics
import sys
from pathlib import Path

records = []
for line in Path(sys.argv[1]).read_text().splitlines():
    if "1280x900" in line and ("STRESS RUNNING" in line or "STRESS ACK" in line):
        match = re.search(r"drawMs=([0-9.]+) presentMs=([0-9.]+)", line)
        if match:
            records.append(tuple(map(float, match.groups())))
assert len(records) >= 2, "no dense-screen rendering samples"
for column, label in enumerate(("draw", "present")):
    values = sorted(row[column] for row in records)
    p95 = values[min(len(values) - 1, int(len(values) * .95))]
    print(f"STRESS {label}: n={len(values)} median={statistics.median(values):.2f}ms p95={p95:.2f}ms max={max(values):.2f}ms")
