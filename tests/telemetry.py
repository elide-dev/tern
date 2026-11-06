"""Qualify native OTLP inspection and preservation of an independent remote exporter."""
import argparse
import gzip
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import build_opener, ProxyHandler, Request
from urllib.error import HTTPError, URLError

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', default='elide')
parser.add_argument('--static', action='store_true')
parser.add_argument('--local-only', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = root / '.dev/scratch/telemetry-test'
out.mkdir(parents=True, exist_ok=True)
tern = shutil.which('tern')
http = build_opener(ProxyHandler({}))
received = []
lock = threading.Lock()

class Remote(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        if self.headers.get('Content-Encoding') == 'gzip': data = gzip.decompress(data)
        with lock: received.append(json.loads(data))
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'{}')

remote = ThreadingHTTPServer(('127.0.0.1', 0), Remote)
threading.Thread(target=remote.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='otlp-', dir='/tmp') as temporary:
    state = Path(temporary)
    socket = state / 'control.sock'
    (state / 'index.html').write_text('traced')
    script = state / 'server.mjs'
    script.write_text('''import { trace } from "@opentelemetry/api";
const tracer = trace.getTracer("inspection-test");
const session = crypto.randomUUID();
let requests = 0;
Elide.serve({port: 0, hostname: "127.0.0.1", fetch(request) {
  return tracer.startActiveSpan("handler", span => {
    span.setAttribute("answer", 42);
    console.warn("correlated request log");
    const failed = new URL(request.url).pathname === "/fail";
    if (failed) span.setStatus({code: 2, message: "test failure"});
    span.end();
    return new Response("traced", {status: failed ? 500 : 200, headers: {"x-session": session, "x-requests": String(++requests)}});
  });
}});
''')
    with (out / 'tern.log').open('w') as log:
        server = subprocess.Popen([tern, 'serve', '--control', str(socket), '--out', str(out)], stdout=log, stderr=log)
        def ctl(command, *values):
            result = subprocess.run([tern, 'ctl', '--control', str(socket), command,
                *(str(v) if command == 'tree' else json.dumps(str(v)) for v in values)], capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply
        def nodes(selector): return ctl('tree', selector).get('nodes', [])
        def tree(selector='.sf-main'): return json.dumps(ctl('tree', selector))
        def wait(predicate):
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if predicate(): return
                time.sleep(.1)
            raise AssertionError(tree())
        def address():
            match = re.search(r'http://127\.0\.0\.1:\d+', tree('[data-role="address"]'))
            return match.group() if match else None
        sessions = set()
        counts = []
        def request(url, suffix, number):
            trace_id = f'{number:032x}'
            req = Request(url + suffix, headers={'traceparent': f'00-{trace_id}-0000000000000001-01'})
            try:
                with http.open(req, timeout=10) as response:
                    assert response.read() == b'traced'
                    if not args.static:
                        sessions.add(response.headers['x-session'])
                        counts.append(int(response.headers['x-requests']))
            except HTTPError as error: assert suffix == '/fail' and error.code == (404 if args.static else 500)
            return trace_id
        def remote_has(trace_id):
            with lock: return trace_id in json.dumps(received)
        def stopped(url):
            try: http.open(url, timeout=.3).close(); return False
            except (URLError, OSError): return True
        try:
            wait(socket.exists)
            command = ['env']
            for name in os.environ:
                if name.startswith(('OTEL_', 'ELIDE_OTEL_')):
                    command.extend(['-u', name])
            if not args.local_only:
                command.extend([f'OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:{remote.server_port}',
                                'OTEL_EXPORTER_OTLP_PROTOCOL=http/json'])
            command.extend(['OTEL_SERVICE_NAME=inspection-test', str(Path(args.runtime).resolve()), 'tern', 'serve',
                            str(Path(args.runtime).resolve()), str(state if args.static else script)])
            ctl('run', shlex.join(command))
            wait(lambda: address() is not None)
            url = address()
            assert not nodes('[data-role="traces-start"]'), 'Tracing must not require restarting'
            success = request(url, '/', 10)
            failure = request(url, '/fail', 11)
            ctl('click', '[data-role="traces-toggle"]')
            wait(lambda: len(nodes('[data-role="trace"]')) >= 2)
            if not args.local_only: wait(lambda: remote_has(success) and remote_has(failure))
            ctl('click', '[data-role="trace"]')
            wait(lambda: bool(nodes('[data-role="span"]')))
            if not args.static:
                wait(lambda: 'handler' in tree('[data-role="span"]'))
                wait(lambda: 'correlated request log' in tree('[data-role="span"]'))
                assert len(nodes('[data-role="span-track"]')) >= 2
            ctl('click', '[data-role="span"]')
            wait(lambda: bool(nodes('.sf-json')))
            ctl('shot', 'static-trace' if args.static else 'trace-waterfall')
            ctl('appearance', 'dark')
            ctl('shot', 'static-trace-dark' if args.static else 'trace-waterfall-dark')
            ctl('appearance', 'light')
            (out / 'trace-tree.json').write_text(tree())
            ctl('click', '[data-role="traces-errors"]')
            wait(lambda: len(nodes('[data-role="trace"]')) == 1)
            ctl('click', '[data-role="traces-errors"]')
            wait(lambda: len(nodes('[data-role="trace"]')) == 2)
            for cycle in range(2):
                ctl('click', '[data-role="traces-pause"]')
                wait(lambda: 'Capture paused' in tree('[data-role="capture-status"]'))
                time.sleep(.2)
                retained = len(nodes('[data-role="trace"]'))
                paused = request(url, '/', 12 + cycle * 2)
                if not args.local_only: wait(lambda: remote_has(paused))
                else: time.sleep(1)
                assert len(nodes('[data-role="trace"]')) == retained, 'Paused capture retained new traces'
                assert address() == url, 'Pausing restarted the server'
                ctl('click', '[data-role="traces-pause"]')
                wait(lambda: 'Live capture' in tree('[data-role="capture-status"]'))
                time.sleep(.2)
                resumed = request(url, '/', 13 + cycle * 2)
                wait(lambda: len(nodes('[data-role="trace"]')) == retained + 1)
                if not args.local_only: wait(lambda: remote_has(resumed))
                assert address() == url, 'Resuming restarted the server'
            if not args.static:
                assert len(sessions) == 1, 'Runtime process was replaced'
                assert counts == sorted(set(counts)), 'Runtime state was reset'
            ctl('click', '[data-role="traces-clear"]')
            wait(lambda: len(nodes('[data-role="trace"]')) == 0)
            request(url, '/', 20)
            wait(lambda: len(nodes('[data-role="trace"]')) == 1)
            ctl('key', 'ctrl+c')
            wait(lambda: stopped(url))
            print('PASS:', 'static' if args.static else 'runtime', 'OTLP traces, waterfall, remote fanout, live pause/resume, clear, uninterrupted runtime, teardown')
        except Exception:
            (out / 'failure-tree.json').write_text(tree())
            ctl('shot', 'failure')
            raise
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
remote.shutdown()
remote.server_close()
