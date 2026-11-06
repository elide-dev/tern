"""Real guest debugging through native Tern controls and the shared agent API."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--runtime')
args = parser.parse_args()
config_path = root / 'plugin/config.json'
config = json.loads(config_path.read_text()) if config_path.exists() else {}
configured = Path(args.runtime or config['runtime'])
runtime = configured.resolve() if args.runtime or configured.is_absolute() else (root / 'plugin' / configured).resolve()
out = root / '.dev/scratch/debug-test'
out.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='td-', dir='/tmp') as temporary:
    state = Path(temporary)
    project = state / "Debugger's λ"
    project.mkdir()
    (project / 'elide.pkl').write_text('amends "elide:project.pkl"\nname = "debug-example"\n')
    javascript = project / 'main.mjs'
    javascript.write_text('''function compute(input) {
  const base = input + 1;
  const payload = {answer: base * 2, nested: {ok: true}};
  const result = payload.answer;
  console.log("computed", result);
  return result;
}
compute(20);
''')
    python = project / 'main.py'
    python.write_text('''def compute(value):
    base = value + 1
    payload = {"answer": base * 2}
    result = payload["answer"]
    print("computed", result)
    return result
compute(20)
''')
    test_file = project / 'example.test.mjs'
    test_file.write_text('''import {test} from "node:test";
import assert from "node:assert/strict";
import {writeFileSync} from "node:fs";
test("a debugged test", () => {
  const actual = 2 + 2;
  assert.equal(actual, 4);
  writeFileSync("test-finished", "passed");
});
''')
    loop = project / 'loop.mjs'
    loop.write_text('let ticks = 0;\nwhile (true) { ticks++; }\n')
    fixtures = state / 'crates/plugins/fixtures'
    fixtures.mkdir(parents=True)
    package = fixtures / 'elide'
    shutil.copytree(root / 'plugin', package, ignore=shutil.ignore_patterns('config.json', 'tern.d.luau'))
    broker_state = state / 'projects'
    fixture_config = {'runtime': str(runtime), 'project_state': str(broker_state),
                      'broker': str(root / 'dist/elide-tern-broker')}
    (package / 'config.json').write_text(json.dumps(fixture_config))
    fixture_root = state / 'crates/tern'
    (fixture_root / 'goldens').mkdir(parents=True)
    socket = state / 'control.sock'
    binding = None

    def broker(op, **fields):
        result = subprocess.run([str(root / 'dist/elide-tern-broker'), 'request', str(broker_state)],
            input=json.dumps({'op': op, **fields}), capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        reply = json.loads(result.stdout)
        assert reply['ok'], reply
        return reply['result']

    def debug():
        return broker('project_debug_snapshot', binding=binding)

    with (out / 'tern.log').open('w') as log:
        environment = {**os.environ, 'STENCIL_FIXTURE_ROOT': str(fixture_root),
            'TERN_DAEMON_SOCKET': str(state / 'daemon.sock'), 'TERN_CONFIG_DIR': str(state / 'config')}
        subprocess.run(['tern', 'plugin', 'link', str(package)], env=environment, check=True, stdout=log, stderr=log)
        daemon = subprocess.Popen(['tern', 'daemon', '--socket', str(state / 'daemon.sock')], stdout=log, stderr=log, env=environment)
        server = subprocess.Popen(['tern', '--control', str(socket), '--out', str(out), '--dir', str(project)],
            stdout=log, stderr=log, env=environment)

        def ctl(command, *values):
            def argument(value):
                if command == 'tree' or (command == 'click' and value in {'right', 'ctrl', 'meta', 'alt', 'shift'}):
                    return str(value)
                return json.dumps(str(value), ensure_ascii=False)
            result = subprocess.run(['tern', 'ctl', '--control', str(socket), command, *(argument(value) for value in values)],
                capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply

        def tree(selector='[data-role="debug-shell"]'):
            return json.dumps(ctl('tree', selector), ensure_ascii=False)

        def wait(predicate, seconds=60):
            deadline = time.monotonic() + seconds
            renewed = time.monotonic()
            while time.monotonic() < deadline:
                if binding and time.monotonic() - renewed > 10:
                    debug()
                    renewed = time.monotonic()
                value = predicate()
                if value:
                    return value
                time.sleep(.1)
            raise AssertionError(tree())

        def click(selector, *modifiers):
            enabled = selector + ':not(.disabled):not([disabled]):not([aria-disabled="true"])'
            wait(lambda: any(node.get('rect', [0, 0, 0, 0])[2] > 0
                and node.get('rect', [0, 0, 0, 0])[3] > 0 for node in ctl('tree', enabled).get('nodes', [])))
            ctl('click', enabled, *modifiers)

        def text_is(selector, expected):
            return any(node.get('text') == expected for node in ctl('tree', selector).get('nodes', []))

        def stopped(line=None, after=0):
            snapshot = debug()
            if snapshot and snapshot['debug']['state'] == 'failed':
                raise AssertionError(snapshot)
            if not snapshot or snapshot['debug']['state'] != 'stopped':
                return False
            current = snapshot['debug']
            return current if current['stop_epoch'] > after and current['frames'] and (line is None or current['frames'][0]['line'] == line) else False

        def input_text(role, text):
            selector = '[data-role="' + role + '"]'
            click(selector)
            wait(lambda: ctl('tree', selector + '.focused').get('nodes'))
            ctl('key', 'Meta+a')
            ctl('type', text)
            wait(lambda: text_is(selector, text))

        def choose_target(text):
            # The target picker where the surface has one, else the typed target field.
            if not ctl('tree', '[data-role="debug-choose"]').get('nodes'):
                return input_text('debug-target', text)
            click('[data-role="debug-choose"]')
            wait(lambda: ctl('tree', '[data-role="debug-targets"]').get('nodes'))
            ctl('type', text)
            wait(lambda: text in tree('[data-role="debug-targets"] .pk-row.sel'))
            click('[data-role="debug-targets"] .pk-btn[data-v="choose"]')
            wait(lambda: text_is('[data-role="debug-target"]', text))

        def carly(code, marker):
            ctl('carly', 'lua', code + '; return ' + json.dumps(marker))
            wait(lambda: marker in json.dumps(ctl('state').get('carly', {}).get('last_tool', {})))

        def breakpoint(path, line):
            click('[data-role="debug-breakpoints-tab"], [data-role="debug-tabs"] .sf-tab[data-tab="breakpoints"]')
            input_text('debug-breakpoint-input', f'{path}:{line}')
            click('[data-role="debug-breakpoint-add"]')
            wait(lambda: f'{path}:{line}' in tree('[data-role="debug-breakpoint"]'))
            click('[data-role="debug-inspect-tab"], [data-role="debug-tabs"] .sf-tab[data-tab="inspect"]')

        def inspect_value(name):
            values = debug()['debug']['variables']
            index, value = next((index, value) for index, value in enumerate(values) if value['name'] == name)
            assert value['reference'] > 0, value
            row = f'[data-role="debug-variables"] .sf-tbl-body .sf-tbl-row:nth-child({index + 1})'
            wait(lambda: text_is(row + ' .sf-tbl-c:first-child', name))
            click(row + ' button')
            wait(lambda: debug()['debug']['selected_reference'] == value['reference'] and not debug()['debug']['pending'])

        def target_processes():
            rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
            return [row for row in rows if row.strip().split(None, 1)[1].startswith(str(runtime) + ' ')
                    and '--debugger=dap' in row and str(project.resolve()) in row]

        try:
            wait(socket.exists)
            ctl('plugins', 'run', 'plugin.elide.workspace')
            wait(lambda: ctl('tree', '[data-role="project-debug"]').get('nodes'))
            click('[data-role="project-debug"]')
            wait(lambda: ctl('tree', '[data-role="debug-target"]').get('nodes'))
            binding = broker('project_attach', root=str(project.resolve()), runtime=str(runtime))
            choose_target('main.mjs')
            breakpoint('main.mjs', 4)
            click('[data-role="debug-launch-button"]')
            entry = wait(lambda: stopped())
            assert target_processes(), 'Debug target process was not found'
            click('[data-role="debug-continue"]')
            first = wait(lambda: stopped(4, entry['stop_epoch']))
            wait(lambda: any(bp['verified'] and bp['line'] == 4 for bp in debug()['debug']['breakpoints']))
            wait(lambda: debug()['debug']['scopes'])
            assert not debug()['debug']['variables'], 'Rendering a pause must not evaluate guest values'
            click('[data-role="debug-read-values"]')
            wait(lambda: 'payload' in tree('[data-role="debug-variables"]'))
            values = debug()['debug']['variables']
            assert any(value['name'] == 'base' and value['value'] == '21' for value in values), values
            inspect_value('payload')
            payload_reference = debug()['debug']['selected_reference']
            values = debug()['debug']['variables']
            assert any(value['name'] == 'answer' and value['value'] == '42' for value in values), values
            inspect_value('nested')
            values = debug()['debug']['variables']
            assert any(value['name'] == 'ok' and value['value'] == 'true' for value in values), values
            wait(lambda: text_is('[data-role="debug-path"]', 'nested'))
            click('[data-role="debug-values-back"]')
            wait(lambda: text_is('[data-role="debug-path"]', 'payload'))
            assert debug()['debug']['selected_reference'] != payload_reference, 'Back must not re-evaluate guest values'
            click('[data-role="debug-read-values"]')
            wait(lambda: debug()['debug']['selected_reference'] == payload_reference and 'answer' in tree('[data-role="debug-variables"]'))
            click('[data-role="debug-source"]', 'meta')

            def source_opened():
                # A file block at the paused caret (file:// links), or the Elide source block
                # (elide://source links) whose gutter marks the paused line with ▶.
                line = first['frames'][0]['line']
                if any(block.get('path') and Path(block['path']).resolve() == javascript.resolve()
                       and block.get('caret') == [line, max(1, first['frames'][0]['column'])]
                       for block in ctl('state').get('file_blocks', [])):
                    return True
                gutter = ctl('tree', "[data-surface='plugin.elide.source'] .sf-editor .sf-ed-gutter").get('nodes', [])
                return any((node.get('text') or '').split()[:2] == [str(line), '▶'] for node in gutter)
            wait(source_opened)
            (out / 'javascript-state.json').write_text(json.dumps(ctl('state'), indent=2, ensure_ascii=False))
            ctl('shot', 'debug-light')
            ctl('prefs', 'preview', 'dark-nord')
            ctl('shot', 'debug-dark')
            click('[data-role="debug-next"]')
            stepped = wait(lambda: stopped(5, first['stop_epoch']))
            assert not stepped['variables'], 'Stepping must invalidate prior values'
            carly('debug_binding = await(plugins.elide.project_open(' + json.dumps(str(project), ensure_ascii=False) + ')); debug_seen = await(plugins.elide.debug_read(debug_binding)); assert(debug_seen.debug.state == "stopped"); assert(not debug_seen.controls)', 'debug-observer-ready')
            carly('await(plugins.elide.debug_takeover(debug_binding, debug_seen.debug.generation))', 'debug-controller-ready')
            wait(lambda: text_is('[data-role="debug-owner"]', 'Observing'))
            wait(lambda: ctl('tree', '[data-role="debug-read-values"].disabled').get('nodes'))
            assert not debug()['debug']['variables'], 'An observer must not automatically inspect guest values'
            stale_command = str(uuid.uuid4())
            carly('await(plugins.elide.debug_control(debug_binding, ' + json.dumps(stale_command) + ', {generation=debug_seen.debug.generation, stop_epoch=' + str(first['stop_epoch']) + ', action={kind="next"}}))', 'stale-command-accepted')
            wait(lambda: 'stop expired' in (debug()['debug'].get('error') or ''))
            assert debug()['debug']['stop_epoch'] == stepped['stop_epoch']
            click('[data-role="debug-takeover"]')
            wait(lambda: text_is('[data-role="debug-owner"]', 'You control'))
            click('[data-role="debug-continue"]')
            wait(lambda: debug()['debug']['state'] == 'exited')
            wait(lambda: not target_processes())
            print('PASS: JavaScript breakpoint, scopes, explicit nested values, native source, stepping, shared agent control and stale-stop rejection')

            choose_target('main.py')
            breakpoint('main.py', 4)
            click('[data-role="debug-launch-button"]')
            entry = wait(lambda: stopped())
            click('[data-role="debug-continue"]')
            first_python = wait(lambda: stopped(4, entry['stop_epoch']))
            assert first_python['generation'] != first['generation']
            wait(lambda: debug()['debug']['scopes'])
            click('[data-role="debug-read-values"]')
            wait(lambda: 'payload' in tree('[data-role="debug-variables"]'))
            assert any(value['name'] == 'base' and value['value'] == '21' for value in debug()['debug']['variables'])
            ctl('shot', 'debug-python')
            click('[data-role="debug-stop-button"]')
            wait(lambda: debug()['debug']['state'] == 'exited')
            wait(lambda: not target_processes())
            print('PASS: Python breakpoint, locals and explicit target termination')

            carly('test_launch = await(plugins.elide.debug_launch(debug_binding, "example.test.mjs", ' + json.dumps(str(uuid.uuid4())) + ', {mode="test", stop_on_entry=false, breakpoints={{path="example.test.mjs",line=6}}}))', 'debug-test-launched')
            wait(lambda: stopped(6))
            carly('debug_seen = await(plugins.elide.debug_read(debug_binding)); await(plugins.elide.debug_control(debug_binding, ' + json.dumps(str(uuid.uuid4())) + ', {generation=debug_seen.debug.generation,stop_epoch=debug_seen.debug.stop_epoch,action={kind="continue"}}))', 'debug-test-resumed')
            wait(lambda: debug()['debug']['state'] == 'exited')
            assert (project / 'test-finished').read_text() == 'passed'
            print('PASS: selected JavaScript test debugging through real Carly exports')

            carly('loop_launch = await(plugins.elide.debug_launch(debug_binding, "loop.mjs", ' + json.dumps(str(uuid.uuid4())) + ', {stop_on_entry=false}))', 'debug-loop-launched')
            wait(lambda: debug()['debug']['state'] == 'running')
            click('[data-role="debug-takeover"]')
            wait(lambda: text_is('[data-role="debug-owner"]', 'You control'))
            click('[data-role="debug-pause"]')
            wait(lambda: stopped())
            click('[data-role="debug-stop-button"]')
            wait(lambda: debug()['debug']['state'] == 'exited')
            wait(lambda: not target_processes())
            carly('await(plugins.elide.project_close(debug_binding))', 'debug-agent-closed')
            assert 'exceeded its budget' not in (out / 'tern.log').read_text()
            print('PASS: pause and stop remain responsive while the guest is busy')
        except BaseException:
            (out / 'failure-state.json').write_text(json.dumps(ctl('state'), indent=2, ensure_ascii=False))
            (out / 'failure-tree.json').write_text(tree())
            if binding:
                try:
                    (out / 'failure-debug.json').write_text(json.dumps(debug(), indent=2, ensure_ascii=False))
                except Exception:
                    pass
            raise
        finally:
            if binding:
                try:
                    snapshot = debug()
                    if snapshot and snapshot['debug']['state'] not in {'exited', 'failed'}:
                        broker('project_debug_takeover', binding=binding, generation=snapshot['debug']['generation'])
                        broker('project_debug_request', binding=binding, command=str(uuid.uuid4()), request={
                            'generation':snapshot['debug']['generation'], 'stop_epoch':snapshot['debug']['stop_epoch'], 'action':{'kind':'stop'}})
                    broker('project_detach', binding=binding)
                except Exception:
                    pass
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
            daemon.terminate()
            try:
                daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.kill(); daemon.wait()
