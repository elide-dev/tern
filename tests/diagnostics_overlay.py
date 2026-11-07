"""Compiler diagnostics in an isolated desktop window: the source block's Diagnostics overlay on a real
`elide build` report (newest run chosen, sign, band, underline, inline message, F8 stepping, count
badge, no reflow), the build lens on plain javac output with elide:// links, and the status segment's
counts, and the workspace's Build button opening the runtime's Build page. Uses W4's fixture project
from tests/build.py. Usage: python3 tests/diagnostics_overlay.py --runtime /path/to/elide (a runtime
whose `elide build` hosts the Build surface and writes diagnostics.json)"""
import argparse, json, os, re, shlex, shutil, subprocess, sys, tempfile, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True, help='Elide runtime with the Build surface and `elide javac`')
runtime = str(Path(parser.parse_args().runtime).resolve())
saved = ROOT / '.dev/scratch/diagnostics-test'
results = []

def check(name, ok, detail=''):
    results.append((name, bool(ok)))
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else ': ' + str(detail)[:1500]), flush=True)

with tempfile.TemporaryDirectory(prefix='w3d-', dir='/tmp') as temporary:
    base = Path(temporary).resolve()
    # tests/build.py's project: a javac error in Util.java, kotlinc warnings in Warn.kt.
    project = base / 'Build λ'
    sources = project / 'src/main/com/example'
    sources.mkdir(parents=True)
    (project / 'elide.pkl').write_text('amends "elide:project.pkl"\n\nname = "build-example"\n\njvm {\n    main = "com.example.HelloKt"\n}\n')
    (sources / 'Hello.kt').write_text('package com.example\n\nfun main() = println(greeting())\n\nfun greeting(): String = "Hello Elide!"\n')
    (sources / 'Warn.kt').write_text('package com.example\n\nfun warn(x: Int): Int {\n  val unused = 3\n  return x!! + 1\n}\n')
    util = sources / 'Util.java'
    util.write_text('package com.example;\n\npublic class Util {\n  public static int twice(int value) {\n    String s = value * 2;\n    return value;\n  }\n}\n')
    # An older run's report that must lose to the build below: a diagnostic on Util.java line 2.
    reports = project / '.dev/reports/build/tern'
    decoy = reports / 'run-decoy'
    decoy.mkdir(parents=True)
    (decoy / 'diagnostics.json').write_text(json.dumps({
        'version': 1, 'outcome': 'failure', 'duration_ms': 1, 'errors': 1, 'warnings': 0, 'notes': 0, 'dropped': 0,
        'diagnostics': [{'severity': 'error', 'path': str(util), 'line': 2, 'col': 1, 'message': 'decoy from an older run'}],
    }))
    os.utime(decoy, (1, 1))
    bindir = Path(runtime).parent
    state = base / 'state'; (state / 'config').mkdir(parents=True)
    package = state / 'crates/plugins/fixtures/elide'
    shutil.copytree(ROOT / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    (package / 'config.json').write_text(json.dumps({'runtime': runtime, 'broker': str(ROOT / 'dist/elide-tern-broker'),
                                                      'project_state': str(base / 'projects')}))
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
        return ctl('tree', selector).get('nodes') or []

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

    def run(line):
        ctl('run', line)

    def lua(code):
        marker = 'w3d-' + str(uuid.uuid4()) + ':'
        ctl('carly', 'lua', code + '\nprint(' + json.dumps(marker) + ')')
        def done():
            value = ctl('state').get('carly', {}).get('last_tool')
            return value if value and (marker in value.get('text', '') or value.get('error')) else None
        value = wait(done, 30)
        ctl('carly', 'close')
        return value

    # The first keyword's rect in the editor: where the code's text sits.
    def first_text_rect():
        found = nodes('[data-role~="source-editor"] .sf-ed-text .tk-keyword')
        return found[0].get('rect') if found else None

    def click(selector):
        wait(lambda: any(n.get('rect', [0, 0, 0, 0])[2] > 0 for n in nodes(selector)), 30)
        return ctl('click', selector)

    # Gutter rows by line number: the sign before the number.
    def gutter():
        found = {}
        for node in nodes('.sf-editor .sf-ed-gutter'):
            match = re.match(r'^\s*([^\d\s]?)\s*(\d+)', node.get('text') or '')
            if match:
                found[int(match.group(2))] = (match.group(1), node['rect'][1])
        return found

    def on_row(selector, line):
        row = gutter().get(line)
        return row is not None and any(abs(n['rect'][1] - row[1]) < 4 for n in nodes(selector))

    try:
        wait(sock.exists)
        time.sleep(4)
        ctl('status-bar', 'on')
        run('export PATH=' + shlex.quote(str(bindir)) + ':$PATH; cd ' + shlex.quote(str(project)))
        terminal = ctl('state')['focused']['id']
        check('project detected', wait(lambda: 'Build λ' in tree('.sl-plugin') or 'build-example' in tree('.sl-plugin'), 30),
              tree('.sl-plugin'))

        # A real build through the Build surface writes the newest report.
        run('elide build')
        fresh = wait(lambda: [p for p in reports.glob('run-*/diagnostics.json') if p.parent.name != 'run-decoy'], 300)
        check('build wrote a report', fresh, sorted(reports.iterdir()))
        report = json.loads(fresh[0].read_text()) if fresh else {}
        util_errors = [d for d in report.get('diagnostics', []) if d.get('path', '').endswith('Util.java')]
        check('report names the javac error', util_errors and util_errors[0]['line'] == 5, report)
        words = []
        for count, one, many in [(report.get('errors', 0), 'error', 'errors'), (report.get('warnings', 0), 'warning', 'warnings')]:
            if count:
                words.append('%d %s' % (count, one if count == 1 else many))
        phrase = ', '.join(words)
        check('status segment counts', wait(lambda: ('Build failed · ' + phrase) in tree('.sl-plugin'), 60),
              (phrase, tree('.sl-plugin')))

        # The source block on Util.java: the Diagnostics tab appears because a report exists.
        ctl('open-url', 'elide://source?root=' + str(project) + '&path=' + str(util) + '&line=1')
        check('block opens', wait(lambda: 'twice' in tree('[data-role~="source-editor"]'), 30), tree('.sf-block'))
        check('diagnostics tab offered', wait(lambda: 'Diagnostics' in tree('[data-role="source-overlays"]')
                                              or nodes('[data-role="source-btn-overlay-diagnostics"]'), 30),
              tree('[data-role="source-overlays"]'))
        wait(first_text_rect, 10)
        time.sleep(1)
        before = first_text_rect()
        if nodes('[data-role="source-overlays"]'):
            click('[data-role="source-overlays"] .sf-tab[data-tab="diagnostics"]')
        else:
            click('[data-role="source-btn-overlay-diagnostics"]')
        check('error sign on line 5', wait(lambda: gutter().get(5, ('',))[0] == '●', 20), gutter())
        check('error band on line 5', wait(lambda: on_row('.sf-editor .sf-t-mark.sf-t-error', 5), 10), tree('.sf-editor .sf-t-mark'))
        check('underline on the token', wait(lambda: on_row('.sf-editor .sf-t-typo', 5), 10), tree('.sf-editor .sf-t-typo'))
        check('inline message', 'incompatible types' in tree('.sf-editor'), tree('.sf-editor'))
        check('newest report wins over the decoy', gutter().get(2, ('',))[0] != '●' and 'decoy' not in tree('.sf-editor'),
              gutter())
        check('count badge', '1 error' in tree('[data-role="source-overlay-state"]') + tree('[data-role="source-badge"]'),
              tree('[data-role="source-overlay-state"]'))
        time.sleep(.8)
        after = first_text_rect()
        check('overlay moves no text', before and after and before[:2] == after[:2], (before, after))
        ctl('key', 'F8')
        check('F8 steps to the diagnostic', wait(lambda: 'Ln 5,' in tree('[data-role="source-position"]'), 10),
              tree('[data-role="source-position"]'))
        ctl('shot', 'diagnostics-overlay')

        # The build lens on plain javac output: grouped by file, counted, linked. Back in the terminal.
        lua('cx.layout:focus(' + str(terminal) + ')')
        wait(lambda: ctl('state')['focused']['id'] == terminal, 10)
        classes = base / 'classes'
        run('elide javac -- -d ' + shlex.quote(str(classes)) + ' ' + shlex.quote(str(util)))
        lens = wait(lambda: (lambda text: text if 'incompatible types' in text else None)(
            tree(".sf-block[data-role='lens.plugin.elide.build'] *")), 240)
        if not lens:
            blocks = nodes('.sf-block')
            lens = json.dumps(blocks, ensure_ascii=False) if blocks and 'incompatible types' in json.dumps(blocks) else ''
        check('lens shows the javac card', lens and 'incompatible types' in lens, tree('.sf-block'))
        check('lens groups by file with counts', lens and 'Util.java' in lens and '1 error' in lens, lens)
        check('lens links the location', lens and 'Open Util.java:5' in lens, lens)
        ctl('shot', 'diagnostics-lens')

        # The workspace's Build button opens the runtime's full Build page.
        lua('cx.layout:focus(' + str(terminal) + ')')
        ctl('plugins', 'run', 'plugin.elide.workspace')
        check('workspace opens', wait(lambda: nodes('[data-role="project-build"]'), 30), tree('.sf-main'))
        time.sleep(6)  # a pane opened under the harness may have paused process callbacks briefly
        ctl('click', '[data-role="project-build"]')
        def launched():
            rows = subprocess.run(['ps', '-axo', 'args'], capture_output=True, text=True).stdout.splitlines()
            return next((row for row in rows if row.startswith(runtime + ' --ignore-version build --surface=screen')), None)
        check('Build button runs build --surface=screen', wait(launched, 60), launched())
        check('Build page shows the failure', wait(lambda: 'Failed' in tree('[data-role="build-status"]'), 240),
              tree('[data-role="build-status"]'))
        ctl('shot', 'diagnostics-build-page')
    finally:
        ctl('quit')
        try:
            server.wait(timeout=10)
        except Exception:
            server.kill()
        daemon.terminate()
        shutil.copytree(out, saved, dirs_exist_ok=True)

failed = [n for n, ok in results if not ok]
print(('FAIL: ' + ', '.join(failed)) if failed else 'PASS: diagnostics overlay, build lens and build counts')
sys.exit(1 if failed else 0)
