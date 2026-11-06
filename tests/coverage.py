"""Measured coverage -> native source -> edit/save -> rerun in an isolated Tern desktop."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--runtime')
args = parser.parse_args()
config = {} if args.runtime else json.loads((root / 'plugin/config.json').read_text())
configured = Path(args.runtime or config['runtime'])
runtime = configured.resolve() if args.runtime or configured.is_absolute() else (root / 'plugin' / configured).resolve()
out = root / '.dev/scratch/coverage-test'
out.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='tc-', dir='/tmp') as temporary:
    state = Path(temporary)
    project = state / "Coverage's λ"
    project.mkdir()
    (project / 'elide.pkl').write_text('amends "elide:project.pkl"\nname = "coverage-example"\n')
    source = project / 'classify.mjs'
    source.write_text('''export function classify(value) {
  if (value > 0) {
    return "positive";
  }
  return "other";
}
''')
    test_file = project / 'classify.test.mjs'
    test_file.write_text('''import {test} from "node:test";
import assert from "node:assert/strict";
import {classify} from "./classify.mjs";
test("positive values", () => assert.equal(classify(1), "positive"));
''')
    fixtures = state / 'crates/plugins/fixtures'
    fixtures.mkdir(parents=True)
    package = fixtures / 'elide'
    shutil.copytree(root / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    fixture_config = {'runtime': str(runtime)}
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
        server = subprocess.Popen(['tern', '--control', str(socket), '--out', str(out), '--dir', str(project)],
            stdout=log, stderr=log, env=environment)

        def ctl(command, *values):
            def argument(value):
                if command == 'tree' or (command == 'click' and value in {'right', 'ctrl', 'meta', 'alt', 'shift'}):
                    return str(value)
                return json.dumps(str(value), ensure_ascii=False)
            result = subprocess.run(['tern', 'ctl', '--control', str(socket), command,
                *(argument(value) for value in values)],
                capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply

        def tree(selector='.sf-main'):
            return json.dumps(ctl('tree', selector), ensure_ascii=False)

        def wait(predicate, seconds=90):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(.1)
            (out / 'failure-state.json').write_text(json.dumps(ctl('state'), indent=2, ensure_ascii=False))
            (out / 'failure-tree.json').write_text(tree())
            raise AssertionError(tree('[data-role="coverage-view"]') + tree('[data-role="run-status"]'))

        def reports():
            return sorted(project.glob('.dev/reports/tests/tern/run-*/coverage.json'), key=lambda path: path.stat().st_mtime_ns)

        def measured(report):
            artifact = json.loads(report.read_text())
            return next(file for file in artifact['files'] if file['path'] == 'classify.mjs')

        try:
            wait(socket.exists)
            ctl('plugins', 'run', 'plugin.elide.workspace')
            wait(lambda: ctl('tree', '[data-role="project-test"]').get('nodes'))
            ctl('click', '[data-role="project-test"]')
            wait(lambda: 'Passed' in tree('[data-role="run-status"]'))
            assert not reports(), 'Ordinary tests must not implicitly collect coverage'
            ctl('click', '[data-role="test-coverage-run"]')
            wait(lambda: 'classify.mjs' in tree('[data-role="coverage-files"]'))
            wait(lambda: 'Passed' in tree('[data-role="run-status"]'))
            first = reports()[0]
            before = first.read_bytes()
            measurement = measured(first)
            assert measurement['sourceDigest']['value'] == hashlib.sha256(source.read_text().encode('utf-16-be')).hexdigest()
            assert any(not line['covered'] for line in measurement['lines']), measurement
            missing = next(line['line'] for line in measurement['lines'] if not line['covered'])
            (out / 'initial-report.json').write_bytes(before)
            (out / 'coverage-tree.json').write_text(tree('[data-role="coverage-view"]'))
            (out / 'coverage-elements.json').write_text(tree('[data-role="coverage-files"] *'))
            ctl('shot', 'coverage-initial')
            ctl('click', '[data-role="coverage-files"] .sf-tbl-body .sf-tbl-row:first-child')
            wait(lambda: 'classify.mjs' in tree('[data-role="coverage-detail"]'))
            ctl('click', '[data-role="coverage-lines"] .sf-tbl-body .sf-tbl-row:first-child')
            wait(lambda: f'line {missing}' in tree('[data-role="coverage-source"]'))
            ctl('shot', 'coverage-light')
            ctl('prefs', 'preview', 'dark-nord')
            ctl('shot', 'coverage-dark')
            ctl('prefs', 'close')
            ctl('click', '[data-role="coverage-source"]', 'meta')
            ctl('file', 'wait')
            wait(lambda: any(block.get('path') and Path(block['path']).resolve() == source.resolve() for block in ctl('state').get('file_blocks', [])))
            ctl('type', '/* reviewed */ ')
            ctl('file', 'save')
            wait(lambda: source.read_text().splitlines()[missing - 1].lstrip().startswith('/* reviewed */'))
            assert first.read_bytes() == before, 'Editing must not rewrite an earlier measured artifact'
            ctl('file', 'open', str(test_file))
            ctl('file', 'goto', '5:1')
            ctl('type', 'test("other values", () => assert.equal(classify(-1), "other"));\n')
            ctl('file', 'save')
            wait(lambda: 'other values' in test_file.read_text())
            ctl('click', '[data-role="test-rerun"]')
            wait(lambda: len(reports()) == 2)
            wait(lambda: 'Passed' in tree('[data-role="run-status"]') and '2 passed' in tree('[data-role="totals"]'))
            after = measured(reports()[-1])
            assert all(line['covered'] for line in after['lines']), after
            assert after['sourceDigest'] != measurement['sourceDigest']
            assert first.read_bytes() == before
            ctl('shot', 'coverage-rerun')
            ctl('carly', 'lua', 'coverage_binding = await(plugins.elide.project_open(' + json.dumps(str(project), ensure_ascii=False) + ')); coverage_state = await(plugins.elide.project_read(coverage_binding)); return coverage_state')
            wait(lambda: '"ready"' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            ctl('carly', 'lua', 'coverage_run = coverage_state.runs[#coverage_state.runs].run; coverage_files = await(plugins.elide.coverage_read(coverage_binding, coverage_run, {limit=1})); assert(#coverage_files.files == 1); assert(coverage_files.next == 1); return "coverage-page-ready"')
            wait(lambda: 'coverage-page-ready' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            ctl('carly', 'lua', 'local detail = await(plugins.elide.coverage_read(coverage_binding, coverage_run, {file=0,limit=1})); assert(#detail.lines == 1); await(plugins.elide.project_close(coverage_binding)); return "coverage-detail-ready"')
            wait(lambda: 'coverage-detail-ready' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            assert 'exceeded its budget' not in (out / 'tern.log').read_text()
            print('PASS: real coverage, native source/line navigation, edit/save/rerun, immutable history, shared agent pages')
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
            daemon.terminate()
            try:
                daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.kill(); daemon.wait()
