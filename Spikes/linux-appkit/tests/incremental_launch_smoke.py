"""Real Linux launches must not rewrite retained projects or conversations."""
import json
from pathlib import Path
import sqlite3
import subprocess
import sys

host, store, socket, folder = sys.argv[1:]
root = Path(folder).parent
database_path = Path(store) / 'threading.db'
other = root / 'IncrementalOther'
fresh = root / 'IncrementalFresh'
fresh_codex = root / 'IncrementalCodexFresh'
other.mkdir()
fresh.mkdir()
fresh_codex.mkdir()
subprocess.run([host, '--add-project', store, str(other)], check=True,
               capture_output=True, timeout=10)


def rows(query, parameters=()):
    with sqlite3.connect(database_path) as connection:
        return connection.execute(query, parameters).fetchall()


first_session = rows('SELECT id, data FROM session ORDER BY rowid LIMIT 1')[0]
session_payload = json.loads(first_session[1])
session_payload['futureSessionField'] = 'retain this conversation'
session_bytes = json.dumps(session_payload, sort_keys=True, separators=(',', ':'))
other_payload = json.loads(rows('SELECT data FROM project WHERE folder_path = ?', (str(other),))[0][0])
other_payload['futureProjectField'] = 'retain this project'
other_bytes = json.dumps(other_payload, sort_keys=True, separators=(',', ':'))
with sqlite3.connect(database_path) as connection:
    connection.execute('UPDATE session SET data = ? WHERE id = ?', (session_bytes, first_session[0]))
    connection.execute('UPDATE project SET data = ? WHERE folder_path = ?', (other_bytes, str(other)))
before_session_ids = {row[0] for row in rows('SELECT id FROM session')}


def preserve_standing_rows():
    assert rows('SELECT data FROM session WHERE id = ?', (first_session[0],))[0][0] == session_bytes
    assert rows('SELECT data FROM project WHERE folder_path = ?', (str(other),))[0][0] == other_bytes


recorder = Path(folder) / 'incremental-codex-recorder'
recorder.write_text('#!/bin/sh\nexit 0\n')
recorder.chmod(0o700)
result = subprocess.run([host, store, socket, 'codex', folder, '/bin/sh', str(recorder), 'test'],
                        input=b'', capture_output=True, timeout=20)
assert result.returncode == 0, (result.returncode, result.stderr)
preserve_standing_rows()
after_session_ids = {row[0] for row in rows('SELECT id FROM session')}
created = after_session_ids - before_session_ids
assert len(created) == 1
assert rows("SELECT value FROM app_state WHERE key = 'selectedSessionID'")[0][0] == created.pop()

for directory in (folder, str(fresh)):
    result = subprocess.run([host, store, socket, 'run', directory, '/bin/true'],
                            input=b'', capture_output=True, timeout=20)
    assert result.returncode == 0, (result.returncode, result.stderr)
    preserve_standing_rows()

fresh_payload = json.loads(rows('SELECT data FROM project WHERE folder_path = ?', (str(fresh),))[0][0])
assert len(fresh_payload['terminals']) == 1, 'new project and terminal were not saved together'
result = subprocess.run([host, store, socket, 'codex', str(fresh_codex), '/bin/sh', str(recorder), 'test'],
                        input=b'', capture_output=True, timeout=20)
assert result.returncode == 0, (result.returncode, result.stderr)
preserve_standing_rows()
new_rows = rows('SELECT project.id, session.id FROM project JOIN session ON session.project_id = project.id '
                'WHERE project.folder_path = ?', (str(fresh_codex),))
assert len(new_rows) == 1, 'new project and first agent were not saved together'
assert rows("SELECT value FROM app_state WHERE key = 'selectedSessionID'")[0][0] == new_rows[0][1]
print('PASS real Codex and terminal launches change only their rows; standing payloads survive', flush=True)
