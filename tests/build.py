"""Exercise the native Build surface in real Tern: javac and kotlinc diagnostics as cards,
counts, source links, the bounded report, layout stability, the full page and the inline block."""
import argparse
import json
import shlex
import shutil
import subprocess
import tempfile
import time
import urllib.parse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = root / '.dev/scratch/build-test'
out.mkdir(parents=True, exist_ok=True)
runtime = str(Path(args.runtime).resolve())
host = root / 'dist/elide-tern-build'
tern = shutil.which('tern')

with tempfile.TemporaryDirectory(prefix='build-') as temporary:
    state = Path(temporary)
    project = (state / 'Build λ').resolve()
    source = project / 'src/main/com/example'
    source.mkdir(parents=True)
    (project / 'elide.pkl').write_text('amends "elide:project.pkl"\n\nname = "build-example"\n\njvm {\n    main = "com.example.HelloKt"\n}\n')
    (source / 'Hello.kt').write_text('package com.example\n\nfun main() = println(greeting())\n\nfun greeting(): String = "Hello Elide!"\n')
    (source / 'Warn.kt').write_text('package com.example\n\nfun warn(x: Int): Int {\n  val unused = 3\n  return x!! + 1\n}\n')
    util = source / 'Util.java'
    util.write_text('package com.example;\n\npublic class Util {\n  public static int twice(int value) {\n    String s = value * 2;\n    return value;\n  }\n}\n')
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
            return value in tree('[data-role="build-status"]')

        def rect(selector):
            found = nodes(selector)
            return found[0]['rect'] if found else None

        def place(box):
            # Where a node sits and how tall it is; its width may follow its text.
            return box and (box[0], box[1], box[3])

        def reports():
            return sorted(project.glob('.dev/reports/build/tern/run-*/diagnostics.json'), key=lambda p: p.stat().st_mtime)

        def host_running():
            rows = subprocess.check_output(['ps', '-axo', 'command'], text=True)
            return any(str(host) in row for row in rows.splitlines())

        def run(*extra):
            ctl('run', 'cd ' + shlex.quote(str(project)) + ' && ' + shlex.join([str(host), runtime, *extra]))

        def assert_cards():
            stats = tree('[data-role="build-stats"]')
            assert 'Errors1' in stats.replace(' ', '') or 'Errors 1' in stats, stats
            assert 'Warnings1' in stats.replace(' ', '') or 'Warnings 1' in stats, stats
            files = tree('[data-role="build-file"]')
            assert 'Util.java' in files and 'Warn.kt' in files, files
            assert '1 error' in files and '1 warning' in files, files
            assert files.index('Util.java') < files.index('Warn.kt'), 'files with errors come first'
            cards = nodes('[data-role="build-diagnostic"]')
            assert len(cards) == 2, tree('[data-role="build-diagnostics"]')
            text = json.dumps([n.get('text', '') for n in cards], ensure_ascii=False)
            assert 'incompatible types: int cannot be converted to java.lang.String' in text, text
            assert 'Unnecessary non-null assertion' in text, text
            assert 'String s = value * 2;' in text, 'the javac card shows its excerpt'
            assert nodes('[data-role="build-open"]'), 'each located card has an Open button'
            # The location links into the project through elide://source, canonical and inside the root.
            links = tree('[data-role="build-location"] *')
            path = urllib.parse.quote(str(util.resolve()), safe='')
            root_q = urllib.parse.quote(str(project), safe='')
            expected = f'elide://source?path={path}&root={root_q}&line=5&col=22'
            assert expected in links, (expected, links)

        try:
            wait(socket.exists)
            # The full page.
            run('--surface=screen', '--no-cache')
            wait(lambda: status('Failed'))
            assert_cards()
            wait(lambda: reports() and 'diagnostics.json' in tree('[data-role="build-summary"]'))
            report = reports()[-1]
            data = json.loads(report.read_text())
            assert (data['version'], data['errors'], data['warnings']) == (1, 1, 1), data
            javac = next(d for d in data['diagnostics'] if d['severity'] == 'error')
            assert (javac['tool'], javac['line'], javac['col']) == ('javac', 5, 22), javac
            assert javac['path'] == str(util.resolve()), javac
            assert javac['excerpt']['first_line'] >= 1 and 'String s' in javac['excerpt']['text'], javac
            assert 'diagnostics.json' in tree('[data-role="build-summary"]')
            assert nodes('[data-role="build-rerun"]') and not nodes('[data-role="build-cancel"]')
            assert 'rebuild' in tree('[data-role="build-keys"]')
            ctl('appearance', 'light')
            ctl('shot', 'build-screen-light')
            ctl('appearance', 'dark')
            ctl('shot', 'build-screen-dark')
            ctl('appearance', 'light')
            # Rebuilding must not move the page: the activity line and the diagnostics area keep
            # their place while the build runs and after it ends.
            activity = place(rect('[data-role="build-activity"]'))
            area = rect('[data-role="build-diagnostics"]')[:2]
            seen_running = None
            for attempt in range(3):
                ctl('click', '[data-role="build-rerun"]')
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and seen_running is None:
                    if nodes('[data-role="build-progress"]') or nodes('[data-role="build-waiting"]'):
                        seen_running = (place(rect('[data-role="build-activity"]')), rect('[data-role="build-diagnostics"]')[:2],
                                        bool(nodes('[data-role="build-cancel"]')))
                        break
                    if status('Failed') and len(reports()) > 1 + attempt:
                        break
                wait(lambda: status('Failed') and len(reports()) >= 2 + attempt)
                if seen_running is not None:
                    break
            assert seen_running is not None, 'never saw the running state'
            assert seen_running[0] == activity, ('the activity line moved when the build started', seen_running[0], activity)
            assert seen_running[1] == area, ('the diagnostics moved when the build started', seen_running[1], area)
            assert seen_running[2], 'Cancel shows while the build runs'
            assert place(rect('[data-role="build-activity"]')) == activity, 'the activity line moved when the build ended'
            assert rect('[data-role="build-diagnostics"]')[:2] == area, 'the diagnostics moved when the build ended'
            assert_cards()
            ctl('key', 'q')
            wait(lambda: not nodes('.sf-dock') and not host_running())
            # Bare, the build draws inline and its block stays in scrollback after it exits.
            run('--no-cache')
            wait(lambda: status('Failed'))
            wait(lambda: not host_running())
            time.sleep(1)
            assert status('Failed'), tree()
            assert nodes('.sf-main'), 'the inline block left scrollback'
            assert not nodes('.sf-dock'), 'inline has no dock'
            assert not nodes('[data-role="build-rerun"]'), 'inline has no rebuild'
            assert_cards()
            ctl('appearance', 'light')
            ctl('shot', 'build-inline-light')
            ctl('appearance', 'dark')
            ctl('shot', 'build-inline-dark')
            ctl('appearance', 'light')
            # A clean build: the empty state, in place.
            util.write_text('package com.example;\n\npublic class Util {\n  public static int twice(int value) {\n    return value * 2;\n  }\n}\n')
            (source / 'Warn.kt').write_text('package com.example\n\nfun warn(x: Int): Int = x + 1\n')
            run('--surface=screen', '--no-cache')
            wait(lambda: status('Succeeded'))
            assert 'No problems' in tree('[data-role="build-empty"]'), tree()
            ctl('key', 'q')
            wait(lambda: not host_running())
            # A runtime that advertises --surface accepts it on a plain run outside Tern.
            usage = subprocess.run([runtime, 'build', '--help'], capture_output=True, text=True, timeout=120).stdout
            if '--surface' in usage:
                plain = subprocess.run([runtime, 'build', '--surface=screen'], cwd=project, capture_output=True, text=True, timeout=300)
                assert 'unexpected argument' not in plain.stderr and plain.returncode == 0, plain.stderr[-2000:]
                flag = 'plain run accepts --surface'
            else:
                flag = 'runtime predates --surface; plain-run check skipped'
            print(f'PASS: javac and kotlinc cards, counts, elide://source links, report, stable layout, page, inline block, empty state ({flag})')
            print('Shots:', *(str(out / 'serve' / f'{name}.png') for name in ['build-screen-light', 'build-screen-dark', 'build-inline-light', 'build-inline-dark']))
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
