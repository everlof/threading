#!/usr/bin/env python3
"""Compare one bounded supervisor pass before/after retained history; no provider or socket."""
import json
from pathlib import Path
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
import uuid


def main():
    binary = str(Path(sys.argv[1]).resolve())
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 100_000
    if not 100 <= count <= 1_000_000: raise SystemExit("history count must be 100..1000000")
    with tempfile.TemporaryDirectory(prefix="supervisor-profile-") as root:
        database = str(Path(root) / "controller.db")
        worker = str(uuid.uuid4())

        def call(*args):
            start = time.perf_counter()
            result = subprocess.run([binary, "--database", database, *args], check=True,
                                    capture_output=True, text=True, timeout=15)
            return json.loads(result.stdout), (time.perf_counter() - start) * 1000

        call("worker-add", worker, "Profile")
        task = Path(root) / "task"
        task.write_text("Fixture")
        call("enqueue", worker, "task", str(task))
        recipe = Path(root) / "recipe.json"
        recipe.write_text(json.dumps(dict(socketPath="/tmp/unconnected.sock", executable="/bin/true", arguments=[],
                                         environment={}, directory=root, recipients=["person:fixture"], destination="fixture")))
        call("launch-prepare", worker, str(recipe))  # Manual intents must never auto-dispatch.
        call("worker-configure", worker, "0", "1", str(recipe))  # Paused policy.

        def measure():
            timings = []
            for _ in range(5):
                cycle, elapsed = call("supervisor-tick")
                assert not cycle["started"] and not cycle["issues"]
                timings.append(elapsed)
            return {"median_ms": round(statistics.median(timings), 2), "max_ms": round(max(timings), 2)}

        before = measure()
        start = time.perf_counter()
        with sqlite3.connect(database) as connection:
            # Synthetic historical payloads are intentionally opaque: a correct active-only
            # sweep never decodes them. IDs and state/index metadata model retained history.
            connection.executemany("INSERT INTO record(kind,id,state,payload) VALUES('launch',?,'stopped','{}')",
                                   ((str(uuid.UUID(int=i + 1)),) for i in range(count)))
            plan = connection.execute("""EXPLAIN QUERY PLAN SELECT sequence,payload FROM record INDEXED BY unresolved_launch
                WHERE kind='launch' AND state IN ('prepared','dispatching','running')
                AND sequence>0 ORDER BY sequence LIMIT 8""").fetchall()
            assert any("unresolved_launch" in row[3] for row in plan), plan
        manufactured = (time.perf_counter() - start) * 1000
        after = measure()
        assert len(call("active-launches")[0]["items"]) == 1
        print(json.dumps(dict(history=count, fixture_ms=round(manufactured, 2), before=before, after=after,
                              active_index_used=True, active_rows=1), indent=2))


if __name__ == "__main__": main()
