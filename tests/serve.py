"""Exercise real static HTTP requests and lifecycle controls in native Tern."""
import argparse
import json
import re
import shlex
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.request import build_opener, ProxyHandler
urlopen = build_opener(ProxyHandler({})).open
from urllib.error import HTTPError, URLError

parser = argparse.ArgumentParser()
parser.add_argument('--runtime')
args = parser.parse_args()

root = Path(__file__).resolve().parents[1]
out = root / '.dev/scratch/serve-test'
out.mkdir(parents=True, exist_ok=True)
tern = shutil.which('tern')
with tempfile.TemporaryDirectory(prefix='serve-', dir='/tmp') as temporary:
    state = Path(temporary)
    (state / 'index.html').write_text('Serving works')
    socket = state / 'control.sock'
    with (out / 'tern.log').open('w') as log:
        server = subprocess.Popen([tern, 'serve', '--control', str(socket), '--out', str(out)], stdout=log, stderr=log)
        def ctl(command, *args):
            result = subprocess.run([tern, 'ctl', '--control', str(socket), command,
                *(str(a) if command == 'tree' else json.dumps(str(a)) for a in args)], capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply
        def tree(selector='.sf-main'):
            return json.dumps(ctl('tree', selector))
        def wait(predicate):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if predicate(): return
                time.sleep(.1)
            raise AssertionError(tree())
        def address():
            return re.search(r'http://127\.0\.0\.1:\d+', tree('[data-role="address"]')).group()
        def stopped(url):
            try: urlopen(url, timeout=.3).close(); return False
            except (URLError, OSError): return True
        try:
            wait(socket.exists)
            ctl('run', shlex.join([str(root / 'dist/elide-tern-serve'), 'elide', str(state)]))
            wait(lambda: 'Running' in tree())
            url = address()
            assert urlopen(url, timeout=10).read() == b'Serving works'
            try: urlopen(url + '/missing', timeout=10)
            except HTTPError as error: assert error.code == 404
            else: raise AssertionError('Missing path was successful')
            wait(lambda: '404' in tree() and '200' in tree())
            ctl('click', '[data-role="request"]')
            wait(lambda: 'duration_ms' in tree('.sf-json'))
            ctl('shot', 'server-requests')
            ctl('click', '[data-role="stop"]')
            wait(lambda: 'Stopped' in tree())
            wait(lambda: stopped(url))
            ctl('click', '[data-role="restart"]')
            wait(lambda: 'Running' in tree())
            url = address()
            assert urlopen(url, timeout=10).read() == b'Serving works'
            ctl('key', 'ctrl+c')
            wait(lambda: stopped(url))
            print('PASS: static requests, 404, details, stop, restart, surface teardown')
            if args.runtime:
                wait(lambda: not ctl('tree', '.sf-dock').get('nodes'))
                script = state / 'server.mjs'
                script.write_text('Elide.serve({port: 0, hostname: "127.0.0.1", fetch(request) { return new Response("runtime works", {status: new URL(request.url).pathname === "/fail" ? 500 : 200}); }});')
                ctl('run', shlex.join([str(root / 'dist/elide-tern-serve'), str(Path(args.runtime).resolve()), str(script)]))
                wait(lambda: 'Running' in tree())
                url = address()
                assert urlopen(url, timeout=10).read() == b'runtime works'
                try: urlopen(url + '/fail', timeout=10)
                except HTTPError as error: assert error.code == 500
                wait(lambda: '500' in tree())
                ctl('shot', 'runtime-requests')
                ctl('click', '[data-role="restart"]')
                wait(lambda: 'Running' in tree() and address() != url)
                wait(lambda: stopped(url))
                url = address()
                ctl('key', 'ctrl+c')
                wait(lambda: stopped(url))
                print('PASS: runtime requests, failure, restart, surface teardown')

        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
