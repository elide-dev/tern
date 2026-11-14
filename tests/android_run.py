"""An Elide run in an Android project, in real Tern with the Elide plugin: new shells name the
plugin's helper as Elide's emulator launcher, so the emulator starts without a window and the helper
announces the start; the plugin opens that device's pane beside the terminal, even though the run
goes through a wrapper script no command-line match would recognize."""
import argparse
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from tern_config import config_dir, daemon_command

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True)
parser.add_argument('--project', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = root / '.dev/scratch/android-run-test'
out.mkdir(parents=True, exist_ok=True)
runtime = str(Path(args.runtime).resolve())
project = Path(args.project).resolve()
helper = str(root / 'dist/elide-tern-android')
tern = shutil.which('tern')
assert tern, 'tern is not on PATH'


def helper_json(*arguments):
    result = subprocess.run([helper, *arguments, '--json'], capture_output=True, text=True, timeout=300)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def ps():
    return subprocess.check_output(['ps', '-axo', 'args'], text=True).splitlines()


listed = helper_json('list', '--root', str(project), '--runtime', runtime)
avd = listed['project']['avd']
if any(entry['name'] == avd and entry.get('serial') for entry in listed.get('avds', [])):
    subprocess.run([helper, 'stop', '--name', avd], check=True, timeout=120)

with tempfile.TemporaryDirectory(prefix='tar-', dir='/tmp') as temporary:
    state = Path(temporary)
    package = state / 'crates/plugins/fixtures/elide'
    shutil.copytree(root / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    (package / 'config.json').write_text(json.dumps({'broker': str(root / 'dist/elide-tern-broker'),
                                                      'runtime': runtime, 'android': helper}))
    fixture_root = state / 'crates/tern'
    (fixture_root / 'goldens').mkdir(parents=True)
    socket = state / 'control.sock'
    environment = {**os.environ, 'STENCIL_FIXTURE_ROOT': str(fixture_root),
                   'TERN_DAEMON_SOCKET': str(state / 'daemon.sock'), 'TERN_CONFIG_DIR': config_dir(state / 'config')}
    with (out / 'tern.log').open('w') as log:
        subprocess.run([tern, 'plugin', 'link', str(package)], env=environment, check=True, stdout=log, stderr=log)
        daemon = subprocess.Popen(daemon_command(state / 'daemon.sock'), env=environment,
                                  stdout=log, stderr=log)
        # A window, not `tern serve`: serve runs its shells itself, without the daemon, and the
        # `spawn` hook that names the launcher runs only for the daemon's shells.
        server = subprocess.Popen([tern, '--control', str(socket), '--out', str(out), '--dir', str(project)],
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

        def lua(expression):
            marker = 'android-run-' + str(uuid.uuid4()) + ':'
            ctl('carly', 'lua', 'print(' + json.dumps(marker) + '..tern.json.encode(' + expression + '))')

            def completed():
                value = ctl('state').get('carly', {}).get('last_tool')
                if value and value.get('error'):
                    raise AssertionError(value)
                return value if value and marker in value.get('text', '') else None
            result = wait(completed)
            line = next(line for line in result['text'].splitlines() if line.startswith(marker))
            ctl('carly', 'close')
            return json.loads(line[len(marker):])

        try:
            wait(socket.exists)
            # The window's first shell takes a moment to reach its prompt.
            wait(lambda: (ctl('state').get('focused') or {}).get('prompt'), what='no shell started')
            # 1. A new shell names the helper as Elide's emulator launcher.
            launcher = state / 'launcher'
            ctl('run', 'printenv ELIDE_ANDROID_EMULATOR_LAUNCHER > ' + shlex.quote(str(launcher)))
            wait(lambda: launcher.exists() and launcher.read_text().strip(), what='printenv wrote nothing')
            named_launcher = json.loads(launcher.read_text())
            assert named_launcher[:4] == [helper, 'start', '--held', '--announce'] and named_launcher[5:] == ['--name'] \
                and named_launcher[4].endswith('/android/started'), named_launcher
            # 2. A run through a wrapper boots the emulator through it and its Run block names the device.
            terminal = lua('cx.session:focused()')
            wrapper = state / 'run.sh'
            wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([runtime, 'run']) + '\n')
            wrapper.chmod(0o755)
            ctl('run', shlex.quote(str(wrapper)))
            prefix = avd + ' · emulator-'

            def named():
                return next((node['text'] for node in nodes('[data-role="run-device"]')
                             if node.get('text', '').startswith(prefix)), None)
            serial = wait(named, 600, 'the Run block named no device').removeprefix(avd + ' · ')
            # 3. The device pane shows it; the emulator has no window and offers its display.
            def display():
                return any('elide-tern-android display' in row and '--serial ' + serial in row for row in ps())
            wait(display, 120, 'no device pane for ' + serial)
            emulator = next(row for row in ps() if 'qemu-system' in row and '-avd ' + avd in row)
            assert '-no-window' in emulator and '-grpc-use-token' in emulator, emulator
            # 4. The device pane took focus, beside the Run block; its display titles it after the
            # device once it shows the screen.
            device = lua('cx.session:focused()')
            assert device != terminal
            wait(lambda: lua('cx.session:pane(' + str(device) + ').title') == avd + ' · ' + serial, 120,
                 'the device pane did not show ' + serial)
            time.sleep(5)
            shot = ctl('shot', 'android-run')
            # 5. Ctrl-C in the terminal stops the run.
            lua('cx.layout:focus(' + str(terminal) + ')')
            ctl('key', 'ctrl+c')
            wait(lambda: not any('--progress=json' in row and runtime in row for row in ps()), 60,
                 'the run did not stop')
            wait(lambda: any('Stopped' in node.get('text', '') for node in nodes('[data-role="run-status"]')), 30,
                 'the Run block did not say Stopped')
            print('PASS: launcher named in new shells, emulator without a window, device on the run page, '
                  'device pane opened', flush=True)
            print('Shot:', shot.get('path') or out)
        finally:
            for process in [server, daemon]:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            subprocess.run([helper, 'stop', '--name', avd], timeout=120)
