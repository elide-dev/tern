"""Real Android SDK lifecycle regression; only uniquely named, temporary AVDs are changed."""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
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


def call(command, *options, succeeds=True, timeout=180):
    result = subprocess.run([str(helper), command, '--json', *common, *options],
                            env=environment, capture_output=True, text=True, timeout=timeout)
    value = json.loads(result.stdout)
    assert (result.returncode == 0) == succeeds, (command, value, result.stderr)
    return value


def display_check(serial):
    """Plays a kitty-graphics terminal over a pty: one frame must arrive and the exit must restore the screen."""
    # Tern itself gets cell mouse reports; this terminal offers pixel reports.
    display_environment = {key: value for key, value in environment.items() if key != 'TERM_PROGRAM'}
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 60, 0, 0))
    process = subprocess.Popen([str(helper), 'display', '--serial', serial, '--name', name], stdin=slave,
                               stdout=slave, stderr=slave, env=display_environment, start_new_session=True)
    os.close(slave)
    buffer = b''
    deadline = time.monotonic() + 90

    def read_until(found):
        nonlocal buffer
        while not found():
            assert time.monotonic() < deadline, buffer[-2000:]
            if select.select([master], [], [], 0.2)[0]:
                try:
                    buffer += os.read(master, 1 << 20)
                except OSError:
                    return
    try:
        read_until(lambda: b'\x1b[c' in buffer)
        # Graphics, pixel mouse, kitty keyboard, 10x20 px cells, 600x800 px window, DA1.
        os.write(master, b'\x1b_Gi=31;OK\x1b\\' + b'\x1b[?1016;2$y' + b'\x1b[?0u' + b'\x1b[6;20;10t'
                 + b'\x1b[4;800;600t' + b'\x1b[?62;c')
        frame = rb'\x1b_Ga=T,f=24,s=(\d+),v=(\d+),i=1,[^;]*t=f;([A-Za-z0-9+/=]+)\x1b\\'
        read_until(lambda: re.search(frame, buffer))
        width, height, encoded = re.search(frame, buffer).groups()
        width, height = int(width), int(height)
        # The frame fills at most the 60x39-cell area above the toolbar row.
        assert 0 < width <= 600 and 0 < height <= 780, (width, height)
        assert os.path.getsize(base64.b64decode(encoded)) == width * height * 3
        os.write(master, b'\x1b_Gi=1;OK\x1b\\')
        assert b'\x1b[?1016h' in buffer and b'\x1b[>25u' in buffer, buffer[-2000:]
        process.send_signal(signal.SIGHUP)
        # Keep reading: the exit restores the terminal, and an unread pty would stall that output.
        read_until(lambda: process.poll() is not None)
        assert process.wait(10) == 0
        assert b'\x1b[?1049l' in buffer, buffer[-2000:]
    finally:
        if process.poll() is None:
            process.kill()
        os.close(master)
    result = subprocess.run([str(helper), 'display', '--serial', serial], env=environment,
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    assert result.returncode == 1 and 'interactive terminal' in result.stderr, result
    for removed in (['view', '--serial', serial], ['start', '--name', name, '--headless']):
        assert subprocess.run([str(helper), *removed], env=environment, capture_output=True,
                              timeout=30).returncode == 1, removed


try:
    call('create', '--name', name, '--image', args.image, '--device', args.device)
    call('create', '--name', name, '--image', args.image, '--device', args.device, succeeds=False)
    assert (home / (name + '.ini')).is_file()
    # Without a keyboard device the emulator drops every key event, Back and Home included.
    assert re.search(r'^hw\.keyboard\s*=\s*yes$', (home / (name + '.avd') / 'config.ini').read_text(), re.M)
    for iteration in range(2):
        started = call('start', '--name', name)
        serial = started['serial']
        assert call('wait', '--name', name, timeout=300)['serial'] == serial
        assert call('wait', '--serial', serial)['serial'] == serial
        call('wait', '--serial', 'emulator-1', succeeds=False)
        call('wait', '--name', name, '--serial', serial, succeeds=False)
        call('delete', '--name', name, '--yes', succeeds=False)
        call('stop', '--name', name + '-different', '--serial', serial, succeeds=False)
        snapshot = call('list')
        assert any(avd.get('serial') == serial and avd['name'] == name and avd.get('embeddable') is True
                   for avd in snapshot['avds']), snapshot
        if iteration == 0:
            display_check(serial)
        call('stop', '--name', name, '--serial', serial)
        # Preserve the advisory file across both restart and delete, even on SDK versions
        # that remove it themselves. It is not an active emulator lock.
        (home / (name + '.avd') / 'multiinstance.lock').touch(exist_ok=True)
    call('delete', '--name', name, succeeds=False)
    assert (home / (name + '.ini')).is_file()
    call('delete', '--name', name, '--yes')
    assert not (home / (name + '.ini')).exists()
    assert not (home / (name + '.avd')).exists()
    print('PASS: real SDK create with keyboard input, overwrite protection, targeted stop, restart, embedded display '
          'frames and terminal restore, and confirmed deletion')
finally:
    # On cleanup failure retain the directory for diagnosis; never unlink a running AVD.
    snapshot = call('list')
    for avd in snapshot['avds']:
        if avd['name'] == name and avd.get('serial'):
            call('stop', '--name', name, '--serial', avd['serial'])
    if (home / (name + '.ini')).exists():
        call('delete', '--name', name, '--yes')
    shutil.rmtree(temporary)
