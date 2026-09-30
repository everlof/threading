#!/usr/bin/env python3
"""Opt-in queue-history fixture. Fixture manufacture is separate from real CLI timings."""
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
    if not 100 <= count <= 1_000_000:
        raise SystemExit("record count must be 100..1000000")
    with tempfile.TemporaryDirectory(prefix="threading-controller-profile-") as root:
        database = str(Path(root) / "controller.db")
        worker = str(uuid.uuid4())

        def call(*args):
            start = time.perf_counter()
            result = subprocess.run([binary, "--database", database, *args],
                                    check=True, capture_output=True, text=True, timeout=10)
            return json.loads(result.stdout), (time.perf_counter() - start) * 1000

        call("worker-add", worker, "Stress fixture")
        def rows():
            for index in range(count):
                identity = str(uuid.UUID(int=index + 1))
                state = "queued" if index >= count - 15 else "completed"
                item = dict(id=identity, workerID=worker, key=str(index), instruction="Fixture",
                            state=state, checkpoint="")
                yield (identity, worker, str(index), state, json.dumps(item))

        manufactured = time.perf_counter()
        with sqlite3.connect(database) as connection:
            connection.executemany("INSERT INTO record(kind,id,parent,key,state,payload) VALUES('work',?,?,?,?,?)", rows())
            # Ten answered items are eligible semantically, but their former processes remain
            # unresolved. Exercise the real claim anti-join, not a simpler historical query.
            for index in range(count - 15, count - 5):
                connection.execute("INSERT INTO record(kind,id,parent,state,payload) VALUES('launch',?,?,'running','{}')",
                                   (str(uuid.uuid4()), str(uuid.UUID(int=index + 1))))
            plan = connection.execute("""EXPLAIN QUERY PLAN
                SELECT payload FROM record AS work WHERE kind='work' AND parent=? AND state='queued'
                AND NOT EXISTS (SELECT 1 FROM record AS launch WHERE launch.kind='launch'
                    AND launch.parent=work.id AND launch.state IN ('prepared','dispatching','running'))
                ORDER BY sequence LIMIT 1""", (worker,)).fetchall()
            assert sum("record_ready" in row[3] for row in plan) == 2, plan
        manufacture_ms = (time.perf_counter() - manufactured) * 1000

        claims, pages = [], []
        for _ in range(5):
            claim, elapsed = call("claim", worker)
            assert claim["work"]["state"] == "running"
            assert int(claim["work"]["key"]) >= count - 5
            claims.append(elapsed)
            page, elapsed = call("works", worker)
            assert len(page["items"]) == 50
            pages.append(elapsed)
        assert call("claim", worker)[0] is None
        print(json.dumps({
            "records": count, "fixture_ms": round(manufacture_ms, 2),
            "claim_process_ms": {"median": round(statistics.median(claims), 2), "max": round(max(claims), 2)},
            "page_process_ms": {"median": round(statistics.median(pages), 2), "max": round(max(pages), 2)},
            "ready_index_used": True, "page_rows": 50,
            "blocked_launches_skipped": 10,
        }, indent=2))


if __name__ == "__main__":
    main()
