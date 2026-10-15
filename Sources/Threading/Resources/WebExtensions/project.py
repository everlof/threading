"""Bounded project authoring and local Source Map v3 resolution for the workbench."""
import json
from pathlib import Path
import re
import urllib.parse


def scaffold(root):
    source = root / 'web-extension'
    config = root / '.threading/web-extensions.json'
    if source.exists() or config.exists():
        raise ValueError('Starter creation refuses to replace web-extension/ or .threading/web-extensions.json.')
    if not config.parent.resolve().is_relative_to(root.resolve()):
        raise ValueError('The configuration directory must remain inside the checkout.')
    files = {
        'manifest.json': json.dumps(dict(manifest_version=3, name='My Web Extension', version='0.1.0',
            permissions=['storage'], background=dict(service_worker='background.js', scripts=['background.js']),
            action=dict(default_popup='popup.html'), options_ui=dict(page='options.html', open_in_tab=True),
            content_scripts=[dict(matches=['http://127.0.0.1/*', 'http://localhost/*'], js=['content.js'])]), indent=2),
        'background.js': """const api = globalThis.browser || chrome;
api.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type !== 'hello') return;
  console.info('Received hello', {tab: sender.tab?.id});
  reply({text: 'Extension connected'});
});
console.info('Background started');
""",
        'content.js': """const api = globalThis.browser || chrome;
api.runtime.sendMessage({type: 'hello'}).then(reply => {
  const badge = document.createElement('p');
  badge.id = 'threading-extension-ready';
  badge.textContent = reply.text;
  document.body.append(badge);
  console.info('Content script ready');
}).catch(error => console.error(error));
""",
        'popup.html': '<!doctype html><html><head><meta charset="utf-8"><title>My extension</title></head><body><h1>My extension</h1><button id="check">Check connection</button><p id="result"></p><script src="popup.js"></script></body></html>',
        'popup.js': """document.querySelector('#check').addEventListener('click', () => {
  (globalThis.browser || chrome).runtime.sendMessage({type: 'hello'}).then(reply => {
    document.querySelector('#result').textContent = reply.text;
    console.info('Popup connected');
  });
});
""",
        'options.html': '<!doctype html><html><head><meta charset="utf-8"><title>Extension options</title></head><body><h1>Extension options</h1><p>Add your settings here.</p></body></html>',
        'README.md': 'Open Web Extensions from Threading’s panel + menu. Start a target, run its tests, edit these files and choose Rebuild & Reload. Safari needs activation in Safari Settings. The originals in this folder are the distributable sources; Threading’s development copies contain local diagnostics and must not be published.\n',
    }
    source.mkdir()
    for name, contents in files.items():
        (source / name).write_text(contents)
    targets = [dict(id=browser, browser=browser, source='web-extension', build=[],
                    tests=[dict(url='fixture', selector='#threading-extension-ready', text='Extension connected'),
                           dict(page='popup', selector='#check', click=True),
                           dict(selector='#result', text='Extension connected')])
               for browser in ('chromium', 'chrome', 'firefox', 'safari')]
    config.parent.mkdir(exist_ok=True)
    config.write_text(json.dumps(dict(version=1, targets=targets), indent=2))
    return dict(project=str(config), instructions='Starter created. Select a browser and Start. Run Tests checks the content script and background message round trip.')


def vlq(segment):
    alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    values, current, shift = [], 0, 0
    for char in segment:
        digit = alphabet.index(char)
        current |= (digit & 31) << shift
        if digit & 32:
            shift += 5
            if shift > 35:
                raise ValueError('Source-map integer exceeds its bound.')
        else:
            values.append(-(current >> 1) if current & 1 else current >> 1)
            current, shift = 0, 0
    return values


def resolve_source(root, source, stack):
    root, source = root.resolve(), source.resolve()
    # Never fetch source maps from a URL named by untrusted extension output.
    for match in re.finditer(r'(?:chrome-extension|moz-extension|safari-web-extension)://[^/\s]+/([^\s():]+):(\d+):(\d+)', stack):
        relative, line, column = match.groups()
        # Development files can sit beside an original (the service-worker wrapper does).
        if relative.rsplit('/', 1)[-1].startswith('threading_'):
            continue
        path = (source / urllib.parse.unquote(relative)).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            continue
        result = dict(path=str(path), line=int(line), column=int(column), mapped=False)
        if path.stat().st_size > 2 * 1024 * 1024:
            return result
        directive = re.search(r'//# sourceMappingURL=([^\s]+)', path.read_text(errors='replace'))
        if not directive or ':' in directive[1]:
            return result
        map_path = (path.parent / urllib.parse.unquote(directive[1])).resolve()
        if not map_path.is_relative_to(root) or not map_path.is_file() or map_path.stat().st_size > 2 * 1024 * 1024:
            return result
        data = json.loads(map_path.read_bytes())
        if data.get('version') != 3 or not isinstance(data.get('sources'), list) or len(data['sources']) > 4096:
            return result
        source_index, original_line, original_column = 0, 0, 0
        selected = None
        for line_index, mapping in enumerate(data.get('mappings', '').split(';')):
            generated_column = 0
            if line_index >= int(line):
                break
            for entry in mapping.split(','):
                fields = vlq(entry)
                if not fields:
                    continue
                generated_column += fields[0]
                if len(fields) < 4:
                    continue
                source_index += fields[1]
                original_line += fields[2]
                original_column += fields[3]
                if line_index == int(line) - 1 and generated_column <= int(column) - 1:
                    selected = source_index, original_line + 1, original_column + 1
        if selected and 0 <= selected[0] < len(data['sources']):
            name = data['sources'][selected[0]]
            if ':' not in name and ':' not in data.get('sourceRoot', ''):
                original = (map_path.parent / data.get('sourceRoot', '') / name).resolve()
                if original.is_relative_to(root) and original.is_file():
                    result = dict(path=str(original), line=selected[1], column=selected[2], mapped=True)
        return result
    raise ValueError('This event has no local source frame. Inspect the stack; remote and virtual source maps are not opened automatically.')
