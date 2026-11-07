"""Window integration points in an isolated desktop window: the build and tap lenses, elide:// links,
project chrome and command_finished. Usage: python3 tests/integration.py --runtime /path/to/elide"""
import argparse, json, os, shlex, shutil, subprocess, sys, tempfile, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True, help='Elide runtime with `elide build` and `elide test --reporter=tap`')
runtime = str(Path(parser.parse_args().runtime).resolve())
saved = ROOT / '.dev/scratch/integration-test'
results = []

def check(name, ok, detail=''):
    results.append((name, bool(ok)))
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else ': ' + str(detail)[:1500]), flush=True)

with tempfile.TemporaryDirectory(prefix='w3-', dir='/tmp') as temporary:
    base = Path(temporary).resolve()
    build = base / 'buildp'; (build / 'src/main/java').mkdir(parents=True)
    (build / 'elide.pkl').write_text('amends "elide:project.pkl"\n\nname = "build-smoke"\n\njvm {\n  main = "Hello"\n}\n')
    (build / 'src/main/java/Hello.java').write_text(
        'public class Hello {\n  public static void main(String[] args) {\n    int x = "oops";\n'
        '    System.out.println(x)\n  }\n}\n')
    tapp = base / 'tapp'; tapp.mkdir()
    (tapp / 'elide.pkl').write_text('amends "elide:project.pkl"\nname = "tap-smoke"\n')
    (tapp / 'sample.test.mjs').write_text(
        'import { test } from "node:test";\nimport assert from "node:assert";\n'
        'test("adds", () => { assert.strictEqual(1 + 1, 2); });\n'
        'test("fails", () => { assert.strictEqual(1 + 1, 3); });\n')
    (tapp / 'two.js').write_text('one\ntwo\nthree\n')
    (tapp / 'nested').mkdir()
    outside = base / 'outside.txt'; outside.write_text('outside\n')
    state = base / 'state'; (state / 'config').mkdir(parents=True)
    package = state / 'crates/plugins/fixtures/elide'
    shutil.copytree(ROOT / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    (package / 'config.json').write_text(json.dumps({'runtime': runtime, 'broker': str(ROOT / 'dist/elide-tern-broker')}))
    (state / 'crates/tern/goldens').mkdir(parents=True)
    env = {**os.environ, 'STENCIL_FIXTURE_ROOT': str(state / 'crates/tern'), 'TERN_PLUGIN_DATA': str(state / 'data'),
           'TERN_DAEMON_SOCKET': str(state / 'daemon.sock'), 'TERN_CONFIG_DIR': str(state / 'config')}
    out = base / 'out'; out.mkdir(); log = (out / 'tern.log').open('w')
    subprocess.run(['tern', 'plugin', 'link', str(package)], env=env, check=True, stdout=log, stderr=log)
    daemon = subprocess.Popen(['tern', 'daemon', '--socket', str(state / 'daemon.sock')], stdout=log, stderr=log, env=env)
    sock = base / 'c.sock'
    server = subprocess.Popen(['tern', '--control', str(sock), '--out', str(out), '--dir', str(tapp / 'nested')],
                              stdout=log, stderr=log, env=env)

    def ctl(command, *words):
        r = subprocess.run(['tern', 'ctl', '--control', str(sock), command,
                            *(str(w) if command == 'tree' else json.dumps(str(w), ensure_ascii=False) for w in words)],
                           capture_output=True, text=True, timeout=30)
        return json.loads(r.stdout)

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

    def lua(code):
        marker = 'w3-' + str(uuid.uuid4()) + ':'
        ctl('carly', 'lua', code + '\nprint(' + json.dumps(marker) + ')')
        def done():
            value = ctl('state').get('carly', {}).get('last_tool')
            return value if value and (marker in value.get('text', '') or value.get('error')) else None
        value = wait(done, 30)
        ctl('carly', 'close')
        return value

    def run(line):
        ctl('run', line)

    try:
        wait(sock.exists)
        time.sleep(4)
        ctl('status-bar', 'on')
        plugins = subprocess.run(['tern', 'plugin', 'list', '--json'], env=env, capture_output=True, text=True).stdout
        check('plugin loads', 'elide' in plugins, plugins)
        bindir = str(Path(runtime).parent)
        run('export PATH=' + shlex.quote(bindir) + ':$PATH')

        # Chrome: from tapp/nested the default title would be "nested"; the project names it "tapp".
        check('status segment', wait(lambda: 'tapp' in tree('.sl-plugin')), tree('.sl-plugin'))
        # `ctl state` reports Tern's own title; the drawn tab carries the formatter's.
        check('tab title from project', wait(lambda: any((n.get('title') or '').startswith('tapp ') for n in ctl('tree', '[role=tab]').get('nodes', [])), 20),
              tree('[role=tab]'))
        check('no plugin error toast', 'failed' not in tree('.toast'), tree('.toast'))
        run('cd ' + shlex.quote(str(tapp)))

        def last_block():
            nodes = ctl('tree', '.sf-block').get('nodes', [])
            return nodes[-1] if nodes else None
        def block_text(count):
            nodes = ctl('tree', '.sf-block').get('nodes', [])
            return json.dumps(nodes[count:], ensure_ascii=False) if len(nodes) > count else ''

        # TAP lens and the failing-test toast from command_finished.
        before = len(ctl('tree', '.sf-block').get('nodes', []))
        run('elide test --reporter=tap sample.test.mjs')
        check('tests failed toast', wait(lambda: 'Tests failed' in tree('.toast'), 240), tree('.toast'))
        tap = wait(lambda: (lambda t: t if 'not ok' in t else None)(block_text(before)), 30) or block_text(before)
        check('tap lens summary', '1 passed' in tap and '1 failed' in tap, tap)
        check('tap lens rows', 'adds' in tap and 'fails' in tap and 'strictly equal' in tap, tap)
        check('outcome segment', wait(lambda: 'Tests failed' in tree('.sl-plugin'), 10), tree('.sl-plugin'))

        # Build lens on a Java compile error.
        before = len(ctl('tree', '.sf-block').get('nodes', []))
        run('cd ' + shlex.quote(str(build)))
        run('elide build')
        check('build segment', wait(lambda: 'Build failed' in tree('.sl-plugin'), 280), tree('.sl-plugin'))
        built = wait(lambda: (lambda t: t if 'expected' in t else None)(block_text(before)), 30) or block_text(before)
        check('build lens diagnostic', 'expected' in built and 'Hello.java' in built and ':4:26' in built, built)
        check('build lens excerpt', 'System.out.println' in built, built)
        ctl('shot', 'lenses')
        run('cd ' + shlex.quote(str(tapp)))
        wait(lambda: 'tapp' in tree('.sl-plugin'), 30)

        # elide:// links as the system hands them to Tern (tern.route.link).
        def opened(path):
            return wait(lambda: any(Path(b['path']).resolve() == path.resolve() for b in ctl('state').get('file_blocks', [])), 15)
        def toast_after(url, text):
            ctl('open-url', url)
            return wait(lambda: text in tree('.toast'), 10)
        # Sources inside a known project open the Elide source block; other files open Tern's editor.
        def source_block(text):
            return wait(lambda: text in tree('[data-role~="source-editor"]'), 15)
        ctl('open-url', 'elide://source?path=' + str(tapp / 'two.js') + '&line=2')
        check('source link opens', source_block('three'), tree('[data-role~="source-editor"]'))
        ctl('open-url', 'elide://source?root=' + str(tapp) + '&path=' + str(tapp / 'sample.test.mjs') + '&line=3')
        check('source link with root opens', source_block('strictEqual'), tree('[data-role~="source-editor"]'))
        ctl('open-url', 'elide://source?root=' + str(tapp) + '&path=' + str(tapp / 'elide.pkl'))
        check('non-source link opens the editor', opened(tapp / 'elide.pkl'), ctl('state').get('file_blocks'))
        def none_open(path):
            return not any(Path(b['path']).resolve() == path.resolve() for b in ctl('state').get('file_blocks', []))
        check('outside root rejected', toast_after('elide://source?root=' + str(tapp) + '&path=' + str(outside), 'malformed') and none_open(outside), tree('.toast'))
        check('undetected project rejected', toast_after('elide://source?path=' + str(outside), 'outside a detected project') and none_open(outside), tree('.toast'))
        check('dotdot rejected', toast_after('elide://source?path=' + str(tapp) + '/../outside.txt', 'malformed') and none_open(outside), tree('.toast'))
        check('root without manifest rejected', toast_after('elide://tests?root=' + str(base), 'no elide.pkl'), tree('.toast'))
        check('other scheme untouched', ctl('open-url', 'elide-not://x').get('ok'))
        tabs = len(ctl('state')['tabs'])
        ctl('open-url', 'elide://tests?root=' + str(tapp))
        check('tests link opens project tests', wait(lambda: len(ctl('state')['tabs']) > tabs, 60), ctl('state')['tabs'])
        ctl('shot', 'routes')
    finally:
        ctl('quit')
        try:
            server.wait(timeout=10)
        except Exception:
            server.kill()
        daemon.terminate()
        shutil.copytree(out, saved, dirs_exist_ok=True)

failed = [n for n, ok in results if not ok]
print(('FAIL: ' + ', '.join(failed)) if failed else 'PASS: lenses, elide:// routes, chrome and command_finished')
sys.exit(1 if failed else 0)
