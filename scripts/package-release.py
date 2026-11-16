#!/usr/bin/env python3
"""Packs the macOS preview release that docs/manual-install.md describes: one directory with
install.sh, INSTALL.md, release.json, plugin/, dist/ (broker, worker, Android helper), runtime/
and sdk/, as elide-tern-<version>-macos-arm64.tar.gz beside a SHA256SUMS that lists it.

  scripts/package-release.py --runtime DIR --sdk DIR --out DIR [--runtime-revision REV]

`--runtime` is an Elide distribution (bin/elide inside), `--sdk` the embedded SDK
(embedder.json, lib/libelide_embed.dylib). Build dist/ first (`make build`). The archive is
reproducible: sorted entries, owner 0, mtime SOURCE_DATE_EPOCH (else 0).
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

SOURCE = Path(__file__).resolve().parents[1]
PLATFORM = 'macos-arm64'
HELPERS = ['broker', 'worker', 'android']


def version():
    manifest = (SOURCE / 'plugin/plugin.toml').read_text()
    match = re.search(r'^version = "([^"\n]+)"$', manifest, re.MULTILINE)
    if not match:
        raise SystemExit('plugin/plugin.toml has no version')
    return match[1]


def revision():
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=SOURCE, check=True,
                          capture_output=True, text=True).stdout.strip()


def require(condition, message):
    if not condition:
        raise SystemExit(f'Incomplete release: {message}')


def plugin_files(stage):
    """The plugin as the repository has it, less its local config.json and dotfiles."""
    root = SOURCE / 'plugin'
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if relative.as_posix() == 'config.json' or any(part.startswith('.') for part in relative.parts):
            continue
        if path.is_symlink():
            raise SystemExit(f'Plugin symlink: {path}')
        if path.is_file():
            target = stage / 'plugin' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)


def package(runtime, sdk, out, runtime_revision, dist=SOURCE / 'dist'):
    name = f'elide-tern-{version()}-{PLATFORM}'
    stage = out / name
    archive = out / f'{name}.tar.gz'
    if stage.exists() or archive.exists():
        raise SystemExit(f'{stage} or {archive} exists')
    require((runtime / 'bin/elide').is_file() and os.access(runtime / 'bin/elide', os.X_OK),
            f'{runtime}/bin/elide is not an executable')
    require((sdk / 'embedder.json').is_file() and (sdk / 'lib/libelide_embed.dylib').is_file(),
            f'{sdk} lacks embedder.json or lib/libelide_embed.dylib')
    for helper in HELPERS:
        path = dist / f'elide-tern-{helper}'
        require(path.is_file() and os.access(path, os.X_OK), f'{path} is missing; run make build')
    stage.mkdir(parents=True)
    plugin_files(stage)
    (stage / 'dist').mkdir()
    for helper in HELPERS:
        for suffix in ['', '.LICENSE']:
            path = dist / f'elide-tern-{helper}{suffix}'
            if path.is_file():
                shutil.copy2(path, stage / 'dist' / path.name)
    shutil.copytree(runtime, stage / 'runtime', symlinks=True)
    shutil.copytree(sdk, stage / 'sdk', symlinks=True)
    shutil.copy2(SOURCE / 'scripts/install-release.sh', stage / 'install.sh')
    (stage / 'install.sh').chmod(0o755)
    shutil.copy2(SOURCE / 'docs/manual-install.md', stage / 'INSTALL.md')
    embedder = json.loads((sdk / 'embedder.json').read_text())
    release = {
        'version': version(),
        'platform': PLATFORM,
        'plugin_revision': revision(),
        'runtime_revision': runtime_revision,
        'sdk_abi': embedder.get('abi'),
        'preview': '-preview' in version(),
        'surface_host': 'elide tern',
    }
    (stage / 'release.json').write_text(json.dumps(release, indent=2) + '\n')
    mtime = int(os.environ.get('SOURCE_DATE_EPOCH', '0'))

    def normalized(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ''
        info.mtime = mtime
        return info

    # The gzip header carries a time too.
    with archive.open('wb') as raw, \
            gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=mtime) as zipped, \
            tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as tar:
        tar.add(stage, arcname=name, recursive=False, filter=normalized)
        for path in sorted(stage.rglob('*')):
            tar.add(path, arcname=f'{name}/{path.relative_to(stage).as_posix()}',
                    recursive=False, filter=normalized)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--runtime-revision', default='unknown')
    parser.add_argument('--dist', type=Path, default=SOURCE / 'dist')
    arguments = parser.parse_args()
    print(package(arguments.runtime.resolve(), arguments.sdk.resolve(), arguments.out.resolve(),
                  arguments.runtime_revision, arguments.dist.resolve()))
