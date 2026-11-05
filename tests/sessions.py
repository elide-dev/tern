"""Two native Tern clients observing one leased project/test session."""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--runtime')
args = parser.parse_args()
out = ROOT / '.dev/scratch/session-test'
out.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='ts-', dir='/tmp') as temporary:
    base = Path(temporary)
    project = base / "Project's λ"
    project.mkdir()
    (project / 'elide.pkl').write_text('amends "elide:project.pkl"\nname = "sessions"\n')
    if args.runtime:
        runtime = Path(args.runtime).resolve()
        (project / 'shared.test.mjs').write_text('import {test} from "node:test"; test("shared session", async () => { await new Promise(resolve => setTimeout(resolve, 5000)); });')
    else:
        runtime = base / 'runtime'
        runtime.write_text('#!/bin/sh\nprintf x >> launches\nprintf "TAP version 13\\n"\nsleep 5\nprintf "ok 1 - shared session\\n1..1\\n"\n')
        runtime.chmod(0o700)
    broker = ROOT / 'dist/elide-tern-broker'
    state = base / 'host'
    def request(**body):
        result = subprocess.run([str(broker), 'request', str(state)], input=json.dumps(body), capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    def success(**body):
        response = request(**body)
        assert response['ok'], response
        return response['result']
    daemon = success(op='ping')['pid']
    binding = success(op='project_attach', root=str(project), runtime=str(runtime))
    alias = base / 'alias'
    alias.symlink_to(project, target_is_directory=True)
    other = success(op='project_attach', root=str(alias), runtime=str(runtime))
    assert other['session'] == binding['session'] and other['lease'] != binding['lease']
    success(op='project_detach', binding=other)
    assert not request(op='project_snapshot', binding=other)['ok']
    stale = {**binding, 'epoch': 'old'}
    assert not request(op='project_snapshot', binding=stale)['ok']
    assert not request(op='project_test', binding=binding, command=str(uuid.uuid4()), subject=str(base))['ok']
    servers = []
    logs = []
    def ctl(index, command, *words):
        result = subprocess.run(['tern', 'ctl', '--control', str(base / f'{index}.sock'), command,
            *(str(word) if command == 'tree' else json.dumps(str(word), ensure_ascii=False) for word in words)], capture_output=True, text=True, timeout=20)
        reply = json.loads(result.stdout)
        assert reply.get('ok'), reply
        return reply
    def tree(index, selector):
        return json.dumps(ctl(index, 'tree', selector), ensure_ascii=False)
    def wait(predicate):
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.1)
        raise AssertionError('Timed out waiting for project session')
    launch = shlex.join([str(ROOT / 'dist/elide-tern-project'), str(broker), str(state), str(runtime), str(project)])
    try:
        for index in range(2):
            log = (out / f'tern-{index}.log').open('w')
            logs.append(log)
            servers.append(subprocess.Popen(['tern', 'serve', '--control', str(base / f'{index}.sock'), '--out', str(out / f'view-{index}')], stdout=log, stderr=log))
            wait(lambda: (base / f'{index}.sock').exists())
            ctl(index, 'run', launch)
            wait(lambda: 'No runs' in tree(index, '[data-role="run-status"]'))
        snapshot = success(op='project_snapshot', binding=binding)
        assert snapshot['attachments'] == 3, snapshot['attachments']
        assert success(op='project_snapshot', binding=binding, after=snapshot['revision']) is None
        command = str(uuid.uuid4())
        run = success(op='project_test', binding=binding, command=command, subject=str(project))['run']
        assert success(op='project_test', binding=binding, command=command, subject=str(alias))['run'] == run
        assert not request(op='project_test', binding=binding, command=str(uuid.uuid4()), subject=str(project))['ok']
        for index in range(2):
            wait(lambda: 'Running' in tree(index, '[data-role="run-status"]'))
        ctl(0, 'key', 'ctrl+c')
        wait(lambda: not ctl(0, 'tree', '.sf-dock').get('nodes'))
        snapshot = success(op='project_snapshot', binding=binding)
        assert snapshot['runs'][0]['running'], 'Closing a view stopped the project run'
        wait(lambda: 'Passed' in tree(1, '[data-role="run-status"]'))
        snapshot = success(op='project_snapshot', binding=binding)
        assert snapshot['runs'][0]['result']['passed'] == 1
        assert Path(snapshot['runs'][0]['report']).is_file()
        assert success(op='project_test', binding=binding, command=command, subject=str(project))['run'] == run
        if not args.runtime: assert (project / 'launches').read_text() == 'x'
        ctl(0, 'run', launch)
        wait(lambda: 'Passed' in tree(0, '[data-role="run-status"]'))
        assert len(success(op='project_snapshot', binding=binding)['runs']) == 1
        ctl(1, 'shot', 'project-shared-results')
        ctl(1, 'click', '[data-role="test-rerun"]')
        wait(lambda: 'Running' in tree(1, '[data-role="run-status"]'))
        ctl(1, 'click', '[data-role="test-cancel"]')
        wait(lambda: 'Cancelled' in tree(1, '[data-role="run-status"]'))
        assert len(success(op='project_snapshot', binding=binding)['runs']) == 2
        ctl(1, 'shot', 'project-run-history')
        print('PASS: shared identities, isolated leases, bounded snapshots, real Tern views, detach/reconnect, deduplication, rerun and cancellation' + (' with native Elide' if args.runtime else ''))
    finally:
        for server in servers:
            server.terminate()
            try: server.wait(timeout=5)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
        try:
            for run in success(op='project_snapshot', binding=binding)['runs']:
                if run['running']: success(op='project_cancel', binding=binding, run=run['id'])
        finally:
            os.kill(daemon, signal.SIGTERM)
        for log in logs: log.close()
