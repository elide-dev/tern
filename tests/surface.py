"""Exercise native REPL controls and real SDK kernels in an isolated Tern renderer."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--sdk', required=True)
parser.add_argument('--runtime')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
tern = shutil.which('tern')
assert tern, 'Tern must be installed'
out = root / '.dev' / 'scratch' / 'surface-test'
out.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='tsp-', dir='/tmp') as state:
    socket = Path(state) / 'control.sock'
    with (out / 'serve.log').open('w') as log:
        server = subprocess.Popen([tern, 'serve', '--control', str(socket), '--out', str(out)], stdout=log, stderr=log)
        def ctl(*words):
            result = subprocess.run([tern, 'ctl', '--control', str(socket), words[0], *(str(w) if words[0] == 'tree' else json.dumps(str(w)) for w in words[1:])],
                                    capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply

        def nodes(selector):
            return ctl('tree', selector).get('nodes', [])

        def wait(predicate):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(0.1)
            raise AssertionError('Timed out waiting for native UI')

        def ready():
            wait(lambda: any(n.get('text') == 'Ready' for n in nodes('.sf-badge')))

        def switch(label):
            ctl('click', '.sf-select-btn')
            wait(lambda: len(nodes('.sf-select.open')) == 1)
            options = nodes('.sf-select-opt')
            assert len(nodes('.sf-select-opt svg')) == len(options), 'Native language icons missing'
            for required in ['JavaScript', 'Python', 'CEL', 'Pkl']:
                assert any(option.get('text', '').startswith(required) for option in options), required
            index = next(i for i, option in enumerate(options, 1) if option.get('text', '').startswith(label))
            ctl('click', f'.sf-select-opt:nth-child({index})')
            wait(lambda: any(n.get('text') == label for n in nodes('.sf-select-v')))
            wait(lambda: not nodes('.sf-select.open'))
            prompt = {'JavaScript': 'js', 'Python': 'py', 'Kotlin': 'kt', 'CEL': 'cel', 'Pkl': 'pkl'}[label]
            wait(lambda: any(n.get('text', '').startswith(prompt + ' ❯') for n in nodes('.sf-editor')))
            ready()

        def evaluate(source, expected):
            ready()
            before = len(nodes('.sf-json'))
            sources = len(nodes('.sf-code'))
            for index, line in enumerate(source.split('\n')):
                if index:
                    ctl('key', 'shift+Enter')
                ctl('type', line)
            ctl('key', 'Enter')
            wait(lambda: len(nodes('.sf-code')) > sources)
            ready()
            if expected is None:
                assert len(nodes('.sf-json')) == before, 'Statement produced a result'
            else:
                wait(lambda: len(nodes('.sf-json')) > before)
                assert expected in nodes('.sf-json')[-1].get('text', ''), nodes('.sf-json')[-1]

        try:
            wait(socket.exists)
            host = [str(Path(args.runtime).resolve()), 'tern', 'repl'] if args.runtime else [str(root / 'dist/elide-tern-repl')]
            cmd = shlex.join([*host, str(root / 'dist/elide-tern-broker'),
                              str(Path(args.sdk).resolve()), str(Path(state) / 'repl'), 'js'])
            ctl('run', cmd)
            ready()
            evaluate('const x = 5;', None)
            evaluate('x', '5')
            evaluate('const y = {hi: 5, nested: {items: [1, 2, 3]}};', None)
            evaluate('y.hi', '5')
            evaluate('y', 'hi')
            labels = [n for n in nodes('.sf-main .sf-row') if n.get('text') == 'JavaScript']
            assert len(labels) == 1, 'Repeated language labels'
            assert len(nodes('.sf-json')) == 3, 'Empty result was rendered'
            evaluate('({users: Array.from({length: 8}, (_, id) => ({id, name: "Person " + id, active: true}))})', 'users')
            branches = '.sf-json .sf-tree-row:not(.leaf) .sf-tree-tw'
            wait(lambda: bool(nodes(branches)))
            ctl('shot', 'notebook-json-expanded')
            count = len(nodes('.sf-json .sf-tree-node'))
            ctl('click', branches)
            wait(lambda: len(nodes('.sf-json .sf-tree-node')) != count)
            ctl('shot', 'notebook-javascript')
            switch('Python')
            evaluate('y.hi', '5')
            evaluate('y.hi = 9', None)
            evaluate('{"shared": y.hi, "items": [1, 2, 3]}', 'shared')
            switch('JavaScript')
            evaluate('y.hi', '9')
            evaluate('null', 'null')
            evaluate('({get unsafe() { throw Error("getter ran"); }})', 'Accessor')
            ctl('type', 'y.hi + 1')
            switch('CEL')
            evaluate('y.hi == 9', 'true')
            switch('Pkl')
            evaluate('name = "notebook"\ncount = 6 * 7', 'count')
            ctl('shot', 'notebook-polyglot')
            switch('JavaScript')
            assert any('y.hi + 1' in n.get('text', '') for n in nodes('.sf-editor')), 'Draft was lost'
            ctl('key', 'Enter')
            wait(lambda: '10' in nodes('.sf-json')[-1].get('text', ''))
            ready()
            ctl('key', 'ctrl+l')
            wait(lambda: bool(nodes('.sf-select.open')))
            ctl('key', 'Down')
            ctl('key', 'Enter')
            wait(lambda: any(n.get('text') == 'Python' for n in nodes('.sf-select-v')))
            wait(lambda: any(n.get('text', '').startswith('py ❯') for n in nodes('.sf-editor')))
            evaluate('y.hi', '9')
            ctl('key', 'ctrl+d')
            wait(lambda: not nodes('.sf-dock'))
            print('PASS: silent statements, grouped languages, JSON trees, live JS/Python sharing, CEL, Pkl, drafts, keyboard switching, teardown')
        except Exception:
            ctl('shot', 'failure')
            print(json.dumps(nodes('.sf-region'), indent=2))
            raise
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
