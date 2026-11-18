"""Wi-Fi pairing in the Android device manager, with a fake adb and dns-sd
(tests/fixtures/android-pair/) standing in for the phone and macOS's Bonjour: the helper's `pairing`
and `pair` commands alone, then in real Tern the QR code as the window draws it (decoded from its
screenshot with CoreImage), the pairing-code prompt, the warning when Local Network privacy blinds
adb's discovery, and that no pairing helper outlives its view."""
import json
import os
import re
import queue
import shutil
import subprocess
import threading
import tempfile
import time
from pathlib import Path
from tern_config import config_dir, daemon_command

root = Path(__file__).resolve().parents[1]
out = root / '.dev/scratch/android-pair-test'
out.mkdir(parents=True, exist_ok=True)
helper = str(root / 'dist/elide-tern-android')
tern = shutil.which('tern')
assert tern, 'tern is not on PATH'
PAIRING = '_adb-tls-pairing._tcp'
CODE_DEVICE = 'adb-FAKE0002-QrStUv'
CODE_ADDRESS = '127.0.0.1:37002'
QR_ADDRESS = '127.0.0.1:37001'
CONNECT = '_adb-tls-connect._tcp'
BLIND_DEVICE = 'adb-FAKE0003-Blind'


def ps():
    return subprocess.check_output(['ps', '-axo', 'args'], text=True).splitlines()


def pairing_running():
    """A pairing helper, or the fake dns-sd browser one started, is still running."""
    return any('elide-tern-android pairing' in row or '/sdk/bin/dns-sd' in row for row in ps())


