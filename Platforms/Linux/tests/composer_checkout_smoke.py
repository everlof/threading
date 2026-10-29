"""An added sibling worktree is a launch destination, while project switching navigates."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib


binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'checkout-fixture'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
main = root / 'Repo'
sibling = root / 'FeatureCheckout'
missing = root / 'GoneCheckout'
plain = root / 'PlainProject'
plain.mkdir()


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True, timeout=8)


git('init', '-b', 'main', str(main))
git('-C', str(main), 'config', 'user.name', 'Fixture')
git('-C', str(main), 'config', 'user.email', 'fixture@example.invalid')
(main / 'README').write_text('checkout fixture\n')
git('-C', str(main), 'add', 'README')
git('-C', str(main), 'commit', '-m', 'Initial')
git('-C', str(main), 'worktree', 'add', '-b', 'feature', str(sibling))
git('-C', str(main), 'worktree', 'add', '-b', 'gone', str(missing))
for project in (main, sibling, missing, plain):
    subprocess.run([host, '--add-project', str(store), str(project)],
                   check=True, capture_output=True, timeout=8)
git('-C', str(main), 'worktree', 'remove', '--force', str(missing))
with sqlite3.connect(str(store / 'threading.db')) as database:
    remembered = {json.loads(data)['name']: json.loads(data).get('lastKnownRepositoryIdentity')
                  for (data,) in database.execute('SELECT data FROM project')}
assert remembered['Repo'] == remembered['FeatureCheckout'] == remembered['GoneCheckout']
assert remembered['PlainProject'] is None

agent = root / 'record-agent'
agent.write_text('''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
Path('checkout-agent.json').write_text(json.dumps({
    'cwd': os.getcwd(), 'argv': sys.argv[1:]
}))
time.sleep(10)
''')
agent.chmod(0o700)
state = root / 'daemon'
state.mkdir()
socket = Path(endpoint)
log_path = output / 'window.log'
Atspi.init()


def eventually(read, label, process, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: {log_path.read_text()}'
        value = read()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{label}: {log_path.read_text()}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def worktree_prompt(branch, process):
    def dialog():
        result = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible',
                                 '--name', '^New Worktree$'], capture_output=True,
                                text=True, timeout=5)
        return result.stdout.splitlines()[0] if result.returncode == 0 else None

    window = eventually(dialog, 'New Worktree prompt', process)
    time.sleep(.4)
    subprocess.run(['import', '-window', window,
                    str(output / f'{branch}-prompt.png')], check=True, timeout=5)
    xdo('windowfocus', '--sync', window)
    xdo('type', '--clearmodifiers', '--delay', '1', branch)
    xdo('key', 'Return')


def application(process):
    desktop = Atspi.get_desktop(0)
    return child_matching(desktop, lambda child:
                          child.get_name() == 'Threading Linux'
                          and child.get_process_id() == process.pid)


def child_matching(parent, predicate):
    # AT-SPI can retire a child between count and lookup while the window swaps panes.
    # The caller's eventually() still requires the exact requested live child.
    try:
        for index in range(parent.get_child_count()):
            child = parent.get_child_at_index(index)
            if child is not None and predicate(child):
                return child
    except GLib.GError:
        return None
    return None


def child_by_id(parent, identity):
    return child_matching(parent, lambda child: child.get_accessible_id() == identity)


def row_named(menu, name):
    return child_matching(menu, lambda row: row.get_name() == name)


def project_rows(frame, count):
    try:
        for index in range(frame.get_child_count()):
            listed = frame.get_child_at_index(index)
            if listed is None or listed.get_role_name() != 'list' or listed.get_child_count() != count:
                continue
            rows = [listed.get_child_at_index(row) for row in range(count)]
            if all(row is not None for row in rows):
                return rows
    except GLib.GError:
        return None
    return None


daemon_process = None
process = None
try:
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=log, stderr=log)
        eventually(lambda: socket.exists(), 'PTY daemon', daemon_process)
    home = root / 'home'
    home.mkdir()
    with log_path.open('w') as log:
        process = subprocess.Popen([binary, '--app-agents-project', str(store), str(socket),
                                    '/bin/sh', str(agent), str(agent), str(main)],
                                   env=dict(os.environ, HOME=str(home), THREADING_LINUX_HEAD_TRACE='1'),
                                   stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'app', process)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'window', process).splitlines()[0]
        xdo('windowfocus', '--sync', window)
        frame = eventually(lambda: app.get_child_at_index(0), 'frame', process)
        panel = eventually(lambda: child_matching(frame, lambda child:
            child.get_role_name() == 'panel'), 'composer panel', process)
        chip = eventually(lambda: child_by_id(panel, 'linux.composer.project'),
                          'location chip', process)
        editor = eventually(lambda: child_by_id(panel, 'linux.composer.editor'),
                            'editor', process)
        eventually(lambda: chip.get_name() == 'Project: Repo › main',
                   'live branch in location chip', process)
        rows = eventually(lambda: project_rows(frame, 5)
            if project_rows(frame, 5) and
            project_rows(frame, 5)[0].get_name().startswith('Repo repository') else None,
            'repository, added and missing checkouts, standalone project', process)
        assert rows[0].get_accessible_id().startswith('repository:'), rows[0].get_accessible_id()
        assert rows[1].get_name().startswith('main [' + str(main) + ']'), rows[1].get_name()
        assert rows[2].get_name().startswith('feature [' + str(sibling) + ']'), rows[2].get_name()
        assert rows[3].get_name().startswith('GoneCheckout [' + str(missing) + ']'), rows[3].get_name()
        assert rows[4].get_name().startswith('PlainProject '), rows[4].get_name()
        root_bounds = rows[0].get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window, '18', str(root_bounds.y + root_bounds.height // 2),
            'click', '1')
        eventually(lambda: project_rows(frame, 2), 'repository folded', process)
        xdo('click', '1')
        eventually(lambda: project_rows(frame, 5), 'repository reopened', process)
        xdo('mousemove', '--window', window, '95', str(root_bounds.y + root_bounds.height // 2),
            'click', '1')
        xdo('key', 'Left')
        eventually(lambda: project_rows(frame, 2), 'keyboard folded repository', process)
        xdo('key', 'Right')
        eventually(lambda: project_rows(frame, 5), 'keyboard reopened repository', process)
        editor.get_editable_text_iface().set_text_contents('Keep this draft')
        eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Keep this draft',
                   'draft', process)
        assert chip.get_action_iface().do_action(0)
        menu = eventually(lambda: child_by_id(panel, 'linux.composer.choices'),
                          'checkout menu', process)
        eventually(lambda: row_named(menu, 'main (this checkout)')
                   and row_named(menu, 'feature') and row_named(menu, 'Switch Project…'),
                   'checkout choices', process)
        assert row_named(menu, 'GoneCheckout') is None, 'missing checkout entered live routing'
        subprocess.run(['import', '-window', window, str(output / 'checkout-menu.png')],
                       check=True, timeout=5)
        assert row_named(menu, 'Switch Project…').get_action_iface().do_action(0)
        eventually(lambda: row_named(menu, '‹ Checkouts') and row_named(menu, 'PlainProject'),
                   'project navigation section', process)
        assert row_named(menu, '‹ Checkouts').get_action_iface().do_action(0)
        eventually(lambda: row_named(menu, 'feature'), 'return to checkout section', process)
        assert row_named(menu, 'feature').get_action_iface().do_action(0)
        eventually(lambda: chip.get_name() == 'Project: Repo › feature',
                   'sibling branch in location chip', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Keep this draft'
        subprocess.run(['import', '-window', window, str(output / 'sibling-selected.png')],
                       check=True, timeout=5)
        action = eventually(lambda: child_by_id(panel, 'linux.placeholder.action'),
                            'Start Session', process)
        bounds = action.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window, str(bounds.x + bounds.width // 2),
            str(bounds.y + bounds.height // 2), 'click', '1')
        marker = sibling / 'checkout-agent.json'
        report = eventually(lambda: json.loads(marker.read_text()) if marker.exists() else None,
                            'agent in sibling worktree', process)
        assert report['cwd'] == str(sibling), report
        assert report['argv'][-2:] == ['--', 'Keep this draft'], report
        assert not (main / 'checkout-agent.json').exists()
        with sqlite3.connect(str(store / 'threading.db')) as database:
            rows = database.execute('SELECT session.data FROM session JOIN project '
                                    'ON session.project_id = project.id '
                                    'WHERE project.folder_path = ?', (str(sibling),)).fetchall()
        assert len(rows) == 1 and json.loads(rows[0][0])['branch'] == 'feature', rows
        # A repository fold is a standing user choice, independent of project disclosures.
        saved_folds = log_path.read_text().count('OUTLINE_REPOSITORY_SAVED ')
        xdo('mousemove', '--window', window, '18', str(root_bounds.y + root_bounds.height // 2),
            'click', '1')
        eventually(lambda: project_rows(frame, 2), 'repository folded after launch', process)
        eventually(lambda: log_path.read_text().count('OUTLINE_REPOSITORY_SAVED ') > saved_folds,
                   'repository fold persisted', process)
        process.terminate()
        process.wait(timeout=5)
        with log_path.open('a') as log:
            process = subprocess.Popen([binary, '--app-agents-project', str(store), str(socket),
                                        '/bin/sh', str(agent), str(agent), str(main)],
                                       env=dict(os.environ, HOME=str(home), THREADING_LINUX_HEAD_TRACE='1'),
                                       stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'restarted app', process)
        frame = eventually(lambda: app.get_child_at_index(0), 'restarted frame', process)
        eventually(lambda: project_rows(frame, 2), 'repository fold restored', process)
        panel = eventually(lambda: child_matching(frame, lambda child:
            child.get_role_name() == 'panel'), 'restarted composer', process)
        chip = eventually(lambda: child_by_id(panel, 'linux.composer.project'),
                          'restarted location chip', process)
        editor = eventually(lambda: child_by_id(panel, 'linux.composer.editor'),
                            'restarted editor', process)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'restarted window', process).splitlines()[0]
        xdo('windowfocus', '--sync', window)
        editor.get_editable_text_iface().set_text_contents('Draft follows new checkout')
        assert chip.get_action_iface().do_action(0)
        choices = eventually(lambda: child_by_id(panel, 'linux.composer.choices'),
                             'restarted checkout choices', process)
        create = eventually(lambda: row_named(choices, 'New Worktree…'),
                            'composer worktree command', process)
        assert create.get_action_iface().do_action(0)
        worktree_prompt('from-composer', process)
        created = root / 'Repo-from-composer'
        eventually(lambda: created.is_dir() and
                   'PROJECT_IMPORTED ' + str(created) in log_path.read_text(),
                   'composer worktree import', process)
        eventually(lambda: chip.get_name() == 'Project: Repo-from-composer › from-composer',
                   'composer moved to created checkout', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft follows new checkout'

        rows = eventually(lambda: project_rows(frame, 7),
                          'new checkout revealed under repository', process)
        root_create = eventually(lambda: rows[0].get_child_at_index(0),
                                 'repository Create action', process)
        assert root_create.get_accessible_id().startswith('sidebar.project.create.')
        assert root_create.get_action_iface().do_action(0)
        sidebar_menu = eventually(lambda: child_matching(frame, lambda child:
            child.get_role_name() == 'list' and child.get_name() == 'New in Repository'),
            'repository creation menu', process)
        assert row_named(sidebar_menu, 'New Chat…').get_action_iface().do_action(1)
        eventually(lambda: child_matching(frame, lambda child:
            child.get_name() == 'New Chat providers'),
            'repository chat providers', process)
        xdo('key', 'Escape')
        sidebar_menu = eventually(lambda: child_matching(frame, lambda child:
            child.get_name() == 'New in Repository'),
            'repository menu restored after providers', process)
        create = eventually(lambda: row_named(sidebar_menu, 'New Worktree…'),
                            'repository worktree command', process)
        assert create.get_action_iface().do_action(1)
        worktree_prompt('from-root', process)
        root_created = root / 'Repo-from-root'
        eventually(lambda: root_created.is_dir() and
                   'PROJECT_IMPORTED ' + str(root_created) in log_path.read_text(),
                   'repository worktree import', process)
        eventually(lambda: project_rows(frame, 8), 'repository gained second checkout', process)
        with sqlite3.connect(str(store / 'threading.db')) as database:
            stored = {row[0] for row in database.execute('SELECT folder_path FROM project')}
        assert {str(created), str(root_created)} <= stored
        git('-C', str(root_created), 'switch', '-c', 'after-live-switch')
        eventually(lambda: chip.get_name() ==
                   'Project: Repo-from-root › after-live-switch',
                   'composer follows live HEAD', process)
        rows = eventually(lambda: project_rows(frame, 8)
            if project_rows(frame, 8) and any(row.get_name().startswith(
                'after-live-switch [' + str(root_created) + ']')
                for row in project_rows(frame, 8)) else None,
            'checkout row follows live HEAD', process)
        assert any(row.get_name().startswith('main [' + str(main) + ']') for row in rows)
        subprocess.run(['import', '-window', window, str(output / 'new-worktrees.png')],
                       check=True, timeout=5)
        print('PASS checkout routing, worktree creation, live HEAD, preserved draft',
              flush=True)
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if daemon_process is not None and daemon_process.poll() is None:
        daemon_process.terminate()
        try:
            daemon_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_process.kill()
            daemon_process.wait(timeout=5)
