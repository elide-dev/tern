"""Exercise the native Run surface in real Tern: program output, the task timeline, a failing
exit status, Stop ending the child, compile errors as cards, the full page, the inline block and
the opt-in `--surface` flag."""
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
out = root / '.dev/scratch/run-test'
out.mkdir(parents=True, exist_ok=True)
runtime = str(Path(args.runtime).resolve())
host = root / 'dist/elide-tern-run'
tern = shutil.which('tern')

HELLO = 'package com.example\n\nfun main() = println("Hello Elide!")\n'

with tempfile.TemporaryDirectory(prefix='run-') as temporary:
    state = Path(temporary)
    project = (state / 'Run λ').resolve()
    source = project / 'src/main/com/example'
    source.mkdir(parents=True)
    (project / 'elide.pkl').write_text('amends "elide:project.pkl"\n\nname = "run-example"\n\njvm {\n    main = "com.example.HelloKt"\n}\n')
    hello = source / 'Hello.kt'
    hello.write_text(HELLO)
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
            return value in tree('[data-role="run-status"]')

        # The log is drawn by a terminal view, so its text is not in the tree: the head's line
        # count shows it arrived, and the run's output.log holds the text.
        def output():
            return tree('[data-role="run-output"]')

        def latest_log():
            logs = sorted(project.glob('.dev/reports/run/tern/run-*/output.log'), key=lambda path: path.stat().st_mtime)
            return logs[-1].read_text() if logs else ''

        def host_running():
            rows = subprocess.check_output(['ps', '-axo', 'command'], text=True)
            return any(str(host) in row for row in rows.splitlines())

        def child_running():
            rows = subprocess.check_output(['ps', '-axo', 'command'], text=True)
            return any('--progress=json' in row and runtime in row for row in rows.splitlines())

        def run(*extra):
            ctl('run', 'cd ' + shlex.quote(str(project)) + ' && ' + shlex.join([str(host), runtime, *extra]))

        try:
            wait(socket.exists)
            # The full page: a finished run with its output, task table and output.log.
            run('--surface=screen')
            wait(lambda: status('Finished'))
            assert '1 line' in output(), output()
            assert nodes('[data-role="build-task-table"]'), tree()
            assert nodes('[data-role="run-rerun"]') and not nodes('[data-role="run-stop"]'), tree()
            assert 'run again' in tree('[data-role="run-keys"]'), tree('[data-role="run-keys"]')
            assert 'Hello Elide!' in latest_log(), latest_log()
            ctl('appearance', 'light')
            ctl('shot', 'run-screen-light')
            ctl('appearance', 'dark')
            ctl('shot', 'run-screen-dark')
            ctl('appearance', 'light')
            # Run again: a failing exit status.
            hello.write_text('package com.example\n\nfun main() { println("boom"); kotlin.system.exitProcess(3) }\n')
            ctl('click', '[data-role="run-rerun"]')
            wait(lambda: status('Failed'))
            assert 'Exited with status 3' in tree('[data-role="run-summary"]'), tree('[data-role="run-summary"]')
            assert 'boom' in latest_log(), latest_log()
            # A long-running program: Stop ends the child.
            hello.write_text('package com.example\n\nfun main() { println("tick"); Thread.sleep(600000) }\n')
            ctl('key', 'r')
            wait(lambda: status('Running') and '1 line' in output())
            assert nodes('[data-role="run-stop"]'), tree()
            ctl('click', '[data-role="run-stop"]')
            wait(lambda: status('Stopped') and not child_running())
            assert 'tick' in latest_log(), latest_log()
            # A compile error: its card.
            hello.write_text('package com.example\n\nfun main() { val s: String = 1 }\n')
            ctl('key', 'r')
            wait(lambda: status('Failed'))
            assert nodes('[data-role="build-diagnostic"]'), tree()
            ctl('key', 'q')
            wait(lambda: not host_running())
            # Inline, the run's block stays in scrollback after it exits.
            hello.write_text(HELLO)
            run('--surface=inline')
            wait(lambda: status('Finished'))
            wait(lambda: not host_running())
            time.sleep(1)
            assert nodes('.sf-main'), 'the inline block left scrollback'
            assert not nodes('.sf-dock'), 'inline has no dock'
            assert not nodes('[data-role="run-rerun"]'), 'inline has no run again'
            ctl('appearance', 'light')
            ctl('shot', 'run-inline-light')
            # Without the flag the host refuses: the surface is opt-in for run.
            plain = subprocess.run([str(host), runtime], cwd=project, capture_output=True, text=True, timeout=60)
            assert plain.returncode != 0 and 'no --surface=MODE' in plain.stderr, (plain.returncode, plain.stderr[-2000:])
            # A runtime that advertises --surface accepts it on a plain run outside Tern.
            usage = subprocess.run([runtime, 'run', '--help'], capture_output=True, text=True, timeout=120).stdout
            if '--surface' in usage:
                plain = subprocess.run([runtime, 'run', '--surface=screen'], cwd=project, capture_output=True, text=True, timeout=300)
                assert 'unexpected argument' not in plain.stderr and plain.returncode == 0, plain.stderr[-2000:]
                assert 'Hello Elide!' in plain.stdout, plain.stdout[-2000:]
                flag = 'plain run accepts --surface'
            else:
                flag = 'runtime predates --surface; plain-run check skipped'
            print(f'PASS: output, task table, output.log, exit status, Stop, compile error cards, page, inline block, opt-in ({flag})')
            print('Shots:', *(str(out / 'serve' / f'{name}.png') for name in ['run-screen-light', 'run-screen-dark', 'run-inline-light']))
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
