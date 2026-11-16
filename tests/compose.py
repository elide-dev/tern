"""Compose previews through the preview service, as the plugin drives it: `open` a session on a
copy of an Android Compose project, read the page's event socket the way the page does, and post
editor documents. Covers a symlinked project path (the file comes back canonical), a rejected
documents post (the preview suspends with the reason and resumes on the next good post), a project
whose first load fails (fixing its manifest loads it), and closing a session."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True)
parser.add_argument('--project', required=True, help='an Elide Android project with Compose previews')
parser.add_argument('--file', required=True, help='the previewed source, relative to --project')
parser.add_argument('--komodo', help='Komodo executable (default: compose_komodo in plugin/config.json)')
parser.add_argument('--launcher', default=str(root / 'dist/elide-tern-compose'))
args = parser.parse_args()
runtime = str(Path(args.runtime).resolve())
komodo = args.komodo or json.loads((root / 'plugin/config.json').read_text()).get('compose_komodo')
assert komodo, 'Pass --komodo or set compose_komodo in plugin/config.json'


class Page:
    """The page's event socket: frames in, pongs out, as a browser keeps it alive."""

    def __init__(self, url):
        host_port, path = url[len('http://'):].split('/', 1)
        host, port = host_port.split(':')
        self.socket = socket.create_connection((host, int(port)), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall((f'GET /{path}events HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\n'
                             f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
                             f'Origin: http://{host_port}\r\n\r\n').encode())
        data = b''
        while b'\r\n\r\n' not in data:
            data += self.socket.recv(4096)
        head, self.pending = data.split(b'\r\n\r\n', 1)
        assert head.startswith(b'HTTP/1.1 101'), head
        self.status = None

    def _read(self, size):
        while len(self.pending) < size:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise EOFError('the page socket closed')
            self.pending += chunk
        data, self.pending = self.pending[:size], self.pending[size:]
        return data

    def _send(self, opcode, payload=b''):
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + masked)

    def message(self, timeout):
        """The next JSON message within `timeout` seconds, or None."""
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            self.socket.settimeout(left)
            try:
                first, second = self._read(2)
            except socket.timeout:
                return None
            self.socket.settimeout(30)
            size = second & 0x7f
            if size == 126:
                size = struct.unpack('>H', self._read(2))[0]
            elif size == 127:
                size = struct.unpack('>Q', self._read(8))[0]
            payload = self._read(size)
            opcode = first & 0x0f
            if opcode == 9:
                self._send(10, payload)
            elif opcode == 8:
                raise EOFError('the page socket closed')
            elif opcode == 1:
                value = json.loads(payload)
                if value.get('type') == 'status':
                    self.status = (value.get('phase'), value.get('message') or '')
                return value

    def until(self, predicate, timeout, what):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.message(deadline - time.monotonic()) is not None and predicate(self.status):
                return self.status
        raise AssertionError(f'{what}; last status {self.status}')

    def close(self):
        self.socket.close()


def post(url, name, body=None):
    request = urllib.request.Request(url + name, data=None if body is None else json.dumps(body).encode(),
                                     method='GET' if body is None else 'POST')
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b'{}')
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b'{}')


def open_session(project, file, cache):
    result = subprocess.run([args.launcher, 'open', '--runtime', runtime, '--root', str(project), '--file', str(file),
                             '--cache', str(cache), '--keep-alive', '2', '--komodo', komodo],
                            input='{"documents":[]}', capture_output=True, text=True, timeout=120, cwd=project)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def copy(project, destination):
    shutil.copytree(project, destination, symlinks=True, ignore=shutil.ignore_patterns('.dev', 'build', '.git'))
    return destination


with tempfile.TemporaryDirectory(prefix='compose-', dir='/tmp') as temporary:
    # Under /tmp, which macOS resolves to /private/tmp: the session answers the canonical form.
    base = Path(temporary)
    cache = base / 'cache'
    project = copy(Path(args.project).resolve(), base / 'project')
    source = project / args.file
    opened = open_session(project, source, cache)
    url = opened['url']
    assert opened['root'] == str(project.resolve()) and opened['file'] == str(source.resolve()), opened
    print('PASS: a project under a symlinked path opens, its file answered in canonical form', flush=True)
    page = Page(url)
    try:
        page.until(lambda status: status and status[0] in ('live', 'error'), 900, 'the previews never went live')
        assert page.status[0] == 'live', page.status
        print('PASS: previews live:', page.status[1], flush=True)

        # A resource edit rebuilds the outputs behind the same class paths: the running renderer
        # is configured again, not replaced by a second Komodo process.
        strings = next(iter(sorted(project.rglob('src/main/res/values/strings.xml'))), None)
        if strings is not None:
            text = strings.read_text()
            strings.write_text(text.replace('</resources>',
                                            '    <string name="compose_harness_probe">probe</string>\n</resources>'))
            page.until(lambda status: status and status[0] in ('building', 'refreshing'), 120,
                       'a resource edit did not rebuild')
            page.until(lambda status: status and status[0] in ('live', 'error'), 600,
                       'the previews did not come back after a resource edit')
            assert page.status[0] == 'live', page.status
            logs = '\n'.join(path.read_text(errors='replace') for path in (cache / 'compose-service').glob('*.log'))
            assert 'configuring the running renderer again' in logs, logs[-4000:]
            assert logs.count('Komodo: starting') == 1, logs.count('Komodo: starting')
            print('PASS: a resource edit reconfigures the running renderer instead of starting another', flush=True)

        # A post the service rejects suspends the preview with the reason; a good post resumes it.
        outside = base / 'outside' / 'Outside.kt'
        outside.parent.mkdir()
        outside.write_text('package outside\n')
        status, answer = post(url, 'documents', {'origin': 'native', 'replace': True,
                                                 'documents': [{'file': str(outside), 'text': 'package outside\n'}]})
        assert status == 400 and 'outside the workspace' in answer.get('error', ''), (status, answer)
        page.until(lambda status: status and status[0] == 'error' and 'outside the workspace' in status[1], 60,
                   'a rejected post did not suspend the preview')
        status, answer = post(url, 'documents', {'origin': 'native', 'replace': True, 'documents': []})
        assert status == 200, (status, answer)
        page.until(lambda status: status and status[0] != 'error', 120, 'a good post did not resume the preview')
        print('PASS: a rejected documents post suspends the preview with its reason; the next post resumes it',
              flush=True)

        status, _ = post(url, 'close', {})
        assert status == 200
        status, answer = post(url, 'info')
        assert status == 410 and answer.get('ended') == 'closed', (status, answer)
        print('PASS: close ends the session', flush=True)
    finally:
        page.close()

    # A project whose manifest fails to load: the edit that fixes it loads the project.
    broken = copy(Path(args.project).resolve(), base / 'broken')
    manifest = broken / 'elide.pkl'
    good = manifest.read_text()
    manifest.write_text(good + '\nthis is not pkl\n')
    opened = open_session(broken, broken / args.file, cache)
    page = Page(opened['url'])
    try:
        page.until(lambda status: status and status[0] == 'error', 300, 'a broken manifest did not fail the load')
        manifest.write_text(good)
        page.until(lambda status: status and status[0] in ('resolving', 'building', 'runtime', 'live'), 120,
                   'fixing the manifest did not load the project again')
        print('PASS: a project that failed its first load loads once its manifest is fixed', flush=True)
        post(opened['url'], 'close', {})
    finally:
        page.close()
