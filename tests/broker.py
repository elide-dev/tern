"""Behavioral IPC checks; --sdk adds real native embedding acceptance."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'dist/elide-tern-broker'


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument('--sdk')
  args = parser.parse_args()
  with tempfile.TemporaryDirectory(prefix='elide-tern-') as directory:
    state = Path(directory) / 'ipc'
    daemon = None

    def request(**body):
      result = subprocess.run([str(BINARY), 'request', str(state)], input=json.dumps(body),
                              text=True, capture_output=True, timeout=20)
      assert result.returncode == 0, result.stderr
      return json.loads(result.stdout)

    def success(**body):
      result = request(**body)
      assert result['ok'], result
      return result['result']

    try:
      with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        pings = list(pool.map(lambda _: success(op='ping'), range(6)))
      assert len({ping['pid'] for ping in pings}) == 1, pings
      daemon = pings[0]['pid']
      assert state.stat().st_mode & 0o777 == 0o700
      assert not request(op='discover', session='missing')['ok']
      assert not request(op='open', sdk=str(state))['ok']
      invalid = subprocess.run([str(BINARY), 'request', str(state)], input='{"op":"ping","unknown":1}',
                               text=True, capture_output=True)
      assert invalid.returncode != 0
      with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(str(state / 'broker.sock'))
        connection.sendall(struct.pack('<I', 4 * 1024 * 1024 + 1))
        size = struct.unpack('<I', connection.recv(4))[0]
        result = json.loads(connection.recv(size))
        assert not result['ok'], result
      insecure = Path(directory) / 'insecure'
      insecure.mkdir(mode=0o755)
      result = subprocess.run([str(BINARY), 'request', str(insecure)], input='{"op":"ping"}',
                              text=True, capture_output=True)
      assert result.returncode != 0 and '0700' in result.stderr
      if args.sdk:
        session = success(op='open', sdk=str(Path(args.sdk).resolve()))['session']
        capabilities = success(op='discover', session=session)
        print('SDK capabilities:', json.dumps(capabilities))
        kernel = success(op='open_kernel', session=session, language='js')['kernel']
        def evaluate(source):
          return success(op='evaluate', session=session, kernel=kernel, language='js', source=source)
        evaluate('var ternValue = 40;')
        assert evaluate('ternValue + 2')['value'] == '42'
        assert not request(op='evaluate', session=session, kernel=kernel, language='js',
                           source='throw new Error("expected")')['ok']
        assert evaluate('ternValue + 3')['value'] == '43'
        notebook = success(op='open_kernel', session=session, language='polyglot')['kernel']
        def cell(language, source):
          return success(op='evaluate', session=session, kernel=notebook, language=language, source=source)
        assert cell('js', 'const y = {hi: 5, nested: {items: [1, 2, 3]}};')['display'] == 'none'
        assert json.loads(cell('js', 'y')['value'])['nested']['items'] == [1, 2, 3]
        assert cell('python', 'y.hi')['value'] == '5'
        assert cell('python', 'y.hi = 9')['display'] == 'none'
        assert cell('js', 'y.hi')['value'] == '9'
        assert cell('js', 'null')['value'] == 'null'
        assert 'Circular reference' in cell('js', '(() => { const c = {}; c.self = c; return c; })()')['value']
        logged = cell('js', 'console.log("hello")')
        assert logged['display'] == 'none' and logged['stdout'] == 'hello\n'
        assert 'Accessor' in cell('js', '({get unsafe() { throw Error("getter ran"); }})')['value']
        assert cell('cel', 'y.hi == 9')['value'] == 'true'
        assert json.loads(cell('pkl', 'name = "notebook"\ncount = 6 * 7')['value'])['count'] == 42
        assert cell('js', '_.count')['value'] == '42'
        isolated = success(op='open_kernel', session=session, language='polyglot')['kernel']
        assert not request(op='evaluate', session=session, kernel=isolated, language='js', source='y.hi')['ok']
        for kind, version in [('mcp', '2024-11-05'), ('lsp', None)]:
          service_session = success(op='open', sdk=str(Path(args.sdk).resolve()))['session']
          params = {'capabilities': {}}
          if kind == 'mcp':
            params.update(protocolVersion=version, clientInfo={'name': 'elide-tern-test', 'version': '0.1'})
          response = success(op='protocol', session=service_session, kind=kind,
                             json=json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': params}))
          messages = [json.loads(m) for m in response['messages']]
          assert any(m.get('id') == 1 and 'result' in m for m in messages), messages
          success(op='close', session=service_session)
        start = time.monotonic()
        result = request(op='evaluate', session=session, kernel=kernel, language='js', source='while (true) {}')
        assert not result['ok'] and time.monotonic() - start < 15, result
        assert not request(op='discover', session=session)['ok']
        fresh = success(op='open', sdk=str(Path(args.sdk).resolve()))['session']
        assert success(op='discover', session=fresh)['languages']
        success(op='close', session=fresh)
        owned = success(op='open', sdk=str(Path(args.sdk).resolve()))['session']
        success(op='discover', session=owned)
        def processes():
          rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,stat='], text=True)
          return {int(pid): (int(parent), status) for pid, parent, status in
                  (row.split() for row in rows.splitlines())}
        workers = [pid for pid, (parent, _) in processes().items() if parent == daemon]
        assert workers, 'Expected supervised SDK worker'
        os.kill(daemon, signal.SIGKILL)
        daemon = None
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
          live = processes()
          if all(pid not in live or live[pid][1].startswith('Z') for pid in workers):
            break
          time.sleep(0.1)
        else:
          raise AssertionError('SDK workers survived broker death')
        daemon = success(op='ping')['pid']
        assert not request(op='discover', session=owned)['ok']
      print('Broker checks passed' + ('; native SDK checks passed' if args.sdk else ' (no SDK required)'))
    finally:
      if daemon:
        os.kill(daemon, signal.SIGTERM)


if __name__ == '__main__':
  main()
