"""Instrument bounded, already-copied bundles; public worlds never receive collector credentials."""
import hashlib
import fnmatch
import json
import os
from pathlib import Path
import re


def instrument_pages(directory, manifest, endpoint, token, build):
    # A source manifest may expose "*". Expand its patterns against only the original files,
    # before writing hooks, so public pages cannot fetch a private hook and steal its route.
    files = [path.relative_to(directory).as_posix() for path in directory.rglob('*') if path.is_file()]
    accessible = manifest.get('web_accessible_resources', [])
    matched_patterns = {}
    bindings = 0
    def expand(patterns):
        nonlocal bindings
        if not isinstance(patterns, list) or len(patterns) > 256 or any(not isinstance(p, str) for p in patterns):
            raise ValueError('Web-accessible resources require at most 256 path patterns per declaration.')
        matches = set()
        for pattern in patterns:
            if pattern not in matched_patterns:
                if len(matched_patterns) >= 256:
                    raise ValueError('At most 256 distinct web-accessible path patterns are supported.')
                matched_patterns[pattern] = [path for path in files if not Path(path).name.startswith('threading_')
                                            and fnmatch.fnmatchcase(path, pattern.lstrip('/'))]
            matches.update(matched_patterns[pattern])
        bindings += len(matches)
        if bindings > 8192:
            raise ValueError('Expanded web-accessible resources exceed 8192 entries; narrow the patterns.')
        return sorted(matches)
    if accessible:
        if manifest['manifest_version'] == 2:
            manifest['web_accessible_resources'] = expand(accessible)
        else:
            if len(accessible) > 256:
                raise ValueError('At most 256 web-accessible resource declarations are supported.')
            for entry in accessible:
                entry['resources'] = expand(entry.get('resources', []))
    resources = Path(__file__).parent
    bootstrap = (resources / 'diagnostics.js').read_text()
    hooks = (resources / 'runtime-hooks.js').read_text()
    bootstrap = bootstrap.replace('/*__THREADING_RUNTIME_HOOKS__*/',
        hooks + '({api, runtime, emit, text, contextID, traceMessages, relay});')
    # A routing hint visible to a page, never an authorization token. The receiver supplies
    # provenance/build identity itself and marks every message from a public world untrusted.
    channel = hashlib.sha256(('public:' + token).encode()).hexdigest()[:24]
    sandboxes = manifest.get('sandbox', {}).get('pages', [])
    if not isinstance(sandboxes, list) or len(sandboxes) > 256 or any(not isinstance(p, str) for p in sandboxes):
        raise ValueError('Declare at most 256 sandbox page paths.')
    written = set()

    def write(name, context=None, public=False, background=False):
        if name in written:
            return name
        path = directory / name
        if path.exists():
            raise ValueError('The extension uses a reserved threading_ development filename: ' + name)
        config = dict(build=build, context=context, public=public, channel=channel, background=background)
        if not public:
            config.update(endpoint=endpoint, token=token, sandboxes=sandboxes)
        path.write_text(bootstrap.replace('__THREADING_CONFIG__', json.dumps(config)))
        written.add(name)
        return name

    write('threading_diagnostics.js')
    write('threading_background.js', background=True)
    write('threading_main.js', context='main-world-untrusted', public=True)
    scripts = manifest.get('content_scripts', [])
    if not isinstance(scripts, list) or len(scripts) > 256:
        raise ValueError('Declare at most 256 content-script groups.')
    instrumented = []
    for script in scripts:
        if script.get('js'):
            if script.get('world') == 'MAIN':
                bridge = dict(script, world='ISOLATED', js=['threading_diagnostics.js'])
                bridge.pop('css', None)
                instrumented.append(bridge)
                script['js'].insert(0, 'threading_main.js')
            else:
                script['js'].insert(0, 'threading_diagnostics.js')
        instrumented.append(script)
    if scripts:
        manifest['content_scripts'] = instrumented

    roles = {}
    for path, role in [
        ((manifest.get('action') or manifest.get('browser_action') or {}).get('default_popup'), 'popup'),
        (manifest.get('options_ui', {}).get('page') or manifest.get('options_page'), 'options'),
        (manifest.get('side_panel', {}).get('default_path') or manifest.get('sidebar_action', {}).get('default_panel'), 'side-panel'),
        (manifest.get('devtools_page'), 'devtools'),
        (manifest.get('chrome_url_overrides', {}).get('newtab'), 'new-tab'),
    ]:
        # One document can serve several surfaces. Its URL cannot tell us which opened it.
        if path:
            roles[path] = None if path in roles else role
    background = manifest.get('background', {})
    # The staging walk already bounded the tree to 4,096 entries. Only a fixed set of hooks is
    # generated, shared by all HTML pages of that role; no hook is copied per HTML file.
    for html in directory.rglob('*'):
        if html.suffix.lower() not in ('.html', '.htm') or not html.is_file():
            continue
        relative = html.relative_to(directory).as_posix()
        if relative in sandboxes:
            script = write('threading_sandbox.js', context='sandbox-untrusted', public=True)
        elif relative == background.get('page'):
            script = 'threading_background.js'
        elif role := roles.get(relative):
            script = write('threading_' + role + '.js', context=role)
        else:
            script = 'threading_diagnostics.js'
        data = html.read_text()
        injection = '<script src=' + json.dumps(os.path.relpath(directory / script, html.parent)) + '></script>'
        match = re.search(r'<head\b[^>]*>', data, flags=re.I)
        position = match.end() if match else 0
        html.write_text(data[:position] + injection + data[position:])
