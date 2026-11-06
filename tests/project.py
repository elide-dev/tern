"""Project detection and real Tern plugin actions; no manifest evaluation on discovery."""
import argparse
import json
import shutil
import os
import re
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from urllib.request import build_opener, ProxyHandler

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--sdk')
parser.add_argument('--runtime')
parser.add_argument('--project', help='Also run all tests in an existing project through the native project action')
args = parser.parse_args()
config_path = root / 'plugin/config.json'
config = json.loads(config_path.read_text()) if config_path.exists() else {}
def configured(name, override):
    if override:
        return str(Path(override).resolve())
    value = config.get(name)
    assert value, f'Pass --{name} or configure plugin/config.json'
    path = Path(value)
    return str((path if path.is_absolute() else root / 'plugin' / path).resolve())
sdk = configured('sdk', args.sdk)
runtime = configured('runtime', args.runtime)
out = root / '.dev/scratch/project-test' 
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='tp-', dir='/tmp') as temporary:
    state = Path(temporary)
    project = state / "A project's λ"
    nested = project / 'src'
    nested.mkdir(parents=True)
    manifest = project / 'elide.pkl'
    manifest.write_text('INVALID PKL: detection must not evaluate this')
    def discover(path):
        result = subprocess.run([str(root / 'dist/elide-tern-broker'), 'project-root', str(path)], capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    detected = discover(nested)
    assert detected['root'] == str(project.resolve())
    assert discover(manifest) == detected
    alias = state / 'alias'; alias.symlink_to(project, target_is_directory=True)
    assert discover(alias) == detected
    child = nested / 'elide.pkl'; child.write_text('also invalid')
    assert discover(child)['root'] == str(nested.resolve())
    assert discover(child)['session_key'] != detected['session_key']
    child.unlink()
    assert discover(state) is None
    manifest.unlink(); os.mkfifo(manifest)
    assert discover(project) is None
    manifest.unlink(); manifest.write_text('amends "elide:project.pkl"\nname = "project-test"\n')
    (project / 'example.test.mjs').write_text('import {test} from "node:test"; test("project context works", () => {});')
    (project / 'index.html').write_text('project server works')

    fixtures = state / 'crates/plugins/fixtures'
    fixtures.mkdir(parents=True)
    package = fixtures / 'elide'
    shutil.copytree(root / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    fixture_config = {'sdk': sdk, 'runtime': runtime}
    for name in ['broker']:
        fixture_config[name] = str(root / 'dist' / ('elide-tern-' + name))
    (package / 'config.json').write_text(json.dumps(fixture_config))
    fixture_root = state / 'crates/tern'
    (fixture_root / 'goldens').mkdir(parents=True)
    socket = state / 'control.sock'
    with (out / 'tern.log').open('w') as log:
        environment = {**os.environ, 'STENCIL_FIXTURE_ROOT': str(fixture_root),
            'TERN_PLUGIN_DATA': str(state / 'data'), 'TERN_DAEMON_SOCKET': str(state / 'daemon.sock'),
            'TERN_CONFIG_DIR': str(state / 'config')}
        subprocess.run(['tern', 'plugin', 'link', str(package)], env=environment, check=True, stdout=log, stderr=log)
        daemon = subprocess.Popen(['tern', 'daemon', '--socket', str(state / 'daemon.sock')], stdout=log, stderr=log, env=environment)
        server = subprocess.Popen(['tern', '--control', str(socket), '--out', str(out), '--dir', str(nested)],
            stdout=log, stderr=log, env=environment)
        def ctl(command, *args):
            result = subprocess.run(['tern', 'ctl', '--control', str(socket), command,
                *(str(a) if command == 'tree' else json.dumps(str(a), ensure_ascii=False) for a in args)], capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply
        def tree(selector):
            return json.dumps(ctl('tree', selector), ensure_ascii=False)
        def native_panel(program):
            pane = ctl('state')['focused']['id']
            listing = json.loads(subprocess.check_output(['tern', 'ls', '--json'], env=environment, text=True))
            blocks = [block for session in listing['sessions'] for tab in session['tabs'] for block in tab['blocks']]
            launch = next(block for block in blocks if block['id'] == pane)
            kind = program.removeprefix('elide-tern-')
            assert runtime in (launch['command'] or ''), launch
            assert f"'tern' '{kind}'" in launch['command'], launch
            assert '-c' in launch['args'] and launch['args'][-1] == launch['command'], launch
        def wait(predicate, seconds=45):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if predicate(): return
                time.sleep(.1)
            raise AssertionError(tree('.toast') + tree('.sf-main') + json.dumps(ctl('state')))
        def menu():
            ctl('plugins', 'run', 'plugin.elide.project')
            wait(lambda: 'Run tests' in tree('#pick'))
        def choose(label):
            options = ctl('tree', '#pick .tn-pk-item').get('nodes', [])
            index = next(i for i, option in enumerate(options, 1) if option.get('text') == label)
            ctl('click', f'#pick .tn-pk-item:nth-child({index})')
        try:
            wait(socket.exists)
            ctl('status-bar', 'on')
            wait(lambda: project.name in tree('.sl-plugin'))
            ctl('click', '.sl-plugin')
            wait(lambda: 'Run tests' in tree('#pick'))
            ctl('shot', 'project-actions')
            ctl('key', 'Enter')
            wait(lambda: 'Passed' in tree('[data-role="run-status"]'))
            native_panel('elide-tern-project')
            assert str(project.resolve()) in tree('[data-role="subject"]')
            assert ctl('state')['focused']['cwd'] == str(project.resolve())
            ctl('carly', 'lua', 'project_binding = await(plugins.elide.project_open(' + json.dumps(str(project.resolve()), ensure_ascii=False) + ')); return await(plugins.elide.project_read(project_binding))')
            wait(lambda: '"Passed"' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            print('PASS: built-in agent reads the same completed native test run')
            command = str(uuid.uuid4())
            ctl('carly', 'lua', 'agent_run = await(plugins.elide.test_run(project_binding, ".", ' + json.dumps(command) + ')); return "agent-started:" .. agent_run.run')
            wait(lambda: 'agent-started:' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            wait(lambda: '2 · Passed' in tree('[data-role="project-runs"]'))
            ctl('carly', 'lua', 'local repeated = await(plugins.elide.test_run(project_binding, ".", ' + json.dumps(command) + ')); assert(repeated.run == agent_run.run); return "agent-deduplicated"')
            wait(lambda: 'agent-deduplicated' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            ctl('carly', 'lua', 'await(plugins.elide.project_close(project_binding)); return "agent-detached"')
            wait(lambda: 'agent-detached' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            ctl('carly', 'lua', 'local ok = pcall(function() return await(plugins.elide.test_run(project_binding, ".", ' + json.dumps(str(uuid.uuid4())) + ')) end); assert(not ok); return "agent-revoked"')
            wait(lambda: 'agent-revoked' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            print('PASS: built-in agent launches a native-visible run, retries without duplication, and detaches')
            ctl('close')
            wait(lambda: not ctl('tree', '.sf-dock').get('nodes'))
            menu()
            choose('Open REPL')
            wait(lambda: 'Ready' in tree('.sf-badge'))
            native_panel('elide-tern-repl')
            ctl('type', '40 + 2'); ctl('key', 'Enter')
            wait(lambda: '42' in tree('.sf-json'))
            assert ctl('state')['focused']['cwd'] == str(project.resolve())
            ctl('close')
            wait(lambda: not ctl('tree', '.sf-dock').get('nodes'))
            menu()
            choose('Serve static files')
            wait(lambda: 'Running' in tree('[data-role="server-status"]') or 'http://127.0.0.1:' in tree('[data-role="address"]'))
            native_panel('elide-tern-serve')
            address = re.search(r'http://127\.0\.0\.1:\d+', tree('[data-role="address"]')).group()
            with build_opener(ProxyHandler({})).open(address, timeout=5) as response:
                assert response.read() == b'project server works'
            ctl('close')
            wait(lambda: not ctl('tree', '.sf-dock').get('nodes'))
            ctl('plugins', 'run', 'plugin.elide.test')
            wait(lambda: str(project.resolve()) in tree('#pick input'))
            ctl('key', 'Escape')
            ctl('files', 'show'); ctl('files', 'root', str(nested))
            ctl('click', '[data-id="project"]')
            wait(lambda: 'Run tests' in tree('#pick'))
            ctl('key', 'Escape')
            if args.project:
                existing = str(Path(args.project).resolve())
                ctl('files', 'root', existing)
                ctl('click', '[data-id="project"]')
                wait(lambda: 'Run tests' in tree('#pick'))
                ctl('key', 'Enter')
                wait(lambda: 'Passed' in tree('[data-role="run-status"]'), seconds=180)
                assert existing in tree('[data-role="subject"]')
                ctl('shot', 'existing-project-tests')
                print('PASS: existing project tests run through the native project action')
                ctl('close')
                wait(lambda: not ctl('tree', '.sf-dock').get('nodes'))
                ctl('files', 'root', str(nested))
            ctl('plugins', 'run', 'plugin.elide.workspace')
            wait(lambda: ctl('tree', '[data-role="project-build"]').get('nodes'))
            wait(lambda: bool(ctl('state').get('file_blocks')))
            workspace_state = ctl('state')
            assert Path(workspace_state['files']['root']).resolve() == project.resolve()
            panes = len(workspace_state['panes'])
            ctl('plugins', 'run', 'plugin.elide.workspace')
            wait(lambda: ctl('tree', '[data-role="project-build"]').get('nodes'))
            assert len(ctl('state')['panes']) == panes, 'Opening a workspace twice must preserve the layout'
            ctl('file', 'wait')
            ctl('click', '.ed-code')
            ctl('file', 'goto', '1:1')
            ctl('type', '// Edited in the native workspace editor\n')
            ctl('file', 'save')
            wait(lambda: manifest.read_text().startswith('// Edited in the native workspace editor\n'))
            ctl('shot', 'project-workspace')
            subprocess.run(['tern', 'plugin', 'reload', 'elide'], env=environment, check=True, stdout=log, stderr=log)
            before_probe = len(ctl('state')['panes'])
            ctl('click', '[data-role="project-test"]')
            ctl('click', '[data-role="project-test"]')
            wait(lambda: 'Passed' in tree('[data-role="run-status"]'))
            assert len(ctl('state')['panes']) == before_probe + 1, 'Pending runtime probe opened duplicate panes'
            native_panel('elide-tern-project')
            assert ctl('tree', '[data-role="project-build"]').get('nodes')
            assert ctl('state')['file_blocks'], 'Running tests must preserve the editor'
            count = len(ctl('state')['panes'])
            ctl('click', '[data-role="project-test"]')
            assert len(ctl('state')['panes']) == count, 'An existing result pane should be focused, not duplicated'
            ctl('shot', 'project-workspace-tests')
            ctl('tab', 'close')
            wait(lambda: not ctl('tree', '[data-role="project-actions"]').get('nodes'))
            print('PASS: native project workspace, Files, editor, adjustable splits and shared Tests action')
            manifest.unlink()
            ctl('plugins', 'run', 'plugin.elide.project')
            wait(lambda: 'No elide.pkl' in tree('.toast'))
            wait(lambda: not ctl('tree', '.sl-plugin').get('nodes'))
            assert 'exceeded its budget' not in (out / 'tern.log').read_text()
            print('PASS: inert/nested/symlink discovery, automatic status, native tests/REPL/static serving, cwd, defaults, Files action, invalidation')
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
            daemon.terminate()
            try: daemon.wait(timeout=10)
            except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
