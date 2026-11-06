#!/usr/bin/env python3
"""Write a bounded, local support report. Logs require an explicit --include-logs."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile

LOG_BYTES = 64 * 1024
METADATA_BYTES = 16 * 1024
PACKAGES = (
    "threading-linux-preview", "libsdl2-2.0-0", "libpangocairo-1.0-0",
    "libatk-bridge2.0-0t64", "libdecor-0-plugin-1-cairo", "libsqlite3-0",
    "zenity", "wl-clipboard", "python3",
)


def read_file(path, limit, tail=False):
    """Never follow a log symlink, read a device, or load an entire growing file."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("not a regular file")
        if tail:
            source.seek(max(0, info.st_size - limit))
        return source.read(limit).decode("utf-8", "replace")


def sanitize(text):
    home = str(Path.home())
    if len(home) > 1:
        text = text.replace(home, "~")
    text = re.sub(r"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+", r"\1 [REDACTED]", text)
    text = re.sub(r"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)"
                  r"[\"']?\s*[:=]\s*[\"']?)[^\s\"',;}]+", r"\1[REDACTED]", text)
    text = re.sub(r"\bsk-[A-Za-z0-9_-]{12,}", "[REDACTED]", text)
    return "".join(character for character in text
                   if character in "\n\t" or ord(character) >= 32 and ord(character) != 127)


def package_versions():
    try:
        # The argument list and dpkg's one-line-per-package output have fixed cardinality.
        result = subprocess.run(
            ["dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}\n", *PACKAGES],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5,
        )
        return result.stdout[:METADATA_BYTES].splitlines()
    except (OSError, subprocess.TimeoutExpired):
        return ["Package information unavailable"]


def report_metadata(app_dir):
    report = {
        "format": "threading-linux-diagnostics-1",
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "architecture": platform.machine(),
        "kernel": platform.release(),
        "desktop": {key: sanitize(os.environ.get(key, ""))[:128] for key in
                    ("XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "DESKTOP_SESSION", "SDL_VIDEODRIVER")},
        "display_available": {key: bool(os.environ.get(key)) for key in ("DISPLAY", "WAYLAND_DISPLAY")},
        "providers_on_path": {name: shutil.which(name) is not None for name in ("codex", "claude")},
        "provider_override": {name: ("unset" if name not in os.environ else
                                     "disabled" if not os.environ[name] else "configured")
                              for name in ("THREADING_LINUX_CODEX", "THREADING_LINUX_CLAUDE")},
        "packages": package_versions(),
    }
    for key, path in (("os_release", Path("/etc/os-release").resolve()),
                      ("bundle_manifest", app_dir / "BUNDLE-MANIFEST")):
        try:
            report[key] = sanitize(read_file(path, METADATA_BYTES))
        except (OSError, ValueError) as error:
            report[key] = f"Unavailable ({type(error).__name__})"
    return report


def collect(destination, include_logs, app_dir):
    destination.mkdir(parents=True, exist_ok=True)
    report_dir = Path(tempfile.mkdtemp(prefix="threading-diagnostics-", dir=destination))
    report = report_metadata(app_dir)
    report["logs_included"] = include_logs
    report["log_status"] = {}
    if include_logs:
        data = Path(os.environ.get("THREADING_LINUX_DATA_DIR") or
                    str(Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
                        / "threading-linux-spike"))
        for name in ("daemon.log", "app-diagnostic.log.1", "app-diagnostic.log"):
            try:
                excerpt = sanitize(read_file(data / name, LOG_BYTES, tail=True))
                (report_dir / name).write_text(excerpt)
                report["log_status"][name] = "included: last 64 KiB at most"
            except (OSError, ValueError) as error:
                report["log_status"][name] = f"Unavailable ({type(error).__name__})"
    (report_dir / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    (report_dir / "READ-ME.txt").write_text(
        "This report was created locally; nothing has been uploaded.\n"
        "Included: build/OS/display metadata and installed runtime package versions.\n"
        "Logs are included only when --include-logs was requested, at most 64 KiB per file.\n"
        "Log redaction is best effort: review any project paths, chat text or credentials before sharing.\n"
        "No databases, transcripts, account files, full environment or process lists are collected.\n"
    )
    archive = report_dir.with_suffix(".tar.gz")
    with tarfile.open(archive, "w:gz") as output:
        output.add(report_dir, arcname=report_dir.name, recursive=True)
    return report_dir, archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--include-logs", action="store_true",
                        help="include bounded log excerpts; review their contents before sharing")
    parser.add_argument("--output", type=Path, default=Path.cwd(), help="destination directory")
    args = parser.parse_args()
    os.umask(0o077)
    report_dir, archive = collect(args.output, args.include_logs, Path(__file__).resolve().parent)
    print(f"Review: {report_dir}\nShare after review: {archive}\nNothing was uploaded.")


if __name__ == "__main__":
    main()
