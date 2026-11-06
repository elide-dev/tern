"""The Elide source block in an isolated desktop window: elide://source opens it, a coverage run from the
block marks covered and uncovered lines, and the Debug overlay sets a breakpoint with `b`, launches and
shows the stop marker. Usage: python3 tests/source.py --runtime /path/to/elide [--sdk /path/to/embedder]"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time, uuid
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
                      '  return "other";\n}\nclassify(1);\n')
    (project / 'classify.test.mjs').write_text(
        'import {test} from "node:test";\nimport assert from "node:assert/strict";\n'
        'import {classify} from "./classify.mjs";\n'
        'test("positive values", () => assert.equal(classify(1), "positive"));\n')
    (project / 'notes.txt').write_text('not a source\n')
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
                            *(str(w) if command == 'tree' else json.dumps(str(w), ensure_ascii=False) for w in words)],
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
            words = (node.get('text') or '').split()
            if words and words[0].isdigit():
                found[int(words[0])] = words[1] if len(words) > 1 else ''
        return found

    def signed(line, glyph, tone):
        selector = '.sf-editor .sf-ed-gutter .sf-t-' + tone
        return gutter().get(line) == glyph and any((n.get('text') or '').strip() == glyph for n in nodes(selector))

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
        check('caret starts on linked line', wait(lambda: any('2' == (n.get('text') or '').strip()
              for n in nodes('.sf-editor .sf-ed-gutter .sf-t-accent')), 10), tree('.sf-editor .sf-ed-gutter'))
        click('[data-role="source-editor"]')

        # Coverage: the empty state offers a run; its result marks lines.
        click('[data-role="source-overlays"] .sf-tab[data-tab="coverage"]')
        check('coverage empty state', wait(lambda: 'No coverage yet' in tree('[data-role="source-empty"]'), 60),
              tree('.sf-main'))
        click('[data-role="source-run-coverage"]')
        check('covered line marked', wait(lambda: signed(3, '●', 'success'), 240), tree('.sf-editor .sf-ed-gutter'))
        check('uncovered line marked', signed(5, '●', 'error'), gutter())
        check('coverage badge', wait(lambda: '% covered' in tree('.sf-main .sf-badge'), 10), tree('.sf-main .sf-badge'))
        ctl('shot', 'source-coverage')

        # Debug: `b` on the caret line, F5 launches, the stop marker lands on that line.
        click('[data-role="source-overlays"] .sf-tab[data-tab="debug"]')
        check('debug launch offered', wait(lambda: nodes('[data-role="source-debug-launch"]'), 30), tree('.sf-main'))
        click('[data-role="source-editor"]')
        ctl('key', 'j')
        wait(lambda: any('3' == (n.get('text') or '').strip() for n in nodes('.sf-editor .sf-ed-gutter .sf-t-accent')), 10)
        ctl('key', 'b')
        check('breakpoint sign', wait(lambda: signed(3, '●', 'error'), 10), gutter())
        ctl('key', 'F5')
        check('stop marker', wait(lambda: signed(3, '▶', 'accent'), 120), tree('.sf-main'))
        check('paused badge', wait(lambda: 'Paused' in tree('.sf-main .sf-badge'), 10), tree('.sf-main .sf-badge'))
        binding = broker('project_attach', root=str(project), runtime=runtime)
        snapshot = broker('project_debug_snapshot', binding=binding, compact=True)
        check('broker agrees on stop', snapshot and snapshot['debug']['state'] == 'stopped'
              and snapshot['debug']['frames'][0]['line'] == 3, snapshot and snapshot['debug'])
        ctl('shot', 'source-debug')
        ctl('key', 'F5')
        check('continue runs to exit', wait(lambda: 'Exited' in tree('.sf-main .sf-badge'), 60), tree('.sf-main'))
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
print(('FAIL: ' + ', '.join(failed)) if failed else 'PASS: source block, coverage marks, breakpoint and stop marker')
sys.exit(1 if failed else 0)
