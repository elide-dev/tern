"""Exercise the native Install surface in real Tern: the dependency records the runtime streams,
the ecosystem table, downloads and dependency tree, the bounded report, an up-to-date install,
the full page and the inline block, a failed resolution, and npm beside Maven. Needs network
access to Maven Central (and the npm registry for the npm part)."""
import argparse
import json
import shlex
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = root / '.dev/scratch/install-test'
out.mkdir(parents=True, exist_ok=True)
runtime = str(Path(args.runtime).resolve())
host = root / 'dist/elide-tern-install'
tern = shutil.which('tern')

MANIFEST = 'amends "elide:project.pkl"\n\nname = "install-example"\n\ndependencies {\n  maven {\n    packages {\n      "%s"\n    }\n  }\n}\n'
GUAVA = 'com.google.guava:guava:33.4.0-jre'
PACKAGE_JSON = '{"dependencies":{"is-number":"7.0.0"}}\n'


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


with tempfile.TemporaryDirectory(prefix='install-') as temporary:
    state = Path(temporary)
    project = (state / 'Install λ').resolve()
    project.mkdir()
    manifest = project / 'elide.pkl'
    manifest.write_text(MANIFEST % GUAVA)
    socket = state / 'control.sock'
    with (out / 'tern.log').open('w') as log:
        server = subprocess.Popen([tern, 'serve', '--control', str(socket), '--out', str(out)], stdout=log, stderr=log)

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

        def status(value):
            # The newest surface only: an inline block's badge stays in scrollback after it exits.
            return value in json.dumps(nodes('[data-role="install-status"]')[-1:], ensure_ascii=False)

        def reports():
            return sorted(project.glob('.dev/reports/install/tern/run-*/install.json'), key=lambda p: p.stat().st_mtime)

        def host_running():
            rows = subprocess.check_output(['ps', '-axo', 'command'], text=True)
            return any(str(host) in row for row in rows.splitlines())

        def run(*extra):
            ctl('run', 'cd ' + shlex.quote(str(project)) + ' && ' + shlex.join([str(host), runtime, *extra]))
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
            contract = subprocess.run([runtime, '--progress=json', 'install', '--fresh'], cwd=project,
                                      capture_output=True, text=True, timeout=600)
            assert contract.returncode == 0, contract.stderr[-4000:]
            stream = records(contract.stderr)
            totals = [r for r in stream if r['type'] == 'dependencies' and r.get('ecosystem') == 'maven']
            assert totals, contract.stderr[-4000:]
            total = totals[-1]
            assert total['resolved'] >= 2 and total['direct'] >= 1 and total['upToDate'] is False, total
            guava = next((r for r in stream if r['type'] == 'dependency' and r.get('id') == 'com.google.guava:guava'), None)
            assert guava and guava['direct'] is True, guava
            assert 'com.google.guava:failureaccess' in guava.get('requires', []), guava
            assert any(r['type'] == 'step-started' and str(r.get('step', '')).startswith('com.google.guava:guava:') for r in stream), \
                [r for r in stream if r['type'] == 'step-started']

            # The full page, downloading.
            run('--surface=screen', '--fresh')
            wait(lambda: status('Installed'), timeout=300)
            assert 'Maven' in tree('[data-role="install-ecosystems"]'), tree()
            assert 'guava-33.4.0-jre.jar' in tree('[data-role="install-transfer-table"]'), tree()
            assert 'com.google.guava:guava' in tree('[data-role="install-tree"]'), tree()
            assert nodes('[data-role="install-rerun"]') and not nodes('[data-role="install-cancel"]'), tree()
            assert 'reinstall' in tree('[data-role="install-keys"]'), tree('.sf-dock')
            wait(lambda: reports() and 'install.json' in tree('[data-role="install-summary"]'))
            data = json.loads(reports()[-1].read_text())
            assert data['version'] == 1 and data['outcome'] == 'success', data
            assert data['packages'] >= 2 and data['downloads'] >= 1, data
            ctl('appearance', 'light')
            shot('install-screen-light')
            ctl('appearance', 'dark')
            shot('install-screen-dark')
            ctl('appearance', 'light')
            quit_page()

            # The full page, up to date: nothing downloads, and the tree still shows what is installed.
            run('--surface=screen')
            wait(lambda: status('Up to date'), timeout=300)
            assert 'com.google.guava:guava' in tree('[data-role="install-tree"]'), tree()
            assert not nodes('[data-role="install-transfers"]'), tree()
            assert 'Reused' in tree('[data-role="install-stats"]'), tree()
            wait(lambda: len(reports()) >= 2)
            data = json.loads(reports()[-1].read_text())
            assert data['outcome'] == 'up-to-date', data
            shot('install-current-light')
            # A tree item's toggle reaches the page: guava closed stays closed when the search
            # below replaces the tree and then gives it back, which only the page can know.
            twisty = '[data-role="install-tree"] .sf-tree-row:not(.leaf) .sf-tree-tw'
            ctl('click', twisty)
            wait(lambda: 'com.google.guava:failureaccess' not in tree('[data-role="install-tree"]'))
            # Find a package: the match shows under the package that requires it; q is a letter
            # while the field has the keyboard, and Escape gives the keyboard back.
            search = '[data-role="install-search"]'
            ctl('click', search)
            wait(lambda: nodes(search + '.focused'))
            ctl('type', 'failureq')
            wait(lambda: 'failureq' in tree(search) and '0 matches' in tree('[data-role="install-graph"]'))
            assert status('Up to date'), tree()
            ctl('key', 'Backspace')
            wait(lambda: '1 match' in tree('[data-role="install-graph"]'))
            found = tree('[data-role="install-tree"]')
            assert 'com.google.guava:guava' in found and 'com.google.guava:failureaccess' in found, found
            assert 'junit' not in found, found
            for _ in 'failure':
                ctl('key', 'Backspace')
            wait(lambda: 'match' not in tree('[data-role="install-graph"]'))
            assert 'com.google.guava:guava' in tree('[data-role="install-tree"] .sf-tree-node.shut'), tree('[data-role="install-tree"]')
            assert 'com.google.guava:failureaccess' not in tree('[data-role="install-tree"]'), tree('[data-role="install-tree"]')
            ctl('key', 'Escape')
            wait(lambda: not nodes(search + '.focused'))
            ctl('click', twisty)
            wait(lambda: 'com.google.guava:failureaccess' in tree('[data-role="install-tree"]'))
            quit_page()

            # Bare, the install draws inline and its block stays in scrollback after it exits.
            run()
            wait(lambda: status('Up to date'), timeout=300)
            wait(lambda: not host_running())
            time.sleep(1)
            assert status('Up to date'), tree()
            assert nodes('.sf-main'), 'the inline block left scrollback'
            assert not nodes('.sf-dock'), 'inline has no dock'
            assert not nodes('[data-role="install-rerun"]'), 'inline has no reinstall'
            ctl('appearance', 'light')
            shot('install-inline-light')
            ctl('appearance', 'dark')
            shot('install-inline-dark')
            ctl('appearance', 'light')

            # Ctrl-C stops an inline install; its block stays in scrollback drawn as cancelled, with
            # no Cancel left to press.
            run('--fresh')
            wait(lambda: status('Starting') or status('Installing'), timeout=60)
            ctl('key', 'Control+c')
            wait(lambda: not host_running(), timeout=60)
            time.sleep(1)
            assert status('Cancelled'), tree()
            assert not nodes('[data-role="install-cancel"]'), tree()

            # A package that does not exist fails the install with a problem naming it.
            manifest.write_text(MANIFEST % 'com.example.missing:nope:0.0.1')
            run('--surface=screen')
            wait(lambda: status('Failed'), timeout=300)
            problems = ' '.join(json.dumps(node, ensure_ascii=False) for node in nodes('[data-role="install-problem"]'))
            assert 'nope' in problems, tree()
            wait(lambda: reports() and json.loads(reports()[-1].read_text())['outcome'] == 'failure')
            quit_page()
            manifest.write_text(MANIFEST % GUAVA)

            # A plain install outside Tern accepts --surface.
            plain = subprocess.run([runtime, 'install', '--surface=screen'], cwd=project, capture_output=True, text=True, timeout=600)
            assert 'unexpected argument' not in plain.stderr and plain.returncode == 0, plain.stderr[-2000:]

            # npm beside Maven, when this runtime carries the npm resolver.
            scratch = state / 'npm-only'
            scratch.mkdir()
            (scratch / 'package.json').write_text(PACKAGE_JSON)
            probe = subprocess.run([runtime, 'install', '--ecosystems=npm'], cwd=scratch, capture_output=True, text=True, timeout=600)
            if probe.returncode != 0:
                npm = 'npm skipped: this runtime could not install npm packages'
                print('NOTE:', npm, probe.stderr[-500:])
            else:
                streamed = subprocess.run([runtime, '--progress=json', 'install', '--ecosystems=npm', '--fresh'], cwd=scratch,
                                          capture_output=True, text=True, timeout=600)
                assert streamed.returncode == 0, streamed.stderr[-4000:]
                stream = records(streamed.stderr)
                assert any(r['type'] == 'task-started' and r.get('task') == 'npm-install' for r in stream), streamed.stderr[-4000:]
                assert any(r['type'] == 'task-finished' and r.get('task') == 'npm-install' and r.get('outcome') == 'success'
                           for r in stream), streamed.stderr[-4000:]
                assert any(r['type'] == 'dependencies' and r.get('ecosystem') == 'npm' and r.get('phase') == 'done'
                           for r in stream), streamed.stderr[-4000:]
                (project / 'package.json').write_text(PACKAGE_JSON)
                before = reports()[-1:]
                run('--surface=screen', '--ecosystems=maven,npm')
                wait(lambda: status('Installed') or status('Up to date'), timeout=300)
                wait(lambda: reports()[-1:] != before)
                lanes = tree('[data-role="install-ecosystems"]')
                assert 'Maven' in lanes and 'npm' in lanes, lanes
                shot('install-npm-light')
                quit_page()
                npm = 'npm records and lane'
            print(f'PASS: dependency records, ecosystem table, downloads, dependency tree, search, report, up to date, page, inline block, failure, plain --surface ({npm})')
            print('Shots:', *shots)
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
