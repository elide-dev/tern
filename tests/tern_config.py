"""An isolated Tern config directory (`TERN_CONFIG_DIR`) for the desktop harnesses."""
import json
from pathlib import Path


def config_dir(path):
    """Creates `path` as a Tern config directory and returns it as a string. A fresh one makes every
    new desktop window open a native modal offering to manage omp, which blocks the harness until a
    person answers it; the recorded answer keeps it closed."""
    path = Path(path)
    (path / 'omp').mkdir(parents=True, exist_ok=True)
    (path / 'omp/state.json').write_text(json.dumps({'managed': False, 'checked': 0, 'no_build': False, 'offered': True}))
    return str(path)
