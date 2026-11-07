"""Exercise native test results, rerun and cancellation in real Tern."""
import argparse
import json
import os
import signal
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
out = root / '.dev/scratch/testing-test'
out.mkdir(parents=True, exist_ok=True)
runtime = str(Path(args.runtime).resolve())
tern = shutil.which('tern')
with tempfile.TemporaryDirectory(prefix='tests-') as temporary:
    state = Path(temporary)
    script = state / 'example.test.mjs'
    script.write_text('''import {test} from "node:test";
import assert from "node:assert/strict";
test("accepts a valid request", () => { assert.equal(2 + 2, 4); });
test("rejects an invalid token", () => { console.log("Checking token policy"); assert.equal(401, 200, "Expected an authorized response"); });
test("refreshes expired sessions", {skip: true}, () => {});
''')
    socket = state / 'control.sock'
    with (out / 'tern.log').open('w') as log:
        server = subprocess.Popen([tern, 'serve', '--control', str(socket), '--out', str(out)], stdout=log, stderr=log)
        def ctl(command, *values):
            result = subprocess.run([tern, 'ctl', '--control', str(socket), command,
                *(str(v) if command == 'tree' else json.dumps(str(v)) for v in values)], capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply
        def tree(selector='.sf-main'):
            return json.dumps(ctl('tree', selector))
        def wait(predicate, timeout=90):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if predicate(): return
                time.sleep(.2)
            raise AssertionError(tree())
        def child():
            rows = subprocess.check_output(['ps', '-axo', 'pid,ppid,command'], text=True)
            for row in rows.splitlines()[1:]:
                parts = row.strip().split(None, 2)
                if len(parts) == 3 and '--reporter=tap' in parts[2] and str(script) in parts[2]:
                    return int(parts[0]), int(parts[1])
            return None
        def gone(pid):
            try: os.kill(pid, 0); return False
            except ProcessLookupError: return True
        def status(value):
            return value in tree('[data-role="run-status"]')
        try:
            wait(socket.exists)
            ctl('run', shlex.join([str(root / 'dist/elide-tern-test'), runtime, str(script)]))
            wait(lambda: status('Failed') or status('Incomplete'))
            assert status('Failed'), tree()
            assert '1 passed' in tree('[data-role="totals"]')
            assert '1 failed' in tree('[data-role="totals"]')
            assert '1 skipped' in tree('[data-role="totals"]')
            assert 'Expected an authorized response' in tree('[data-role="test-diagnostics"]')
            assert 'Checking token policy' in tree('[data-role="test-stdout"]')
            ctl('appearance', 'dark')
            ctl('shot', 'tests-dark')
            ctl('appearance', 'light')
            ctl('shot', 'tests-light')
            assert 'ms' in tree('[data-role="test-duration"]')
            assert 'example.test.mjs' in tree('[data-role="test-source"]')
            ctl('click', '[data-role="test-failures"], [data-role="test-views"] [data-tab="failures"]')
            wait(lambda: 'accepts a valid request' not in tree('[data-role="test-list"]'))
            ctl('click', '[data-role="test-output"], [data-role="test-views"] [data-tab="output"]')
            wait(lambda: bool(ctl('tree', '[data-role="run-output"]').get('nodes')))
            ctl('click', '[data-role="test-output"], [data-role="test-views"] [data-tab="output"]')
            reports = list(state.glob('.dev/reports/tests/tern/*/results.tap'))
            assert len(reports) == 1
            report = reports[0].read_text()
            assert '# elide-test:' in report and '1..3' in report, report
            (out / 'results.tap').write_text(report)
            script.write_text('import {test} from "node:test"; test("accepts a valid request", () => {});')
            ctl('click', '[data-role="test-rerun"]')
            wait(lambda: status('Passed'))
            assert '1 passed' in tree('[data-role="totals"]')
            script.write_text('import {test} from "node:test"; test("waiting for a service", async () => { await new Promise(resolve => setTimeout(resolve, 60000)); });')
            # Starting a run must not move the page: the results table stays where it was.
            header = '[data-role="test-list"] .sf-tbl-row.head'
            def header_rect():
                nodes = ctl('tree', header).get('nodes') or []
                return nodes[0].get('rect') if nodes else None
            ctl('click', '[data-role="test-views"] [data-tab="results"]')
            wait(lambda: header_rect() is not None)
            before = header_rect()
            ctl('click', '[data-role="test-rerun"]')
            wait(lambda: 'waiting for a service' in tree('[data-role="test-running"]'))
            after = header_rect()
            assert before is not None and before == after, (before, after)
            running_pid, _ = child()
            ctl('click', '[data-role="test-cancel"]')
            wait(lambda: status('Cancelled'))
            wait(lambda: gone(running_pid))
            ctl('key', 'ctrl+c')
            # The dock leaves when the surface closes; the process exits a moment later.
            wait(lambda: not ctl('tree', '.sf-dock').get('nodes') and not ctl('state')['focused']['busy'])
            ctl('run', shlex.join([runtime, 'test', str(script)]))
            wait(lambda: 'waiting for a service' in tree('[data-role="test-running"]'))
            running_pid, host_pid = child()
            os.kill(host_pid, signal.SIGKILL)
            wait(lambda: gone(running_pid))
            print('PASS: live results, failure/output/source/duration, filters, raw TAP, rerun, cancellation, teardown, host death')
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
