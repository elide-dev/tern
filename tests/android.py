"""Real Android SDK lifecycle regression; only uniquely named, temporary AVDs are changed."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--sdk', help='Android SDK override (otherwise normal SDK discovery)')
parser.add_argument('--image', required=True, help='Installed system-images;android-API;VARIANT;ABI package')
parser.add_argument('--device', default='pixel_2', help='Installed hardware profile ID')
args = parser.parse_args()
helper = root / 'dist/elide-tern-android'
name = 'tern-regression-' + uuid.uuid4().hex
temporary = Path(tempfile.mkdtemp(prefix='tern-android-'))
home = temporary / 'avds'
home.mkdir()
environment = {**os.environ, 'ANDROID_AVD_HOME': str(home)}
common = ['--sdk', args.sdk] if args.sdk else []


def call(command, *options, succeeds=True):
    result = subprocess.run([str(helper), command, '--json', *common, *options],
                            env=environment, capture_output=True, text=True, timeout=180)
    value = json.loads(result.stdout)
    assert (result.returncode == 0) == succeeds, (command, value, result.stderr)
    return value


try:
    call('create', '--name', name, '--image', args.image, '--device', args.device)
    call('create', '--name', name, '--image', args.image, '--device', args.device, succeeds=False)
    assert (home / (name + '.ini')).is_file()
    for _ in range(2):
        started = call('start', '--name', name, '--headless')
        serial = started['serial']
        call('delete', '--name', name, '--yes', succeeds=False)
        call('stop', '--name', name + '-different', '--serial', serial, succeeds=False)
        snapshot = call('list')
        assert any(avd.get('serial') == serial and avd['name'] == name for avd in snapshot['avds'])
        call('stop', '--name', name, '--serial', serial)
        # Preserve the advisory file across both restart and delete, even on SDK versions
        # that remove it themselves. It is not an active emulator lock.
        (home / (name + '.avd') / 'multiinstance.lock').touch(exist_ok=True)
    call('delete', '--name', name, succeeds=False)
    assert (home / (name + '.ini')).is_file()
    call('delete', '--name', name, '--yes')
    assert not (home / (name + '.ini')).exists()
    assert not (home / (name + '.avd')).exists()
    print('PASS: real SDK create, overwrite protection, targeted stop, restart, and confirmed deletion')
finally:
    # On cleanup failure retain the directory for diagnosis; never unlink a running AVD.
    snapshot = call('list')
    for avd in snapshot['avds']:
        if avd['name'] == name and avd.get('serial'):
            call('stop', '--name', name, '--serial', avd['serial'])
    if (home / (name + '.ini')).exists():
        call('delete', '--name', name, '--yes')
    shutil.rmtree(temporary)
