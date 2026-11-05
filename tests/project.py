"""Project detection and real Tern plugin actions; no manifest evaluation on discovery."""
import argparse
import json
import shutil
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.request import build_opener, ProxyHandler

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--sdk')
parser.add_argument('--runtime')
args = parser.parse_args()
config_path = root / 'plugin/config.json'
config = json.loads(config_path.read_text()) if config_path.exists() else {}
def configured(name, override):
    value = override or config.get(name)
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
    for name in ['broker', 'repl', 'serve', 'test', 'project']:
        fixture_config[name] = str(root / 'dist' / ('elide-tern-' + name))
    (package / 'config.json').write_text(json.dumps(fixture_config))
    fixture_root = state / 'crates/tern'
    (fixture_root / 'goldens').mkdir(parents=True)
    socket = state / 'control.sock'
    with (out / 'tern.log').open('w') as log:
        server = subprocess.Popen(['tern', 'serve', '--control', str(socket), '--out', str(out), '--dir', str(nested)],
            stdout=log, stderr=log, env={**os.environ, 'STENCIL_FIXTURE_ROOT': str(fixture_root), 'TERN_PLUGIN_DATA': str(state / 'data')})
        def ctl(command, *args):
            result = subprocess.run(['tern', 'ctl', '--control', str(socket), command,
                *(str(a) if command == 'tree' else json.dumps(str(a), ensure_ascii=False) for a in args)], capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply
        def tree(selector):
            return json.dumps(ctl('tree', selector), ensure_ascii=False)
        def wait(predicate):
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if predicate(): return
                time.sleep(.1)
            raise AssertionError(tree('.toast') + tree('.sf-main') + json.dumps(ctl('state')))
        def menu():
            ctl('plugins', 'run', 'plugin.elide.project')
            wait(lambda: 'Run tests' in tree('#pick'))
        try:
            wait(socket.exists)
            ctl('plugins', 'fixtures')
            ctl('status-bar', 'on')
            wait(lambda: project.name in tree('.sl-plugin'))
            ctl('click', '.sl-plugin')
            wait(lambda: 'Run tests' in tree('#pick'))
            ctl('shot', 'project-actions')
            ctl('key', 'Enter')
            wait(lambda: 'Passed' in tree('[data-role="run-status"]'))
            assert str(project.resolve()) in tree('[data-role="subject"]')
            assert ctl('state')['focused']['cwd'] == str(project.resolve())
            ctl('key', 'ctrl+c')
            wait(lambda: not ctl('tree', '.sf-dock').get('nodes'))
            menu()
            ctl('key', 'ArrowDown'); ctl('key', 'Enter')
            wait(lambda: 'Ready' in tree('.sf-badge'))
            ctl('type', '40 + 2'); ctl('key', 'Enter')
            wait(lambda: '42' in tree('.sf-json'))
            assert ctl('state')['focused']['cwd'] == str(project.resolve())
            ctl('key', 'ctrl+d')
            wait(lambda: not ctl('tree', '.sf-dock').get('nodes'))
            menu()
            ctl('key', 'ArrowDown'); ctl('key', 'ArrowDown'); ctl('key', 'Enter')
            wait(lambda: 'Running' in tree('[data-role="server-status"]') or 'http://127.0.0.1:' in tree('[data-role="address"]'))
            address = re.search(r'http://127\.0\.0\.1:\d+', tree('[data-role="address"]')).group()
            with build_opener(ProxyHandler({})).open(address, timeout=5) as response:
                assert response.read() == b'project server works'
            ctl('key', 'ctrl+c')
            wait(lambda: not ctl('tree', '.sf-dock').get('nodes'))
            ctl('plugins', 'run', 'plugin.elide.test')
            wait(lambda: str(project.resolve()) in tree('#pick input'))
            ctl('key', 'Escape')
            ctl('files', 'show'); ctl('files', 'root', str(nested))
            ctl('click', '[data-id="project"]')
            wait(lambda: 'Run tests' in tree('#pick'))
            ctl('key', 'Escape')
            manifest.unlink()
            ctl('plugins', 'run', 'plugin.elide.project')
            wait(lambda: 'No elide.pkl' in tree('.toast'))
            wait(lambda: not ctl('tree', '.sl-plugin').get('nodes'))
            print('PASS: inert/nested/symlink discovery, automatic status, native tests/REPL/static serving, cwd, defaults, Files action, invalidation')
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
