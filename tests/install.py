"""Exercise the release installer without changing the user's Tern installation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='tern-install-') as temporary:
    root = Path(temporary).resolve()
    bundle = root / "release's λ"
    for directory in ['dist', 'sdk/lib', 'runtime/bin', 'plugin']:
        (bundle / directory).mkdir(parents=True)
    shutil.copyfile(source / 'scripts/install-release.sh', bundle / 'install.sh')
    for relative in ['runtime/bin/elide', *(f'dist/elide-tern-{name}' for name in
                     ['broker', 'worker', 'android'])]:
        path = bundle / relative
        path.write_text('#!/bin/sh\nexit 0\n')
        path.chmod(0o755)
    for relative in ['sdk/embedder.json', 'sdk/lib/libelide_embed.dylib', 'plugin/plugin.toml',
                     'plugin/syntaxes/Pkl.sublime-syntax']:
        (bundle / relative).parent.mkdir(parents=True, exist_ok=True)
        (bundle / relative).touch()
    commands = root / 'commands'
    commands.mkdir()
    uname = commands / 'uname'
    uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n')
    uname.chmod(0o755)
    tern = commands / 'tern'
    tern.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TERN_INSTALL_ARGS"\n')
    tern.chmod(0o755)
    arguments = root / 'arguments'
    syntaxes = root / 'config/syntaxes'
    environment = {**os.environ, 'PATH': str(commands) + ':/usr/bin:/bin', 'TERN_INSTALL_ARGS': str(arguments),
                   'TERN_CONFIG_DIR': str(root / 'config')}

    def run():
        return subprocess.run(['/bin/sh', str(bundle / 'install.sh')], env=environment,
                              cwd=root, capture_output=True, text=True, timeout=10)

    result = run()
    assert result.returncode == 0, result.stderr
    assert arguments.read_text().splitlines() == ['plugin', 'link', str(bundle / 'plugin')]
    grammar = syntaxes / 'Pkl.sublime-syntax'
    assert grammar.is_symlink() and grammar.resolve() == bundle / 'plugin/syntaxes/Pkl.sublime-syntax'
    grammar.unlink()
    grammar.write_text('own grammar\n')
    assert run().returncode == 0
    assert not grammar.is_symlink() and grammar.read_text() == 'own grammar\n'
    config = bundle / 'plugin/config.json'
    assert json.loads(config.read_text()) == {
        'sdk': '../sdk', 'broker': '../dist/elide-tern-broker', 'runtime': '../runtime/bin/elide'}
    config.write_text('{"custom":true}\n')
    assert run().returncode == 0
    assert config.read_text() == '{"custom":true}\n'
    arguments.unlink()
    (bundle / 'dist/elide-tern-worker').unlink()
    result = run()
    assert result.returncode != 0 and 'Incomplete release' in result.stderr
    assert not arguments.exists()
    uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo x86_64;; esac\n')
    result = run()
    assert result.returncode != 0 and 'Apple Silicon' in result.stderr
    assert not arguments.exists()
print('PASS: release paths, configuration preservation, grammar link, incomplete bundles, and platform checks')
