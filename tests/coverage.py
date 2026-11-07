"""Measured coverage -> native source -> edit/save -> rerun in an isolated Tern desktop."""
import argparse
import hashlib
import json
import re
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import zlib

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
    # Line 4 is blank inside the covered `if`: inferred, it must carry the band too.
    source.write_text('''export function classify(value) {
  if (value > 0) {
    const label = "positive";

    return label;
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
    fixture_config['project'] = str(root / 'dist/elide-tern-project')
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

        def png(path):
            data = Path(path).read_bytes()
            pos, chunks = 8, []
            while pos < len(data):
                length, kind = struct.unpack('>I4s', data[pos:pos + 8])
                body = data[pos + 8:pos + 8 + length]
                if kind == b'IHDR':
                    width, height, _, color = struct.unpack('>IIBB', body[:10])
                    channels = {2: 3, 6: 4}[color]
                elif kind == b'IDAT':
                    chunks.append(body)
                pos += 12 + length
            raw = zlib.decompress(b''.join(chunks))
            stride = width * channels
            rows, prev = [], bytearray(stride)
            for y in range(height):
                kind = raw[y * (stride + 1)]
                line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
                for i in range(stride):
                    a = line[i - channels] if i >= channels else 0
                    b = prev[i]
                    c = prev[i - channels] if i >= channels else 0
                    if kind == 1:
                        line[i] = (line[i] + a) & 255
                    elif kind == 2:
                        line[i] = (line[i] + b) & 255
                    elif kind == 3:
                        line[i] = (line[i] + (a + b) // 2) & 255
                    elif kind == 4:
                        pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                        line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
                rows.append(bytes(line))
                prev = line
            return lambda x, y: tuple(rows[int(y)][int(x) * channels:int(x) * channels + 3])

        # The blank line inside the covered block is tinted across its whole row, like the
        # inferred closer below it, and unlike the function's closer, which nothing reaches.
        def blank_band(shot):
            pixel = png(out / 'live' / (shot + '.png'))
            rows = {}
            for node in ctl('tree', '[data-role="coverage-editor"] .sf-ed-gutter').get('nodes', []):
                match = re.match(r'^\s*[^\d\s]?\s*(\d+)', node.get('text') or '')
                if match:
                    rows[int(match.group(1))] = node['rect']
            editor = ctl('tree', '[data-role="coverage-editor"]')['nodes'][0]['rect']
            mid = lambda line: (rows[line][1] + rows[line][3] / 2) * 2
            start, end = (rows[4][0] + rows[4][2] + 4) * 2, (editor[0] + editor[2] - 24) * 2
            closer, clear = pixel(end, mid(6)), pixel(end, mid(8))
            near = lambda p, q, d: sum(abs(x - y) for x, y in zip(p, q)) <= d
            across = [pixel(x, mid(4)) for x in range(int(start), int(end), 6)]
            ok = not near(closer, clear, 12) and all(near(p, closer, 6) for p in across)
            return ok, {'closer': closer, 'clear': clear, 'blank': sorted(set(across))[:6]}

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
            if ctl('tree', '[data-role="coverage-lines"]').get('nodes'):
                ctl('click', '[data-role="coverage-lines"] .sf-tbl-body .sf-tbl-row:first-child')
            wait(lambda: f'line {missing}' in tree('[data-role="coverage-source"]'))
            ctl('shot', 'coverage-light')
            ok, band = blank_band('coverage-light')
            assert ok, band
            ctl('prefs', 'preview', 'dark-nord')
            ctl('shot', 'coverage-dark')
            ctl('prefs', 'close')
            ctl('click', '[data-role="coverage-source"]', 'meta')
            def file_block():
                return any(block.get('path') and Path(block['path']).resolve() == source.resolve() for block in ctl('state').get('file_blocks', []))
            # A project source link opens Tern's editor or, with the source block, plugin.elide.source.
            wait(lambda: file_block() or bool(ctl('tree', "[data-surface='plugin.elide.source']").get('nodes')))
            if not file_block():
                ctl('file', 'open', str(source))
                ctl('file', 'goto', f'{missing}:1')
            ctl('file', 'wait')
            wait(file_block)
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
            ctl('carly', 'lua', 'local detail = await(plugins.elide.coverage_read(coverage_binding, coverage_run, {file=0,limit=1})); assert(#detail.lines == 1); return "coverage-detail-ready"')
            wait(lambda: 'coverage-detail-ready' in str(ctl('state').get('carly', {}).get('last_tool', '')))
            # The broker serves closers of covered blocks as `inferred`: line 6 of classify.mjs
            # closes the covered `if`.
            ctl('carly', 'lua', 'local listing = await(plugins.elide.coverage_read(coverage_binding, coverage_run, {limit=100})); '
                'local index; for _, file in listing.files do if string.find(file.path, "classify%.mjs$") and not string.find(file.path, "%.test%.") then index = file.index end end; '
                'assert(index, "classify.mjs not measured"); '
                'local page = await(plugins.elide.coverage_read(coverage_binding, coverage_run, {file=index,limit=100})); '
                'local inferred = {}; for _, line in page.lines do if line.state == "inferred" then table.insert(inferred, line.line) end end; '
                'await(plugins.elide.project_close(coverage_binding)); return "coverage-inferred:" .. table.concat(inferred, ",")')
            def inferred_reply():
                return re.search(r'coverage-inferred:([0-9,]*)', str((ctl('state').get('carly', {}).get('last_tool') or {}).get('text', '')))
            wait(inferred_reply)
            inferred = inferred_reply()
            assert '6' in inferred.group(1).split(','), inferred.group(0)
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
