"""Exercise the release packer and installer without changing the user's Tern installation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

source = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_release', source / 'scripts/package-release.py')
package_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_release)
with tempfile.TemporaryDirectory(prefix='tern-install-') as temporary:
    root = Path(temporary).resolve()
    # A runtime, an SDK and helpers small enough to pack here.
    inputs = root / 'inputs'
    for relative in ['runtime/bin/elide', *(f'dist/elide-tern-{name}' for name in
                     ['broker', 'worker', 'android'])]:
        path = inputs / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\nexit 0\n')
        path.chmod(0o755)
    (inputs / 'runtime/lib').mkdir()
    (inputs / 'runtime/lib/current').symlink_to('.')
    (inputs / 'sdk/lib').mkdir(parents=True)
    (inputs / 'sdk/lib/libelide_embed.dylib').touch()
    (inputs / 'sdk/embedder.json').write_text('{"abi": {"major": 1, "minor": 1}}')
    out = root / 'out'
    archive = package_release.package(inputs / 'runtime', inputs / 'sdk', out, 'f' * 40, inputs / 'dist')
    # The archive is what SHA256SUMS lists, and packing again gives the same bytes.
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert (out / 'SHA256SUMS').read_text() == f'{digest}  {archive.name}\n'
    again = package_release.package(inputs / 'runtime', inputs / 'sdk', root / 'again', 'f' * 40,
                                    inputs / 'dist')
    assert again.read_bytes() == archive.read_bytes(), 'the archive is not reproducible'
    # Unpacked where a user would put it (a quote and a non-ASCII name in the path).
    place = root / "release's λ"
    with tarfile.open(archive) as tar:
        tar.extractall(place, filter='tar')
    bundle = place / archive.name.removesuffix('.tar.gz')
    release = json.loads((bundle / 'release.json').read_text())
    assert release['platform'] == 'macos-arm64' and release['runtime_revision'] == 'f' * 40, release
    assert release['sdk_abi'] == {'major': 1, 'minor': 1}, release
    assert (bundle / 'runtime/lib/current').is_symlink(), 'runtime symlinks are kept'
    assert not (bundle / 'plugin/config.json').exists(), 'a local config.json is never packed'
    assert (bundle / 'INSTALL.md').read_text() == (source / 'docs/manual-install.md').read_text()
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
print('PASS: reproducible packed release with SHA256SUMS, release paths, configuration preservation, grammar link, incomplete bundles, and platform checks')
