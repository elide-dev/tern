"""The Elide source block in an isolated desktop window: elide://source opens it, a coverage run from the
block marks covered and uncovered lines, and the Debug overlay sets a breakpoint with `b`, launches and
shows the stop marker. Usage: python3 tests/source.py --runtime /path/to/elide [--sdk /path/to/embedder]"""
import argparse, json, os, re, shutil, struct, subprocess, sys, tempfile, time, uuid, zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True, help='Elide runtime with `elide tern` project hosting')
parser.add_argument('--sdk', help='Extracted embedder SDK directory (written to the fixture config when given)')
arguments = parser.parse_args()
runtime = str(Path(arguments.runtime).resolve())
saved = ROOT / '.dev/scratch/source-test'
results = []

def check(name, ok, detail=''):
    results.append((name, bool(ok)))
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else ': ' + str(detail)[:1500]), flush=True)
    return ok

with tempfile.TemporaryDirectory(prefix='w5-', dir='/tmp') as temporary:
    base = Path(temporary).resolve()
    project = base / 'sourcep'; project.mkdir()
    (project / 'elide.pkl').write_text('amends "elide:project.pkl"\nname = "source-example"\n')
    source = project / 'classify.mjs'
    # Line 3 runs under the test and the debug launch; line 5 never does.
    source.write_text('export function classify(value) {\n  if (value > 0) {\n    return "positive";\n  }\n'
                      '  return "other";\n}\nexport const sign = (v) => (v > 0 ? "+" : "-");\nclassify(1);\n')
    (project / 'classify.test.mjs').write_text(
        'import {test} from "node:test";\nimport assert from "node:assert/strict";\n'
        'import {classify, sign} from "./classify.mjs";\n'
        'test("positive values", () => assert.equal(classify(1), "positive"));\n'
        'test("signs", () => assert.equal(sign(1), "+"));\n')
    (project / 'notes.txt').write_text('not a source\n')
    # Near the size limit, and one past it.
    large = project / 'large.mjs'
    large.write_text(''.join(f'export const value{i} = {i}; // padding to make the line longer than usual\n' for i in range(5000)))
    huge = project / 'huge.mjs'
    huge.write_text('// x\n' * 140000)
    state = base / 'state'; (state / 'config').mkdir(parents=True)
    package = state / 'crates/plugins/fixtures/elide'
    shutil.copytree(ROOT / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    broker_state = base / 'projects'
    config = {'runtime': runtime, 'broker': str(ROOT / 'dist/elide-tern-broker'), 'project_state': str(broker_state)}
    if arguments.sdk:
        config['sdk'] = str(Path(arguments.sdk).resolve())
    (package / 'config.json').write_text(json.dumps(config))
    (state / 'crates/tern/goldens').mkdir(parents=True)
    env = {**os.environ, 'STENCIL_FIXTURE_ROOT': str(state / 'crates/tern'), 'TERN_PLUGIN_DATA': str(state / 'data'),
           'TERN_DAEMON_SOCKET': str(state / 'daemon.sock'), 'TERN_CONFIG_DIR': str(state / 'config')}
    out = base / 'out'; out.mkdir(); log = (out / 'tern.log').open('w')
    subprocess.run(['tern', 'plugin', 'link', str(package)], env=env, check=True, stdout=log, stderr=log)
    daemon = subprocess.Popen(['tern', 'daemon', '--socket', str(state / 'daemon.sock')], stdout=log, stderr=log, env=env)
    sock = base / 'c.sock'
    server = subprocess.Popen(['tern', '--control', str(sock), '--out', str(out), '--dir', str(project)],
                              stdout=log, stderr=log, env=env)

    def ctl(command, *words):
        r = subprocess.run(['tern', 'ctl', '--control', str(sock), command,
                            *(str(w) if command == 'tree' or isinstance(w, (int, float)) else json.dumps(str(w), ensure_ascii=False) for w in words)],
                           capture_output=True, text=True, timeout=30)
        return json.loads(r.stdout)

    def nodes(selector):
        return ctl('tree', selector).get('nodes', [])

    def tree(selector):
        return json.dumps(ctl('tree', selector), ensure_ascii=False)

    def wait(predicate, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.25)
        return None

    def broker(op, **fields):
        r = subprocess.run([str(ROOT / 'dist/elide-tern-broker'), 'request', str(broker_state)],
                           input=json.dumps({'op': op, **fields}), capture_output=True, text=True, timeout=20)
        reply = json.loads(r.stdout)
        assert reply['ok'], reply
        return reply['result']

    # Gutter runs: one per line, "<number> <sign> " with the sign in its tone's span.
    def gutter():
        found = {}
        for node in nodes('.sf-editor .sf-ed-gutter'):
            match = re.match(r'^\s*([^\d\s]?)\s*(\d+)', node.get('text') or '')
            if match:
                found[int(match.group(2))] = match.group(1)
        return found

    def signed(line, glyph, tone):
        selector = '.sf-editor .sf-ed-gutter .sf-t-' + tone
        return gutter().get(line) == glyph and any((n.get('text') or '').strip() == glyph for n in nodes(selector))

    def lua(code):
        marker = 'w5-' + str(uuid.uuid4()) + ':'
        ctl('carly', 'lua', code + '\nprint(' + json.dumps(marker) + ')')
        def done():
            value = ctl('state').get('carly', {}).get('last_tool')
            return value if value and (marker in value.get('text', '') or value.get('error')) else None
        value = wait(done, 30)
        ctl('carly', 'close')
        return value

    def shots(name):
        wait(lambda: not nodes('.toast'), 12)
        ctl('prefs', 'preview', 'light')
        ctl('prefs', 'close')
        time.sleep(.5)
        ctl('shot', name + '-light')
        ctl('prefs', 'preview', 'dark-nord')
        ctl('prefs', 'close')
        time.sleep(.5)
        ctl('shot', name + '-dark')
        ctl('prefs', 'preview', 'light')
        ctl('prefs', 'close')

    # Each line's tint is a `mark <tone>` run on its first character; match it to a line number by
    # the gutter row at the same height.
    def tinted(tone, line):
        rows = {}
        for node in nodes('.sf-editor .sf-ed-gutter'):
            match = re.match(r'^\s*[^\d\s]?\s*(\d+)', node.get('text') or '')
            if match:
                rows[int(match.group(1))] = node['rect'][1]
        y = rows.get(line)
        return y is not None and any(abs(n['rect'][1] - y) < 4 for n in nodes('.sf-editor .sf-t-mark.sf-t-' + tone))

    # Wide panes show the overlay switch as tabs, split panes (under about 150 columns) as a well of
    # icon toggles.
    def overlay(mode):
        if nodes('[data-role="source-overlays"]'):
            click('[data-role="source-overlays"] .sf-tab[data-tab="' + mode + '"]')
        else:
            click('[data-role="source-btn-overlay-' + mode + '"]')
        time.sleep(.6)

    cell_width = [8.04]

    def first_text_rect():
        found = nodes('[data-role="source-editor"] .sf-ed-text .tk-keyword')
        return found[0].get('rect') if found else None

    def numbered(line, token):
        return any((n.get('text') or '').strip() == str(line) for n in nodes('.sf-editor .sf-ed-gutter .sf-t-' + token))

    # Screenshot pixels, to check what the tints paint (a run's background is not a node).
    decoded = {}
    def png(path):
        if str(path) in decoded:
            return decoded[str(path)]
        data = Path(path).read_bytes()
        pos, chunks, width = 8, [], 0
        while pos < len(data):
            length, kind = struct.unpack('>I4s', data[pos:pos + 8])
            body = data[pos + 8:pos + 8 + length]
            if kind == b'IHDR':
                width, height, depth, color = struct.unpack('>IIBB', body[:10])
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
        decoded[str(path)] = lambda x, y: tuple(rows[int(y)][int(x) * channels:int(x) * channels + 3])
        return decoded[str(path)]

    def gutter_rows():
        rows = {}
        for node in nodes('.sf-editor .sf-ed-gutter'):
            match = re.match(r'^\s*[^\d\s]?\s*(\d+)', node.get('text') or '')
            if match:
                rows[int(match.group(1))] = node['rect']
        return rows

    # A tinted row: past the text, its middle differs from an untinted row's at the same x (the band
    # is there and row-aligned), the neighbouring untinted row is untouched, and inside the text some
    # pixels stay far darker or lighter than the band (the text paints over it).
    def band_ok(shot, line, clear_line):
        pixel = png(out / 'live' / (shot + '.png'))
        rows = gutter_rows()
        editor = nodes('[data-role="source-editor"]')[0]['rect']
        far = (editor[0] + editor[2] - 24) * 2
        mid = lambda r: (rows[r][1] + rows[r][3] / 2) * 2
        band, clear = pixel(far, mid(line)), pixel(far, mid(clear_line))
        tinted = sum(abs(p - q) for p, q in zip(band, clear)) > 12
        text_x = (rows[line][0] + rows[line][2] + 4) * 2
        ink = [pixel(text_x + dx, mid(line)) for dx in range(0, 360, 2)]
        lum = lambda p: sum(p) / 3
        visible = sum(1 for p in ink if abs(lum(p) - lum(band)) > 60) >= 4
        return tinted and visible, {'band': band, 'clear': clear, 'tinted': tinted, 'text_visible': visible}

    def click(selector):
        enabled = selector + ':not(.disabled):not([disabled]):not([aria-disabled="true"])'
        wait(lambda: any(n.get('rect', [0, 0, 0, 0])[2] > 0 for n in nodes(enabled)), 30)
        return ctl('click', enabled)

    binding = None
    try:
        wait(sock.exists)
        time.sleep(4)
        plugins = subprocess.run(['tern', 'plugin', 'list', '--json'], env=env, capture_output=True, text=True).stdout
        check('plugin loads', 'elide' in plugins, plugins)

        # elide://source with a project root opens the block, not Tern's editor.
        ctl('open-url', 'elide://source?root=' + str(project) + '&path=' + str(source) + '&line=2')
        check('block opens from link', wait(lambda: 'classify(value)' in tree('[data-role="source-editor"]'), 30),
              tree('.sf-block'))
        check('head row names file and project',
              wait(lambda: 'classify.mjs' in tree('.sf-main') and 'sourcep' in tree('.sf-main'), 30), tree('.sf-main'))
        check('no file block for source link', not any(Path(b['path']).resolve() == source.resolve()
              for b in ctl('state').get('file_blocks', []) if b.get('path')), ctl('state').get('file_blocks'))
        check('line numbers in gutter', wait(lambda: len(gutter()) >= 7, 10), tree('.sf-editor .sf-ed-gutter'))
        check('caret starts on linked line', wait(lambda: 'Ln 2,' in tree('[data-role="source-position"]'), 10),
              tree('[data-role="source-position"]'))
        # The gutter is exactly sign + digits + space + hairline + two spaces: 1 + 2 + 1 + 1 + 2 cells here.
        def gutter_cells(digits):
            cell = nodes('.sf-editor .sf-t-mark')[0]['rect'][2] if nodes('.sf-editor .sf-t-mark') else cell_width[0]
            cell_width[0] = cell
            # With two editors on screen, the widest gutter is the file with the most digits.
            width = max(n['rect'][2] for n in nodes('.sf-editor .sf-ed-gutter'))
            return abs(width - (5 + digits) * cell) < 1.5, {'gutter': width, 'cell': cell, 'cells': width / cell}
        ok, detail = gutter_cells(1)
        check('gutter width, single-digit file', ok, detail)
        click('[data-role="source-editor"]')

        def editor_text():
            found = nodes('[data-role="source-editor"] .sf-ed-text')
            return found[0].get('text', '') if found else ''
        def position():
            return tree('[data-role="source-position"]')
        def go_line(n):
            ctl('key', 'Control+g')
            wait(lambda: nodes('[data-role="source-go-input"]'), 10)
            ctl('type', str(n))
            ctl('key', 'Enter')
            return wait(lambda: f'Ln {n},' in position(), 10)

        # Editing: go to a line, type, save, undo and redo.
        check('overlay toggles in a split pane', all(nodes('[data-role="source-btn-overlay-' + m + '"]')
              for m in ['none', 'coverage', 'debug']), tree('[data-role="source-toolbar"]'))
        check('go to line', go_line(6), position())
        ctl('key', 'End')
        ctl('key', 'Enter')
        ctl('type', '// edited')
        check('typing edits the buffer', wait(lambda: '// edited' in editor_text(), 10), editor_text())
        shots('source-dirty')
        check('modified shown', wait(lambda: 'Modified' in tree('[data-role="source-modified"]')
              and nodes('[data-role="source-dirty"]') and nodes('[data-role="source-btn-save"]'), 10), tree('.sf-main'))
        ctl('key', 'Meta+s')
        check('save writes the file', wait(lambda: source.read_text().splitlines()[6] == '// edited', 10), source.read_text())
        check('clean after save', wait(lambda: not nodes('[data-role="source-modified"]'), 10), tree('.sf-dock'))
        ctl('key', 'Meta+z')
        check('undo', wait(lambda: '// edited' not in editor_text(), 10), editor_text())
        check('undo dirties', wait(lambda: nodes('[data-role="source-modified"]'), 10), tree('.sf-dock'))
        ctl('key', 'Meta+Shift+z')
        check('redo', wait(lambda: '// edited' in editor_text() and not nodes('[data-role="source-modified"]'), 10),
              editor_text())
        # Auto-indent: Enter inside the function keeps its indentation.
        go_line(2)
        ctl('key', 'End')
        ctl('key', 'Enter')
        ctl('type', 'x;')
        ctl('key', 'Meta+s')
        check('auto-indent', wait(lambda: '    x;' in source.read_text().splitlines(), 10), source.read_text())
        # Typing and the newline are separate undo steps.
        ctl('key', 'Meta+z')
        ctl('key', 'Meta+z')
        wait(lambda: nodes('[data-role="source-modified"]'), 10)
        ctl('key', 'Meta+s')
        check('saved without the undone line', wait(lambda: len(source.read_text().splitlines()) == 9 and not nodes('[data-role="source-modified"]'), 10),
              source.read_text())

        # The file changes underneath a clean buffer: the block reloads it.
        source.write_text(source.read_text() + '// external\n')
        check('reload from disk', wait(lambda: 'Reloaded classify.mjs' in tree('.toast') and 10 in gutter(), 15), tree('.toast'))

        # Find marks matches and selects the next one; go to line moves the caret.
        ctl('key', 'Control+f')
        wait(lambda: nodes('[data-role="source-find-input"]'), 10)
        ctl('type', 'return')
        check('find counts matches', wait(lambda: '2 matches' in tree('[data-role="source-find"]'), 10), tree('[data-role="source-find"]'))
        check('find marks matches', wait(lambda: len([n for n in nodes('[data-role="source-editor"] .sf-t-mark')
              if 'return' in (n.get('text') or '')]) >= 2, 10), tree('[data-role="source-editor"] .sf-t-mark'))
        ctl('key', 'Enter')
        check('find selects next', wait(lambda: '6 selected' in tree('[data-role="source-selection"]'), 10), tree('.sf-dock'))
        ctl('shot', 'source-find')
        ctl('key', 'Escape')
        check('find closes', wait(lambda: not nodes('[data-role="source-find"]'), 10), tree('.sf-dock'))

        # Coverage: the empty state offers a run; its result marks lines.
        overlay('coverage')
        check('coverage empty state', wait(lambda: 'No coverage yet' in tree('[data-role="source-badge"]'), 60),
              tree('[data-role="source-toolbar"]'))
        # Running tests reports in the badge and status bar only: the code never moves.
        rect_before = first_text_rect()
        click('[data-role="source-btn-run-coverage"]')
        wait(lambda: 'Running tests' in tree('[data-role="source-badge"]') + tree('[data-role="source-overlay-state"]'), 30)
        rect_during = first_text_rect()
        check('covered lines tinted', wait(lambda: tinted('success', 3), 240), tree('.sf-editor .sf-t-mark'))
        rect_after = first_text_rect()
        check('running tests moves no text', rect_before and rect_before[:2] == (rect_during or [])[:2] == (rect_after or [])[:2],
              [rect_before, rect_during, rect_after])
        check('uncovered line tinted', tinted('error', 5), tree('.sf-editor .sf-t-mark'))
        check('coverage keeps the editor', nodes('[data-role="source-editor"]'), tree('.sf-main'))
        check('hotness hidden', not nodes('[data-role="source-btn-overlay-hotness"]') and 'Hotness' not in tree('[data-role="source-overlays"]'),
              tree('[data-role="source-toolbar"]'))
        check('coverage badge', wait(lambda: '% covered' in tree('.sf-main .sf-badge'), 10), tree('.sf-main .sf-badge'))
        print('     partial line tinted: %s' % tinted('warning', 8), flush=True)
        # `inferred` lines (closers, blanks, comments) render at half the covered tint once the
        # broker's coverage page carries that state.
        probe = broker('project_attach', root=str(project), runtime=runtime)
        try:
            runs = [r for r in broker('project_snapshot', binding=probe)['runs'] if r['options'].get('coverage')]
            files = broker('project_coverage_page', binding=probe, run=runs[-1]['id'])['files']
            index = next(f['index'] for f in files if f['path'].endswith('classify.mjs'))
            measured = broker('project_coverage_page', binding=probe, run=runs[-1]['id'], file=index)['lines']
        finally:
            broker('project_detach', binding=probe)
        inferred = [l['line'] for l in measured if l.get('state') == 'inferred']
        if inferred:
            check('inferred line at half tint', tinted('success.sf-t-dim', inferred[0]), tree('.sf-editor .sf-t-mark'))
        else:
            print('     inferred lines: none in this runtime\'s coverage page yet', flush=True)
        shots('source-coverage')
        ok, detail = gutter_cells(2)
        check('gutter width, 10-line file', ok, detail)
        ok, detail = band_ok('source-coverage-light', 5, 4)
        check('uncovered band row-aligned, under the text (light)', ok, detail)
        ok, detail = band_ok('source-coverage-light', 3, 4)
        check('covered band row-aligned, under the text (light)', ok, detail)
        ok, detail = band_ok('source-coverage-dark', 5, 4)
        check('uncovered band row-aligned, under the text (dark)', ok, detail)
        # Negative control: an unmeasured row (4) reads untinted against another (1).
        ok, detail = band_ok('source-coverage-light', 4, 1)
        check('unmeasured row stays untinted', not detail['tinted'], detail)
        # An unsaved edit on a measured line mutes its tint; untouched lines keep theirs.
        click('[data-role="source-editor"]')
        go_line(3)
        ctl('key', 'Home')
        ctl('type', '/* a */ ')
        check('edited line muted', wait(lambda: tinted('muted', 3), 10), tree('.sf-editor .sf-t-mark'))
        check('untouched lines keep tints', tinted('error', 5) and tinted('success', 2), tree('.sf-editor .sf-t-mark'))
        for _ in range(6):
            if not nodes('[data-role="source-modified"]'):
                break
            ctl('key', 'Meta+z')
            time.sleep(.3)
        check('undo back to the saved text', wait(lambda: '/* a */' not in editor_text() and not nodes('[data-role="source-modified"]'), 10), editor_text())

        # Switching overlays changes only colors: the first line's text stays where it was.
        overlay('none')
        time.sleep(.5)
        rects = [first_text_rect()]
        for tab in ['coverage', 'debug', 'none']:
            overlay(tab)
            time.sleep(.8)
            rects.append(first_text_rect())
        check('overlay switches move no text', rects[0] and all(r and r[:2] == rects[0][:2] for r in rects), rects)

        # Debug: F9 on two lines, F5 launches; the target pauses at the call first, then in the function.
        overlay('debug')
        check('debug launch offered', wait(lambda: nodes('[data-role="source-btn-debug-launch"]'), 30), tree('.sf-main'))
        check('no stepping before a target', not nodes('[data-role="source-debug-steps"]'), tree('[data-role="source-toolbar"]'))
        click('[data-role="source-editor"]')
        go_line(3)
        ctl('key', 'F9')
        check('breakpoint sign', wait(lambda: signed(3, '●', 'error'), 10), gutter())
        check('breakpoint number in error', wait(lambda: numbered(3, 'error'), 10), tree('.sf-editor .sf-ed-gutter'))
        check('breakpoint line tinted', tinted('error', 3), tree('.sf-editor .sf-t-mark'))
        go_line(9)
        ctl('key', 'F9')
        wait(lambda: signed(9, '●', 'error'), 10)
        ctl('key', 'F5')
        check('stop marker', wait(lambda: signed(9, '▶', 'accent'), 120), tree('.sf-main'))
        check('stop line tinted', wait(lambda: tinted('accent', 9) and numbered(9, 'accent'), 10), tree('.sf-editor .sf-t-mark'))
        check('stepping wells while paused', nodes('[data-role="source-debug-run"]') and nodes('[data-role="source-debug-steps"]')
              and nodes('[data-role="source-btn-debug-resume"]'), tree('[data-role="source-toolbar"]'))
        # A split pane leaves the state to the status bar while the debugger's wells show.
        check('paused state with line', wait(lambda: 'Paused at 9' in tree('[data-role="source-overlay-state"]'), 10), tree('.sf-dock'))
        shots('source-debug-split')
        ctl('key', 'F5')
        check('second stop', wait(lambda: signed(3, '▶', 'accent'), 60), gutter())
        binding = broker('project_attach', root=str(project), runtime=runtime)
        snapshot = broker('project_debug_snapshot', binding=binding, compact=True)
        check('broker agrees on stop', snapshot and snapshot['debug']['state'] == 'stopped'
              and snapshot['debug']['frames'][0]['line'] == 3, snapshot and snapshot['debug'])
        lua('cx.layout:move_to_new_tab(cx.session:focused())')
        time.sleep(1)
        shots('source-debug-wide')
        ctl('key', 'F5')
        check('continue runs to exit', wait(lambda: 'Exited' in tree('.sf-main .sf-badge'), 60), tree('.sf-main'))
        # Large files: a ~380 KiB file opens and takes edits; one past the limit says so.
        ctl('open-url', 'elide://source?root=' + str(project) + '&path=' + str(large) + '&line=4000')
        check('large file opens at line', wait(lambda: 'Ln 4000,' in tree('[data-role="source-position"]'), 30),
              tree('[data-role="source-position"]'))
        # The new block has the focus; type into it, not into the first editor on screen.
        def statuses():
            return [n.get('text') or '' for n in nodes('[data-role="source-status"]')]
        started = time.monotonic()
        ctl('type', 'z')
        check('large file takes edits', wait(lambda: len(statuses()) == 2 and 'Modified' in statuses()[-1], 10), statuses())
        check('edit stays in its block', 'Modified' not in statuses()[0], statuses())
        # Past 600 lines the editor is sent without `lang`, so it is not `.code`; the small file is.
        ok, detail = gutter_cells(4)
        check('gutter width, 5,000-line file', ok, detail)
        check('large file not highlighted', len(nodes('.sf-editor.code')) == 1 and len(nodes('.sf-editor:not(.code)')) == 1,
              tree('.sf-editor'))
        print('     large file edit round trip: %.2fs' % (time.monotonic() - started), flush=True)
        ctl('shot', 'source-large')
        ctl('open-url', 'elide://source?root=' + str(project) + '&path=' + str(huge))
        check('oversized file refused', wait(lambda: 'File too large' in tree('[data-role="source-problem"]'), 30),
              tree('.sf-main'))
        ctl('open-url', 'elide://source?root=' + str(project) + '&path=' + str(project / 'notes.txt'))
        check('non-source link opens the editor', wait(lambda: any(Path(b['path']).resolve() == (project / 'notes.txt').resolve()
              for b in ctl('state').get('file_blocks', []) if b.get('path')), 15), ctl('state').get('file_blocks'))
        check('no plugin failure toast', 'failed' not in tree('.toast'), tree('.toast'))
        log.flush()
        check('no budget overrun', 'exceeded' not in (out / 'tern.log').read_text(), '')
    finally:
        if binding:
            try:
                broker('project_detach', binding=binding)
            except Exception:
                pass
        ctl('quit')
        try:
            server.wait(timeout=10)
        except Exception:
            server.kill()
        daemon.terminate()
        shutil.copytree(out, saved, dirs_exist_ok=True)

failed = [n for n, ok in results if not ok]
print(('FAIL: ' + ', '.join(failed)) if failed else 'PASS: source editor editing, save, reload, undo, find, go to line, coverage and debug overlays')
sys.exit(1 if failed else 0)
