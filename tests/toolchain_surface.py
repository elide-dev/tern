"""Exercise the native Toolchains surface in real Tern: the `tool` records the runtime streams, the
page (install all, per-tool remove and install, update, the bounded report), the inline listing and
the inline install. Serves its own tool archive on 127.0.0.1; needs no network."""
import argparse
import functools
import http.server
import json
import os
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import threading
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = root / '.dev/scratch/toolchain-test'
out.mkdir(parents=True, exist_ok=True)
runtime = str(Path(args.runtime).resolve())
host = root / 'dist/elide-tern-toolchain'
tern = shutil.which('tern')

MANIFEST = ('amends "elide:project.pkl"\n\nname = "toolchains-fixture"\n\n'
            'toolchain { ["hello"] { version = "1.0.0"; platforms { ["any"] { url = "http://127.0.0.1:%d/hello-1.0.0.tar.gz" } } } }\n')


def records(stderr):
    found = []
    for line in stderr.splitlines():
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and isinstance(value.get('type'), str):
            found.append(value)
    return found


with tempfile.TemporaryDirectory(prefix='toolchain-') as temporary:
    state = Path(temporary)
    home = (state / 'home').resolve()
    home.mkdir()
    environment = {**os.environ, 'HOME': str(home)}
    # `hello-1.0.0.tar.gz`, holding the executable `hello-1.0.0/bin/hello`.
    served = (state / 'served').resolve()
    bin_dir = state / 'archive/hello-1.0.0/bin'
    bin_dir.mkdir(parents=True)
    (bin_dir / 'hello').write_text('#!/bin/sh\necho hello from managed tool\n')
    (bin_dir / 'hello').chmod(0o755)
    served.mkdir()
    archive = served / 'hello-1.0.0.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        tar.add(state / 'archive/hello-1.0.0', arcname='hello-1.0.0')
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(served))
    http_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=http_server.serve_forever, daemon=True).start()

    project = (state / 'Toolchains λ').resolve()
    project.mkdir()
    (project / 'elide.pkl').write_text(MANIFEST % http_server.server_address[1])
    socket = state / 'control.sock'
    with (out / 'tern.log').open('w') as log:
        server = subprocess.Popen([tern, 'serve', '--control', str(socket), '--out', str(out)],
                                  stdout=log, stderr=log, env=environment)

        def ctl(command, *values):
            result = subprocess.run([tern, 'ctl', '--control', str(socket), command,
                *(str(v) if command == 'tree' else json.dumps(str(v), ensure_ascii=False) for v in values)],
                capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply

        def tree(selector='.sf-main'):
            return json.dumps(ctl('tree', selector), ensure_ascii=False)

        def nodes(selector):
            return ctl('tree', selector).get('nodes') or []

        def wait(predicate, timeout=180, step=.2):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if predicate(): return
                time.sleep(step)
            raise AssertionError(tree())

        def newest(role, value):
            # The newest surface only: an inline block stays in scrollback after it exits.
            return value in json.dumps(nodes(f'[data-role="{role}"]')[-1:], ensure_ascii=False)

        def status(value):
            return newest('toolchain-status', value)

        def tool_state(value):
            return newest('toolchain-tool-state', value)

        def reports():
            return sorted(project.glob('.dev/reports/toolchain/tern/run-*/toolchain.json'), key=lambda p: p.stat().st_mtime)

        def host_running():
            rows = subprocess.check_output(['ps', '-axo', 'command'], text=True)
            return any(str(host) in row for row in rows.splitlines())

        def run(*extra):
            ctl('run', 'cd ' + shlex.quote(str(project)) + ' && HOME=' + shlex.quote(str(home)) + ' '
                + shlex.join([str(host), runtime, *extra]))
            if '--surface=screen' in extra:
                wait(lambda: nodes('.sf-dock'))

        def quit_page():
            ctl('key', 'q')
            wait(lambda: not nodes('.sf-dock') and not host_running())

        shots = []

        def shot(name):
            ctl('shot', name)
            shots.append(str(out / 'serve' / f'{name}.png'))

        try:
            wait(socket.exists)
            # The contract: what the runtime streams under --progress=json.
            contract = subprocess.run([runtime, '--progress=json', 'toolchain', 'install'], cwd=project,
                                      capture_output=True, text=True, timeout=600, env=environment)
            assert contract.returncode == 0, contract.stderr[-4000:]
            tools = [r for r in records(contract.stderr) if r['type'] == 'tool' and r.get('name') == 'hello']
            assert tools and tools[-1]['state'] == 'installed' and tools[-1].get('reused') is False, tools
            assert tools[-1].get('received') == archive.stat().st_size, tools
            removed = subprocess.run([runtime, 'toolchain', 'remove', 'hello'], cwd=project,
                                     capture_output=True, text=True, timeout=600, env=environment)
            assert removed.returncode == 0 and 'Removed hello 1.0.0' in removed.stdout, removed

            # The page: one missing tool, installed from the head button.
            run('--surface=screen')
            wait(lambda: status('1 missing'), timeout=300)
            assert nodes('[data-role="toolchain-install"]'), tree()
            ctl('click', '[data-role="toolchain-install"]')
            wait(lambda: status('Ready'), timeout=300)
            assert tool_state('Installed'), tree()
            wait(lambda: reports() and 'toolchain.json' in tree('[data-role="toolchain-summary"]'))
            data = json.loads(reports()[-1].read_text())
            assert data['version'] == 1 and data['outcome'] == 'success' and data['installed'] == 1, data
            # The tool's section names its program and links its declaration.
            wait(lambda: 'hello' in tree('[data-role="toolchain-tool-details"]') and nodes('[data-role="toolchain-tool-manifest"]'))
            assert 'hello' in tree('[data-role="toolchain-tool-programs"]'), tree('[data-role="toolchain-tool-details"]')
            ctl('appearance', 'light')
            shot('toolchain-screen-light')
            ctl('appearance', 'dark')
            shot('toolchain-screen-dark')
            ctl('appearance', 'light')

            # Remove asks first; confirmed, the tool is missing again.
            ctl('click', '[data-role="toolchain-tool-remove"]')
            wait(lambda: nodes('[data-role="toolchain-tool-remove-confirm"]'))
            ctl('click', '[data-role="toolchain-tool-remove-confirm"]')
            wait(lambda: tool_state('Missing'), timeout=120)

            # The tool's own install, then an update: a second run that downloads nothing new.
            ctl('click', '[data-role="toolchain-tool-install"]')
            wait(lambda: tool_state('Installed') and status('Ready'), timeout=300)
            before = len(reports())
            ctl('key', 'u')
            wait(lambda: len(reports()) > before and status('Up to date'), timeout=300)
            quit_page()

            # Inline listing: the block stays in scrollback with Manage, and no page buttons.
            run('list')
            wait(lambda: nodes('[data-role="toolchain-manage"]'), timeout=300)
            wait(lambda: not host_running())
            time.sleep(1)
            assert nodes('[data-role="toolchain-manage"]'), 'the inline block left scrollback'
            assert not nodes('[data-role="toolchain-update"]'), tree()
            assert not nodes('.sf-dock'), 'inline has no dock'

            # Inline install ends with its summary and exits 0.
            exit_file = state / 'install.status'
            ctl('run', 'cd ' + shlex.quote(str(project)) + ' && HOME=' + shlex.quote(str(home)) + ' '
                + shlex.join([str(host), runtime, 'install']) + '; echo $? > ' + shlex.quote(str(exit_file)))
            wait(lambda: exit_file.exists() and exit_file.read_text().strip(), timeout=300)
            assert exit_file.read_text().strip() == '0', exit_file.read_text()
            assert nodes('[data-role="toolchain-summary"]'), tree()

            print('PASS: tool records, page install/remove/update, report, inline listing, inline install')
            print('Shots:', *shots)
        finally:
            http_server.shutdown()
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
