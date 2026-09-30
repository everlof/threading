#!/usr/bin/env python3
"""Opt-in sparse-history stress check. Synthetic state only; includes CLI process startup."""
import json
import os
from pathlib import Path
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="controller-operations-profile-") as directory:
    root = Path(directory)
    database = root / "controller.db"
    worker = str(uuid.uuid4())
    def call(*args):
        value = subprocess.run([binary, "--database", str(database), *args], check=True,
                               capture_output=True, text=True, timeout=15)
        return json.loads(value.stdout)
    call("worker-add", worker, "Synthetic worker")
    def measure():
        times = []
        for _ in range(5):
            start = time.perf_counter()
            assert call("open-questions", worker)["items"] == []
            assert call("pending-deliveries")["items"] == []
            times.append((time.perf_counter() - start) * 1000)
        return {"median_ms": round(statistics.median(times), 2), "max_ms": round(max(times), 2)}
    before = measure()
    start = time.perf_counter()
    with sqlite3.connect(database) as connection:
        connection.executemany("INSERT INTO record(kind,id,parent,state,scope,payload) VALUES(?,?,?,?,?,?)",
            (("delivery" if index % 2 else "question", f"history-{index}", "synthetic", "delivered" if index % 2 else "answered", worker, "opaque-closed-history") for index in range(100000)))
        plans = [row[3] for row in connection.execute("EXPLAIN QUERY PLAN SELECT sequence,payload FROM record INDEXED BY unresolved_delivery WHERE kind='delivery' AND state IN ('pending','sending','uncertain') AND sequence>0 ORDER BY sequence LIMIT 8")]
        assert any("unresolved_delivery" in plan for plan in plans), plans
    manufacture_ms = round((time.perf_counter() - start) * 1000, 2)
    print(json.dumps({"history_rows": 100000, "manufacture_ms": manufacture_ms, "before": before, "after": measure(), "query_plan": plans}, indent=2))
