"""Run the actual build generator against disposable Git metadata, with a process deadline."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

generator, terminfo = map(os.path.abspath, sys.argv[1:])
environment = {key: value for key, value in os.environ.items() if not key.startswith("SWIFTTERM_BUILD_")}
with tempfile.TemporaryDirectory(prefix="swiftterm-build-info-") as path:
    root = Path(path)
    source = root / "source"
    source.mkdir()
    shutil.copy(terminfo, source / "swifterm-terminfo")
    def generate():
        subprocess.run([generator, str(source), str(root / "info.swift"), str(root / "terminfo.swift")],
                       env=environment, check=True, timeout=8)
        assert "xtgettcapReplies" in (root / "terminfo.swift").read_text()
        return (root / "info.swift").read_text()
    # A copied worktree can name Git metadata outside the container. Git exits 128; the
    # generator must complete with unavailable metadata instead of hanging after that exit.
    (source / ".git").write_text("gitdir: /missing-build-info-fixture/.git\n")
    text = generate()
    assert "branch: String? = nil" in text and "hasUncommittedChanges: Bool? = nil" in text
    (source / ".git").unlink()
    def git(*args):
        return subprocess.check_output(["git", "-C", str(source), "-c", "commit.gpgsign=false",
                                       "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", *args],
                                      stderr=subprocess.PIPE, timeout=8).decode().strip()
    git("init", "-b", "fixture")
    git("add", "swifterm-terminfo")
    git("commit", "-m", "fixture")
    git("tag", "fixture-tag")
    commit = git("rev-parse", "HEAD")
    text = generate()
    assert 'branch: String? = "fixture"' in text and 'tag: String? = "fixture-tag"' in text
    assert f'commit: String? = "{commit}"' in text and "hasUncommittedChanges: Bool? = false" in text
    (source / "dirty.txt").write_text("fixture\n")
    assert "hasUncommittedChanges: Bool? = true" in generate()
print("PASS build-info generator: unavailable worktree, clean/tagged Git and dirty Git all terminate")
