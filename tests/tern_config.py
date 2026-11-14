"""An isolated Tern config directory (`TERN_CONFIG_DIR`) and session daemon for the desktop harnesses."""
import json
import shutil
from pathlib import Path


def config_dir(path):
    """Creates `path` as a Tern config directory and returns it as a string. A fresh one makes every
    new desktop window open a native modal offering to manage omp, which blocks the harness until a
    person answers it; the recorded answer keeps it closed."""
    path = Path(path)
    (path / 'omp').mkdir(parents=True, exist_ok=True)
    (path / 'omp/state.json').write_text(json.dumps({'managed': False, 'checked': 0, 'no_build': False, 'offered': True}))
    return str(path)


def daemon_command(socket):
    """The command starting a session daemon on `socket` as a window starts one: from the Tern Daemon
    helper app beside the executable where there is one. A window whose daemon runs another copy of
    Tern (the bare CLI) shows a "Restart the session daemon" banner over its top right corner, and the
    banner takes the clicks meant for the controls under it."""
    tern = Path(shutil.which('tern')).resolve()
    helper = tern.parent.parent / 'Helpers/Tern Daemon.app/Contents/MacOS/tern'
    return [str(helper if helper.exists() else tern), 'daemon', '--socket', str(socket)]