with tempfile.TemporaryDirectory(prefix='tap-', dir='/tmp') as temporary:
    state = Path(temporary)
    sdk = state / 'sdk'
    (sdk / 'platform-tools').mkdir(parents=True)
    (sdk / 'emulator').mkdir()
    shutil.copy(root / 'tests/fixtures/android-pair/adb', sdk / 'platform-tools/adb')
    (sdk / 'platform-tools/adb').chmod(0o755)
    (sdk / 'emulator/emulator').write_text('#!/bin/sh\nexit 0\n')
    (sdk / 'emulator/emulator').chmod(0o755)
    # The fake dns-sd comes first on PATH, for the helper here and for the one Tern starts.
    (sdk / 'bin').mkdir()
    shutil.copy(root / 'tests/fixtures/android-pair/dns-sd', sdk / 'bin/dns-sd')
    (sdk / 'bin/dns-sd').chmod(0o755)
    os.environ['PATH'] = str(sdk / 'bin') + os.pathsep + os.environ['PATH']
    adb_state = sdk / 'state.json'
    adb_log = sdk / 'log.jsonl'

    def read_state():
        return json.loads(adb_state.read_text()) if adb_state.exists() else {}

    def write_state(value):
        temporary_file = sdk / '.state-harness'
        temporary_file.write_text(json.dumps(value))
        os.replace(temporary_file, adb_state)

    def reset_state():
        adb_state.unlink(missing_ok=True)
        adb_log.unlink(missing_ok=True)

    def helper_run(*arguments):
        result = subprocess.run([helper, *arguments, '--json', '--sdk', str(sdk)], capture_output=True, text=True,
                                timeout=60)
        return result.returncode, json.loads(result.stdout.strip().splitlines()[-1])

    # 1. The helper alone.
    write_state({'mdns': 'ERROR: mdns daemon unavailable'})
    status, value = helper_run('pairing')
    assert status == 1 and 'mDNS is unavailable' in value.get('error', ''), (status, value)
    reset_state()

    def start_pairing():
        process = subprocess.Popen([helper, 'pairing', '--json', '--sdk', str(sdk)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        events = queue.Queue()
        threading.Thread(target=lambda: [events.put(json.loads(line)) for line in process.stdout], daemon=True).start()

        def next_event(predicate, seconds):
            deadline = time.monotonic() + seconds
            while (left := deadline - time.monotonic()) > 0:
                try:
                    event = events.get(timeout=left)
                except queue.Empty:
                    break
                if predicate(event):
                    return event
            return None
        return process, next_event

    def discovery(event):
        return event['event'] == 'discovery'

    pairing, next_event = start_pairing()
    try:
        ready = next_event(lambda event: True, 10)
        assert ready and ready['event'] == 'ready' and re.fullmatch(r'elide-[A-Za-z0-9]{10}', ready['service']), ready
        assert len(ready['qr']) == 29 and all(re.fullmatch(r'[01]{29}', row) for row in ready['qr']), ready
        # A connected device's service, which adb stops listing, is no sign of blind discovery.
        write_state({'bonjour': [{'name': BLIND_DEVICE, 'type': CONNECT}]})
        assert next_event(discovery, 8) is None, 'a warning for a connect service only Bonjour sees'
        # A device waiting to pair that Bonjour sees and adb does not: Local Network privacy blinds adb.
        write_state({'bonjour': [{'name': BLIND_DEVICE, 'type': PAIRING}]})
        blocked = next_event(discovery, 15)
        assert blocked and blocked['blocked'] and 'Local Network' in blocked['message'], blocked
        write_state({'bonjour': [{'name': BLIND_DEVICE, 'type': PAIRING}],
                     'services': [{'name': BLIND_DEVICE, 'type': PAIRING, 'address': '127.0.0.1:37003'}]})
        cleared = next_event(discovery, 5)
        assert cleared and not cleared['blocked'], cleared
        pairing.stdin.close()
        assert pairing.wait(timeout=5) == 0, 'pairing did not end when its stdin closed'
    finally:
        if pairing.poll() is None:
            pairing.kill()
    # Tern ends the helper with SIGTERM while its stdin is still open; its dns-sd ends with it.
    pairing, next_event = start_pairing()
    try:
        assert next_event(lambda event: event['event'] == 'ready', 10)
        time.sleep(1)
        assert pairing_running()
        pairing.terminate()
        pairing.wait(timeout=5)
        time.sleep(.5)
        assert not pairing_running(), 'dns-sd outlived the pairing helper'
    finally:
        if pairing.poll() is None:
            pairing.kill()
    reset_state()
    write_state({'services': [{'name': CODE_DEVICE, 'type': PAIRING, 'address': CODE_ADDRESS}],
                 'secrets': {CODE_ADDRESS: '123456'}})
    status, value = helper_run('pair', '--address', CODE_ADDRESS, '--code', '000000')
    assert status == 1 and 'Wrong password' in value.get('error', ''), (status, value)
    status, value = helper_run('pair', '--address', CODE_ADDRESS, '--code', '123456')
    assert status == 0 and value.get('serial') == CODE_DEVICE + '._adb-tls-connect._tcp' \
        and value.get('name') == 'Google Pixel 8', (status, value)
    status, value = helper_run('pair', '--address', CODE_ADDRESS, '--code', '12345')
    assert status == 1 and 'six digits' in value.get('error', ''), (status, value)
    reset_state()

    # 2. In a real Tern window.
    package = state / 'crates/plugins/fixtures/elide'
    shutil.copytree(root / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    (package / 'config.json').write_text(json.dumps({'broker': str(root / 'dist/elide-tern-broker'), 'runtime': 'elide',
                                                      'android': helper, 'android_sdk': str(sdk)}))
    fixture_root = state / 'crates/tern'
    (fixture_root / 'goldens').mkdir(parents=True)
    socket = state / 'control.sock'
    environment = {**os.environ, 'STENCIL_FIXTURE_ROOT': str(fixture_root),
                   'TERN_DAEMON_SOCKET': str(state / 'daemon.sock'), 'TERN_CONFIG_DIR': config_dir(state / 'config')}
    with (out / 'tern.log').open('w') as log:
        subprocess.run([tern, 'plugin', 'link', str(package)], env=environment, check=True, stdout=log, stderr=log)
        daemon = subprocess.Popen(daemon_command(state / 'daemon.sock'), env=environment, stdout=log, stderr=log)
        server = subprocess.Popen([tern, '--control', str(socket), '--out', str(out), '--dir', str(state)],
                                  env=environment, stdout=log, stderr=log)

        def ctl(command, *values):
            result = subprocess.run([tern, 'ctl', '--control', str(socket), command,
                                     *(str(v) if command == 'tree' else json.dumps(str(v), ensure_ascii=False)
                                       for v in values)], capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply

        def nodes(selector):
            return ctl('tree', selector).get('nodes') or []

        def wait(predicate, seconds=30, what='Tern did not settle'):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                result = predicate()
                if result:
                    return result
                time.sleep(.2)
            (out / 'failed-state.json').write_text(json.dumps(ctl('state'), indent=2, ensure_ascii=False))
            raise AssertionError(what + '; see ' + str(out))

        def names(text):
            return [node for node in nodes('[data-role="android-device-name"]') if node.get('text') == text]

        def open_pairing():
            ctl('click', '[data-role="android-pair"]')
            wait(lambda: nodes('[data-role="android-qr"]'), what='the pairing view showed no QR code')

        try:
            wait(socket.exists)
            wait(lambda: (ctl('state').get('focused') or {}).get('prompt'), what='no shell started')
            ctl('plugins', 'run', 'plugin.elide.android')
            wait(lambda: nodes('[data-role="android-pair"]'), what='the device manager has no Wi-Fi button')
            open_pairing()
            # Pairing code: the device appears while it advertises, the prompt takes its code.
            write_state({'services': [{'name': CODE_DEVICE, 'type': PAIRING, 'address': CODE_ADDRESS}],
                         'secrets': {CODE_ADDRESS: '123456'}})
            wait(lambda: names(CODE_DEVICE), what='the device showing a pairing code is not listed')
            ctl('click', '[data-role="android-paircode-1"]')
            time.sleep(.5)
            ctl('type', '123456')
            ctl('key', 'Enter')
            wait(lambda: names('Google Pixel 8'), what='the device paired by code is not in the device list')
            # QR code: the window's own drawing decodes to the Wireless debugging payload.
            open_pairing()
            time.sleep(1)
            ctl('shot', 'android-pair')
            shot = max(out.glob('**/android-pair*.png'), key=lambda path: path.stat().st_mtime)
            decoded = subprocess.run(['swift', str(root / 'tests/fixtures/decode-qr.swift'), str(shot)],
                                     capture_output=True, text=True, timeout=300)
            assert decoded.returncode == 0, decoded.stderr
            match = re.fullmatch(r'WIFI:T:ADB;S:(elide-[A-Za-z0-9]{10});P:([A-Za-z0-9]{12});;', decoded.stdout.strip())
            assert match, 'the QR code in ' + str(shot) + ' decoded to ' + repr(decoded.stdout)
            service, password = match.groups()
            current = read_state()
            current['services'] = [{'name': service, 'type': PAIRING + '.', 'address': QR_ADDRESS}]
            current['secrets'] = {QR_ADDRESS: password}
            write_state(current)
            wait(lambda: len(names('Google Pixel 8')) == 2, what='the device that scanned the code is not listed')
            logged = [json.loads(line) for line in adb_log.read_text().splitlines()]
            assert ['pair', QR_ADDRESS, password] in logged, 'adb pair did not use the QR password'
            wait(lambda: not pairing_running(), 5, 'the pairing helper outlived its connected device')
            # Blind adb discovery: the view says how to fix it, and stops once adb sees the device.
            open_pairing()
            blocked = '[data-role="android-pair-blocked"]'
            time.sleep(6)
            assert not nodes(blocked), 'a warning without a device only Bonjour sees'
            current = read_state()
            current['bonjour'] = [{'name': BLIND_DEVICE, 'type': PAIRING}]
            write_state(current)
            warning = wait(lambda: nodes(blocked), 15, 'no warning when Bonjour sees a device adb does not')
            assert 'Local Network' in warning[0].get('text', ''), warning
            ctl('shot', 'android-pair-blocked')
            current = read_state()
            current['services'] = [{'name': BLIND_DEVICE, 'type': PAIRING, 'address': '127.0.0.1:37003'}]
            write_state(current)
            wait(lambda: not nodes(blocked), 10, 'the warning stayed once adb saw the device')
            # Leaving the view ends its helper.
            ctl('click', '[data-role="android-pair-back"]')
            wait(lambda: not pairing_running(), 5, 'the pairing helper outlived its view')
            wait(lambda: nodes('[data-role="android-pair"]'), what='Back did not return to the device list')
            print('PASS: helper pairing/pair, QR code decoded from the window and paired with its password, '
                  'pairing code through the prompt, blind-discovery warning, no helper outlives its view', flush=True)
            print('Shot:', shot)
        finally:
            for process in [server, daemon]:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
