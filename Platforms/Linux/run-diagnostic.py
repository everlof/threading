#!/usr/bin/env python3
"""Run the normal launcher, retaining at most two 1 MiB output logs."""
import os
from pathlib import Path
import signal
import subprocess
import sys

LOG_BYTES = 1024 * 1024


def main():
    os.umask(0o077)
    data = Path(os.environ.get("THREADING_LINUX_DATA_DIR") or
                str(Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
                    / "threading-linux-spike"))
    if not data.is_absolute():
        raise SystemExit("The data directory must be an absolute path.")
    data.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = data / "app-diagnostic.log"
    previous = data / "app-diagnostic.log.1"
    if path.exists():
        path.replace(previous)

    def open_log():
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        return os.fdopen(descriptor, "wb", buffering=0)

    launcher = Path(__file__).resolve().with_name("run-app.sh")
    output = open_log()
    child = None
    try:
        child = subprocess.Popen([str(launcher), *sys.argv[1:]], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT)
        for number in (signal.SIGINT, signal.SIGTERM):
            signal.signal(number, lambda received, frame: child.send_signal(received))
        print(f"Diagnostic log: {path}", flush=True)
        written = 0
        while chunk := os.read(child.stdout.fileno(), 8192):
            if written + len(chunk) > LOG_BYTES:
                output.close()
                path.replace(previous)
                output = open_log()
                written = 0
            output.write(chunk)
            written += len(chunk)
        return child.wait()
    finally:
        output.close()
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
