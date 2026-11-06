"""Browse `elide help` as a native Tern page: landing page, nav, search, back, themes.

Runs the dev host `dist/elide-tern-help` (`make help ELIDE_SOURCE=<elide>`) in a
headless Tern, and checks that `elide help --format markdown` into a file never
carries Tern protocol bytes.
"""
import argparse
import json
import shlex
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = root / '.dev/scratch/help-test'
out.mkdir(parents=True, exist_ok=True)
runtime = str(Path(args.runtime).resolve())
host = root / 'dist/elide-tern-help'
assert host.exists(), f'{host} is missing: run make help ELIDE_SOURCE=<elide checkout>'
tern = shutil.which('tern')

# Redirected output is Markdown and nothing else: no Tern probe, no surface bytes.
markdown = subprocess.run([runtime, 'help', '--format', 'markdown'], capture_output=True, timeout=60)
assert markdown.returncode == 0, markdown.stderr
assert b'\x1b_tsp' not in markdown.stdout and b'\x1b' not in markdown.stdout, 'markdown output carries escapes'
(out / 'index.md').write_bytes(markdown.stdout)
page = subprocess.run([runtime, 'help', '--format', 'markdown', 'sandbox'], capture_output=True, timeout=60)
assert page.returncode == 0 and b'\x1b_tsp' not in page.stdout, page.stderr
(out / 'sandbox.md').write_bytes(page.stdout)

with tempfile.TemporaryDirectory(prefix='help-') as temporary:
    state = Path(temporary)
    socket = state / 'control.sock'
    with (out / 'tern.log').open('w') as log:
        server = subprocess.Popen([tern, 'serve', '--control', str(socket), '--out', str(out)], stdout=log, stderr=log)

        def ctl(command, *values):
            result = subprocess.run([tern, 'ctl', '--control', str(socket), command,
                *(str(v) if command == 'tree' else json.dumps(str(v)) for v in values)], capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply

        def nodes(selector):
            return ctl('tree', selector).get('nodes', [])

        def tree(selector='.sf-main'):
            return json.dumps(ctl('tree', selector), ensure_ascii=False)

        def wait(predicate, timeout=60):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(.2)
            raise AssertionError(tree())

        def crumbs():
            return tree('[data-role="help-breadcrumb"]')

        def page_has(text):
            return text in tree('.sf-md')

        try:
            wait(socket.exists)
            ctl('run', shlex.join([str(host)]))
            # The landing page is the first page of the nav, drawn by Tern's own md kind.
            wait(lambda: nodes('.sf-md'))
            wait(lambda: page_has('Overview') or page_has('Elide'))
            landing = crumbs()
            assert 'Get Started' in landing, landing
            assert nodes('[data-role="help-nav"]'), tree()
            assert nodes('[data-role="help-search"]'), tree()
            assert 'search' in tree('[data-role="help-keys"]')
            ctl('appearance', 'light')
            ctl('shot', 'help-light')
            ctl('appearance', 'dark')
            ctl('shot', 'help-dark')
            ctl('appearance', 'light')

            # A nav row opens its page; the trail follows.
            ctl('click', '[data-role="help-nav"] [data-id$=".p2"]')
            wait(lambda: crumbs() != landing)
            clicked = crumbs()
            assert 'Getting started' in clicked or 'Installation' in clicked, clicked

            # `/`, a topic and Enter open it from the search.
            ctl('key', '/')
            wait(lambda: 'Search the docs' in tree('[data-role="help-results"]'))
            ctl('type', 'sandbox')
            wait(lambda: 'Sandbox' in tree('[data-role="help-results"]'))
            ctl('shot', 'help-search')
            ctl('key', 'Enter')
            wait(lambda: nodes('.sf-md') and 'Sandbox' in crumbs())
            assert page_has('--allow-net') or page_has('sandbox'), tree('.sf-md')
            assert not nodes('[data-role="help-results"]'), tree()

            # `b` goes back to the page the search left.
            ctl('key', 'b')
            wait(lambda: crumbs() == clicked)
            ctl('key', 'f')
            wait(lambda: 'Sandbox' in crumbs())

            # `]` steps to the next page in nav order.
            ctl('key', ']')
            wait(lambda: 'Sandbox' not in crumbs())

            # A page's links are rows that navigate in place (the md link itself goes
            # to the window's routes, which never reach the program).
            ctl('key', '/')
            ctl('type', 'getting-started')
            wait(lambda: 'Getting started' in tree('[data-role="help-results"]'))
            ctl('key', 'Enter')
            wait(lambda: 'Getting started' in crumbs())
            linking = crumbs()
            wait(lambda: nodes('[data-role="help-links"] .sf-item'))
            ctl('click', '[data-role="help-links"] .sf-item')
            wait(lambda: crumbs() != linking)
            ctl('key', 'b')
            wait(lambda: crumbs() == linking)
            # Tern's md draws no custom-scheme links, so the page marks link text with
            # spans carrying the help href (⌘-click hands it to the window's routes).
            wait(lambda: nodes('.sf-md [data-href^="elide://help?topic="]'))
            ctl('shot', 'help-links')
            ctl('key', 'q')
            wait(lambda: not nodes('[data-role="help-heading"]'))

            # An unknown topic shows the closest ones instead of a dead end.
            ctl('run', shlex.join([str(host), 'sandboks']))
            wait(lambda: nodes('[data-role="help-missing"]'))
            assert 'Sandbox' in tree('[data-role="help-suggestions"]'), tree()
            ctl('shot', 'help-missing')
            ctl('click', '[data-role="help-suggestions"] .sf-item')
            wait(lambda: nodes('.sf-md'))
            ctl('key', 'q')
            wait(lambda: not nodes('[data-role="help-heading"]'))
            print('PASS: markdown has no TSP bytes, landing page, nav click, search and Enter, back/forward, next page, unknown topic suggestions, light/dark shots')
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
