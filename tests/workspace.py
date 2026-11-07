"""Native project workspace navigation, unsaved buffers, and terminal working directory."""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--headless', action='store_true', help='Exercise routing without opening an OS window')
args = parser.parse_args()
out = root / '.dev/scratch/workspace-test'
out.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='tw-', dir='/tmp') as temporary:
    state = Path(temporary)
    project = state / "Workspace's λ"
    nested = project / 'nested'
    nested.mkdir(parents=True)
    manifest = project / 'elide.pkl'
    manifest.write_text('amends "elide:project.pkl"\nname = "workspace-test"\n')
    for filename in ['one.js', 'two.py', 'three.txt']:
        (project / filename).write_text(f'// {filename}\n')
    def png_chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    (project / 'pixel.png').write_bytes(b'\x89PNG\r\n\x1a\n'
        + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
        + png_chunk(b'IDAT', zlib.compress(b'\0\0\0\0\xff')) + png_chunk(b'IEND', b''))
    (project / 'bytes.bin').write_bytes(bytes(range(256)))
    other = state / 'other-project'
    other.mkdir()
    (other / 'elide.pkl').write_text('amends "elide:project.pkl"\n')
    (other / 'outside.txt').write_text('Other project stays separate\n')
    package = state / 'crates/plugins/fixtures/elide'
    shutil.copytree(root / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    (package / 'config.json').write_text(json.dumps({'broker': str(root / 'dist/elide-tern-broker')}))
    fixture_root = state / 'crates/tern'
    (fixture_root / 'goldens').mkdir(parents=True)
    socket = state / 'control.sock'
    environment = {**os.environ, 'STENCIL_FIXTURE_ROOT': str(fixture_root),
                   'TERN_DAEMON_SOCKET': str(state / 'daemon.sock'), 'TERN_CONFIG_DIR': str(state / 'config')}
    with (out / 'tern.log').open('w') as log:
        subprocess.run(['tern', 'plugin', 'link', str(package)], env=environment, check=True, stdout=log, stderr=log)
        daemon = subprocess.Popen(['tern', 'daemon', '--socket', str(state / 'daemon.sock')], env=environment,
                                  stdout=log, stderr=log)
        command = ['tern', *(['serve'] if args.headless else []), '--control', str(socket),
                   '--out', str(out), '--dir', str(nested)]
        server = subprocess.Popen(command, env=environment, stdout=log, stderr=log)

        def ctl(command, *values):
            def argument(value):
                if command == 'tree' or (command == 'click' and
                                        (isinstance(value, (int, float)) or value in {'ctrl', 'meta', 'alt', 'shift'})):
                    return str(value)
                return json.dumps(str(value), ensure_ascii=False)
            result = subprocess.run(['tern', 'ctl', '--control', str(socket), command,
                                     *(argument(value) for value in values)], capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply

        def wait(predicate, seconds=30):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                result = predicate()
                if result:
                    return result
                time.sleep(.1)
            (out / 'failed-state.json').write_text(json.dumps(ctl('state'), indent=2, ensure_ascii=False))
            raise AssertionError('Workspace did not settle; see .dev/scratch/workspace-test')

        def lua(expression):
            marker = 'workspace-' + str(uuid.uuid4()) + ':'
            ctl('carly', 'lua', 'print(' + json.dumps(marker) + '..tern.json.encode(' + expression + '))')
            def completed():
                value = ctl('state').get('carly', {}).get('last_tool')
                if value and value.get('error'):
                    raise AssertionError(value)
                return value if value and marker in value.get('text', '') else None
            result = wait(completed)
            assert not result.get('error'), result
            line = next(line for line in result['text'].splitlines() if line.startswith(marker))
            value = json.loads(line[len(marker):])
            ctl('carly', 'close')
            return value

        def files_click(name, *modifiers):
            ctl('files', 'show')
            ctl('files', 'wait')
            row = wait(lambda: next((row for row in ctl('tree', '.ft-row').get('nodes', [])
                                     if row.get('text') == name), None))
            x, y, width, height = row['rect']
            ctl('click', x + width / 2, y + height / 2, *modifiers)

        def open_file(name):
            files_click(name)
            ctl('file', 'wait')
            return wait(lambda: next((block for block in ctl('state').get('file_blocks', [])
                                      if Path(block['path']).resolve() == (project / name).resolve()
                                      and block['id'] == ctl('state')['focused']['id']), None))

        def active_tab():
            return next(tab for tab in ctl('state')['tabs'] if tab['active'])

        def reload_plugin():
            if args.headless:
                ctl('plugins', 'fixtures')
            else:
                subprocess.run(['tern', 'plugin', 'reload', 'elide'], env=environment, check=True, stdout=log, stderr=log)

        try:
            wait(socket.exists)
            if args.headless:
                ctl('plugins', 'fixtures')
            ctl('status-bar', 'on')
            wait(lambda: ctl('tree', '.sl-plugin').get('nodes'))
            initial = ctl('state')['focused']['id']
            ctl('plugins', 'run', 'plugin.elide.workspace')
            wait(lambda: ctl('tree', '[data-role="project-actions"]').get('nodes'))
            for action in ['build', 'test', 'run', 'debug', 'repl', 'serve', 'files']:
                selector = '[data-role="project-' + action + '"]'
                button = ctl('tree', selector)['nodes'][0]
                assert button.get('title') and ctl('tree', selector + '[aria-label]').get('nodes'), button
                assert not button.get('text'), 'Toolbar actions should use native icons without repeated labels'
                assert ctl('tree', selector + ' svg').get('nodes'), ctl('tree', selector + ' *')
            # Controls follow the editor's file: elide.pkl has no Source view and no debug target.
            assert not ctl('tree', '[data-role="project-source"]').get('nodes'), 'Source must hide for elide.pkl'
            assert ctl('tree', '[data-role="project-debug"]')['nodes'][0].get('title') == 'Open debugger'
            toolbar = ctl('tree', '[data-role="project-actions"]')['nodes'][0]
            assert toolbar['rect'][3] <= 40, toolbar
            pane = next(node for node in ctl('tree', '.tn-pane')['nodes']
                        if node['rect'][1] <= toolbar['rect'][1]
                        and node['rect'][1] + node['rect'][3] >= toolbar['rect'][1] + toolbar['rect'][3])
            assert pane['rect'][3] <= 70, pane
            center = lambda node: node['rect'][1] + node['rect'][3] / 2
            assert abs(center(toolbar) - center(pane)) <= 1, (toolbar, pane)
            for group in ['project-name', 'project-execution', 'project-tools']:
                node = ctl('tree', '[data-role="' + group + '"]')['nodes'][0]
                assert abs(center(node) - center(toolbar)) <= 1, node
            assert ctl('tree', '[data-role="project-name"]')['nodes'][0]['text'] == project.name
            ctl('shot', 'workspace-toolbar')
            ctl('file', 'wait')
            editor = ctl('state')['focused']['id']
            snapshot = lua('{panes=cx.session:panes()}')
            tab = next(pane['tab'] for pane in snapshot['panes'] if pane['pane'] == editor)
            terminal = next(pane for pane in snapshot['panes'] if pane.get('tab') == tab and pane['kind'] == 'terminal')
            assert Path(terminal['cwd']).resolve() == project.resolve(), terminal
            assert active_tab()['panes'] == 3
            if not args.headless:
                process = json.loads(subprocess.check_output(['tern', 'process', str(terminal['pane']), '--json'],
                                                           env=environment, text=True))
                (out / 'terminal-process.json').write_text(json.dumps(process, indent=2))
                child = process['child']
                assert Path(child['cwd']).resolve() == project.resolve(), child
                assert '-c' not in child['argv'], 'Workspace terminal must start an interactive shell, not injected commands'
                if sys.platform == 'darwin':
                    cwd = subprocess.check_output(['lsof', '-a', '-p', str(child['pid']), '-d', 'cwd', '-Fn'], text=True)
                    cwd = next(line[1:] for line in cwd.splitlines() if line.startswith('n'))
                    assert Path(cwd).resolve() == project.resolve(), cwd
                elif sys.platform.startswith('linux'):
                    assert Path(f'/proc/{child["pid"]}/cwd').resolve() == project.resolve()
                print('PASS: actual terminal process starts in project root with no injected command', flush=True)
            opened = open_file('one.js')
            assert opened['id'] == editor, 'Ordinary Files click must reuse the workspace editor'
            wait(lambda: ctl('tree', '[data-role="project-source"]').get('nodes'))
            wait(lambda: ctl('tree', '[data-role="project-debug"]')['nodes'][0].get('title') == 'Debug one.js')
            assert active_tab()['panes'] == 3
            assert open_file('two.py')['id'] == editor
            image = open_file('pixel.png')
            assert image['id'] == editor and image['mode'] == 'image', image
            binary = open_file('bytes.bin')
            assert binary['id'] == editor and binary['mode'] == 'hex', binary
            before = ctl('state')['file_blocks']
            files_click('nested')
            assert ctl('state')['file_blocks'] == before, 'Directory clicks must keep native Files navigation'
            assert open_file('two.py')['id'] == editor
            before = ctl('state')['file_blocks']
            files_click('three.txt', 'ctrl')
            assert ctl('state')['file_blocks'] == before, 'Ctrl-click must keep native Files selection behavior'
            files_click('three.txt', 'meta')
            assert ctl('state')['file_blocks'] == before, 'Command-click must keep native Files selection behavior'
            ctl('file', 'open', str(project / 'three.txt'), 'beside')
            assert active_tab()['panes'] == 4, 'Explicit split must remain a native split'
            secondary = ctl('state')['focused']['id']
            assert secondary != editor
            ctl('close')
            assert open_file('one.js')['id'] == editor
            ctl('file', 'autosave', 'off')
            ctl('click', '.ed-code')
            ctl('file', 'goto', '1:1')
            ctl('type', '// unsaved edit\n')
            wait(lambda: any(block['id'] == editor and block['dirty'] for block in ctl('state')['file_blocks']))
            ctl('click', '[data-role="project-debug"]')
            wait(lambda: 'Save this file before debugging.' in json.dumps(ctl('tree', '.toast')))
            assert active_tab()['panes'] == 3, 'Debugging a dirty editor must not silently launch the saved file'
            replacement = open_file('two.py')['id']
            assert replacement != editor
            assert active_tab()['panes'] == 3
            retained = lua('cx.session:read(' + str(editor) + ')')
            assert retained['dirty'] and retained['lines'][0] == '// unsaved edit', retained
            assert not (project / 'one.js').read_text().startswith('// unsaved edit')
            workspace_source = package / 'lib/workspace.luau'
            current_source = workspace_source.read_text()
            legacy_source = current_source.replace('ui.button("", {', 'ui.button(label, {')
            assert legacy_source != current_source
            workspace_source.write_text(legacy_source)
            reload_plugin()
            wait(lambda: ctl('tree', '[data-role="project-build"]')['nodes'][0].get('text') == 'Build project')
            workspace_source.write_text(current_source)
            reload_plugin()
            wait(lambda: not ctl('tree', '[data-role="project-build"]')['nodes'][0].get('text'))
            assert ctl('state')['focused']['id'] == replacement, 'Reload must refresh toolbar without changing focus'
            assert active_tab()['panes'] == 3, 'Reload must preserve the workspace layout'
            ctl('close')
            wait(lambda: ctl('state')['focused']['id'] == editor)
            assert open_file('three.txt')['id'] != editor, 'Restored dirty editor must remain retained'
            current = ctl('state')['focused']['id']
            ctl('plugins', 'run', 'plugin.elide.workspace')
            assert ctl('state')['focused']['id'] == current
            assert active_tab()['panes'] == 3
            lua('cx.docs:open(' + json.dumps(str(other / 'elide.pkl')) + ', {how="tab"})')
            ctl('tab', len(ctl('state')['tabs']))
            ctl('file', 'wait')
            wait(lambda: any(block['id'] == ctl('state')['focused']['id']
                             and Path(block['path']).resolve() == (other / 'elide.pkl').resolve()
                             for block in ctl('state')['file_blocks']))
            ctl('plugins', 'run', 'plugin.elide.workspace')
            wait(lambda: ctl('tree', '[data-role="project-actions"]').get('nodes')
                 and Path(ctl('state')['files']['root']).resolve() == other.resolve())
            other_editor = ctl('state')['focused']['id']
            files_click('outside.txt')
            ctl('file', 'wait')
            assert ctl('state')['focused']['id'] == other_editor
            panes = lua('cx.session:panes()')
            assert any(pane['pane'] == initial for pane in panes), 'Original terminal must survive'
            assert any(pane['pane'] == current for pane in panes), 'Other project editor must survive'
            assert any(pane['pane'] == editor and pane.get('parked') for pane in panes), 'Unsaved buffer must survive'
            ctl('shot', 'workspace-navigation')
            ctl('prefs', 'preview', 'dark-nord')
            ctl('shot', 'workspace-toolbar-dark')
            assert 'exceeded its budget' not in (out / 'tern.log').read_text()
            assert 'plugin style sheet has errors' not in (out / 'tern.log').read_text()
            print('PASS: native workspace routing, modifiers, retained edits, reopening, and project isolation', flush=True)
        finally:
            for process in [server, daemon]:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
