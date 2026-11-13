"""Exercise the native Run surface in real Tern: program output, the task timeline folding once
the program writes, logcat output as records that wrap in a narrow pane, the log sized to the
pane, a failing exit status, Stop ending the child, compile errors as cards, the full page, the
inline block, and a bare run on a terminal of its own: typed input, a TTY and Ctrl-C."""
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
out = root / '.dev/scratch/run-test'
out.mkdir(parents=True, exist_ok=True)
runtime = str(Path(args.runtime).resolve())
host = root / 'dist/elide-tern-run'
tern = shutil.which('tern')

HELLO = 'package com.example\n\nfun main() = println("Hello Elide!")\n'

# A program writing what an Android run's output is: `adb logcat` threadtime lines, the last five
# after a pause, one of them longer than a narrow pane is wide.
SLOW = 'Slow frame: 48 ms on the main thread while inflating the settings screen, 3 frames dropped, see https://example.com/frames for how to read this trace and what to do about it'
LOGCAT = '''package com.example

fun main() {
    println("--------- beginning of main")
    repeat(40) { println("11-11 18:32:59.${500 + it}  4233  4233 I sample.app: line $it") }
    System.out.flush()
    Thread.sleep(1500)
    println("11-11 18:33:00.412  4233  4250 W sample.app: SLOW")
    println("11-11 18:33:01.200  4233  4233 E AndroidRuntime: FATAL EXCEPTION: main")
    println("11-11 18:33:01.200  4233  4233 E AndroidRuntime: java.lang.IllegalStateException: boom")
    println("11-11 18:33:01.200  4233  4233 E AndroidRuntime: \\tat sample.app.MainActivity.onCreate(MainActivity.kt:12)")
    println("11-11 18:33:01.200  4233  4233 E AndroidRuntime: \\tat android.app.Activity.performCreate(Activity.java:8595)")
}
'''.replace('SLOW', SLOW)

# Elide keeps a terminal stdin open after `rl.close()`, so the script exits on its own.
PROMPT = '''import { createInterface } from "node:readline";
console.log("one");
console.log("two");
const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: false });
rl.question("Name: ", (name) => {
  console.log(`Hello ${name}! tty=${process.stdout.isTTY === true}`);
  rl.close();
  process.exit(0);
});
'''
WAIT = 'for (let i = 0; i < 5; i++) console.log(`tick ${i}`);\nsetInterval(() => {}, 1000);\n'

with tempfile.TemporaryDirectory(prefix='run-') as temporary:
    state = Path(temporary)
    project = (state / 'Run λ').resolve()
    source = project / 'src/main/com/example'
    source.mkdir(parents=True)
    (project / 'elide.pkl').write_text('amends "elide:project.pkl"\n\nname = "run-example"\n\njvm {\n    main = "com.example.HelloKt"\n}\n')
    hello = source / 'Hello.kt'
    hello.write_text(HELLO)
    socket = state / 'control.sock'
    with (out / 'tern.log').open('w') as log:
        server = subprocess.Popen([tern, 'serve', '--control', str(socket), '--out', str(out)], stdout=log, stderr=log)

        def ctl(command, *values):
            result = subprocess.run([tern, 'ctl', '--control', str(socket), command,
                *(str(v) if command in ('tree', 'resize') else json.dumps(str(v), ensure_ascii=False) for v in values)],
                capture_output=True, text=True, timeout=30)
            reply = json.loads(result.stdout)
            assert reply.get('ok'), reply
            return reply

        def tree(selector='.sf-main'):
            return json.dumps(ctl('tree', selector), ensure_ascii=False)

        def nodes(selector):
            return ctl('tree', selector).get('nodes') or []

        def rect(selector):
            found = nodes(selector)
            return found[0]['rect'] if found else None

        def wait(predicate, timeout=180, step=.2):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if predicate(): return
                time.sleep(step)
            raise AssertionError(tree())

        def status(value):
            return value in tree('[data-role="run-status"]')

        # Plain output is drawn by a terminal view, so its text is not in the tree: the head's
        # line count shows it arrived, and the run's output.log holds the text.
        def output():
            return tree('[data-role="run-output"]')

        def latest_log():
            logs = sorted(project.glob('.dev/reports/run/tern/run-*/output.log'), key=lambda path: path.stat().st_mtime)
            return logs[-1].read_text() if logs else ''

        def host_running():
            rows = subprocess.check_output(['ps', '-axo', 'command'], text=True)
            return any(str(host) in row for row in rows.splitlines())

        def child_running():
            rows = subprocess.check_output(['ps', '-axo', 'command'], text=True)
            return any('--progress=json' in row and runtime in row for row in rows.splitlines())

        def running(marker):
            rows = subprocess.check_output(['ps', '-axo', 'command'], text=True)
            return any(marker in row for row in rows.splitlines())

        # Earlier inline blocks stay in scrollback, so a new block is told apart by count.
        def blocks(role, text):
            return sum(text in node.get('text', '') for node in nodes(f'[data-role="{role}"]'))

        def run(*extra):
            ctl('run', 'cd ' + shlex.quote(str(project)) + ' && ' + shlex.join([str(host), runtime, *extra]))

        try:
            wait(socket.exists)
            # The full page: a finished run with its output, task table and output.log.
            run('--surface=screen')
            wait(lambda: status('Finished'))
            assert '1 line' in output(), output()
            # The tasks folded when the program printed its line.
            assert nodes('[data-role="build-tasks"].collapsed'), tree('[data-role="build-tasks"]')
            assert nodes('[data-role="run-rerun"]') and not nodes('[data-role="run-stop"]'), tree()
            assert 'run again' in tree('[data-role="run-keys"]'), tree('[data-role="run-keys"]')
            assert 'Hello Elide!' in latest_log(), latest_log()
            ctl('appearance', 'light')
            ctl('shot', 'run-screen-light')
            ctl('appearance', 'dark')
            ctl('shot', 'run-screen-dark')
            ctl('appearance', 'light')
            # Run again: a failing exit status.
            hello.write_text('package com.example\n\nfun main() { println("boom"); kotlin.system.exitProcess(3) }\n')
            ctl('click', '[data-role="run-rerun"]')
            wait(lambda: status('Failed'))
            assert 'Exited with status 3' in tree('[data-role="run-summary"]'), tree('[data-role="run-summary"]')
            assert 'boom' in latest_log(), latest_log()
            # A long-running program: Stop ends the child.
            hello.write_text('package com.example\n\nfun main() { println("tick"); Thread.sleep(600000) }\n')
            ctl('key', 'r')
            wait(lambda: status('Running') and '1 line' in output())
            assert nodes('[data-role="run-stop"]'), tree()
            ctl('click', '[data-role="run-stop"]')
            wait(lambda: status('Stopped') and not child_running())
            assert 'tick' in latest_log(), latest_log()
            # A compile error: its card.
            hello.write_text('package com.example\n\nfun main() { val s: String = 1 }\n')
            ctl('key', 'r')
            wait(lambda: status('Failed'))
            assert nodes('[data-role="build-diagnostic"]'), tree()
            # No program output: the tasks the last run folded are open again.
            assert nodes('[data-role="build-tasks"]:not(.collapsed)'), tree('[data-role="build-tasks"]')
            # Logcat output: records under the folded tasks, a stack trace's lines in one. The log
            # takes the height the pane has left, so the page does not scroll, and it follows the
            # lines written after the pause.
            hello.write_text(LOGCAT)
            ctl('key', 'r')
            wait(lambda: status('Finished'))
            assert '46 lines' in output(), output()
            assert nodes('[data-role="build-tasks"].collapsed'), tree('[data-role="build-tasks"]')
            fatal = nodes('[data-role="run-log-record"]')[-1]
            widths = {round(badge['rect'][2]) for badge in nodes('[data-role="run-log-level"]')}
            assert len(widths) == 1, ('the level badges differ in width', widths)
            assert fatal.get('title') == '11-11 18:33:01.200  4233  4233 E AndroidRuntime: FATAL EXCEPTION: main', fatal
            assert fatal['text'].startswith('18:33:01.2004233-4233EAndroidRuntimeFATAL EXCEPTION: main'), fatal
            trace = nodes('[data-role="run-log-record"] [data-id$=".l42.message"]')[0]['text']
            assert 'IllegalStateException: boom' in trace and trace.endswith('performCreate(Activity.java:8595)'), trace
            ctl('appearance', 'light')
            ctl('shot', 'run-logcat-light')
            ctl('appearance', 'dark')
            ctl('shot', 'run-logcat-dark')
            ctl('appearance', 'light')
            log, dock = rect('[data-role="run-logcat"]'), rect('.sf-dock')
            assert log[1] + log[3] <= dock[1], ('the log runs under the dock', log, dock)
            assert fatal['rect'][1] + fatal['rect'][3] <= log[1] + log[3] + 1, ('the log did not follow its last record', fatal, log)
            # Narrow, a record's message goes under its tag and wraps: nothing is cut.
            ctl('resize', 560, 800)
            wait(lambda: nodes('.sf-col[data-role="run-log-record"]'))
            slow = nodes('[data-role="run-log-record"] [data-id$=".l41.message"]')[0]
            assert slow['text'] == SLOW, slow
            line = rect('[data-role="run-log-record"] [data-id$=".l1.message"]')[3]
            assert slow['rect'][3] >= 2 * line, ('the long message did not wrap', slow, line)
            log, dock = rect('[data-role="run-logcat"]'), rect('.sf-dock')
            assert log[1] + log[3] <= dock[1], ('the log runs under the dock', log, dock)
            ctl('shot', 'run-logcat-narrow-light')
            ctl('appearance', 'dark')
            ctl('shot', 'run-logcat-narrow-dark')
            ctl('appearance', 'light')
            ctl('resize', 1280, 800)
            ctl('key', 'q')
            wait(lambda: not host_running())
            # Inline, the run's block stays in scrollback after it exits.
            hello.write_text(HELLO)
            run('--surface=inline')
            wait(lambda: status('Finished'))
            wait(lambda: not host_running())
            time.sleep(1)
            assert nodes('.sf-main'), 'the inline block left scrollback'
            assert not nodes('.sf-dock'), 'inline has no dock'
            assert not nodes('[data-role="run-rerun"]'), 'inline has no run again'
            ctl('appearance', 'light')
            ctl('shot', 'run-inline-light')
            # A bare run is hosted on a terminal of its own: the prompt shows before the answer, what
            # is typed reaches the program, its output is a terminal, and Ctrl-C interrupts it.
            usage = subprocess.run([runtime, 'run', '--help'], capture_output=True, text=True, timeout=120).stdout
            launchers = [[str(host), runtime]]
            # Help wraps its text to the terminal's width.
            if 'inline (the default)' in ' '.join(usage.split()):
                launchers.append([runtime, 'run'])
            (project / 'prompt.mjs').write_text(PROMPT)
            (project / 'wait.mjs').write_text(WAIT)
            for launcher in launchers:
                marker = shlex.join(launcher) + ' '
                bare = lambda script: ctl('run', 'cd ' + shlex.quote(str(project)) + ' && ' + shlex.join([*launcher, script]))
                bare('prompt.mjs')
                wait(lambda: blocks('run-output', '3 lines') == 1)
                ctl('type', 'Ada')
                ctl('key', 'Enter')
                wait(lambda: not running(marker))
                assert 'Name: Ada\nHello Ada! tty=true' in latest_log(), latest_log()
                ticking, stopped = blocks('run-output', '5 lines'), blocks('run-status', 'Stopped')
                bare('wait.mjs')
                wait(lambda: blocks('run-output', '5 lines') == ticking + 1)
                ctl('key', 'ctrl+c')
                wait(lambda: not running(marker) and not child_running())
                assert blocks('run-status', 'Stopped') == stopped + 1, tree('[data-role="run-status"]')
                assert 'tick 4' in latest_log(), latest_log()
            # A runtime that advertises --surface accepts it on a plain run outside Tern.
            if '--surface' in usage:
                plain = subprocess.run([runtime, 'run', '--surface=screen'], cwd=project, capture_output=True, text=True, timeout=300)
                assert 'unexpected argument' not in plain.stderr and plain.returncode == 0, plain.stderr[-2000:]
                assert 'Hello Elide!' in plain.stdout, plain.stdout[-2000:]
                flag = 'plain run accepts --surface'
            else:
                flag = 'runtime predates --surface; plain-run check skipped'
            print(f'PASS: output, task table, logcat records, wrapping, log height, task fold, output.log, exit status, Stop, compile error cards, page, inline block, bare run on a terminal ({flag})')
            print('Shots:', *(str(out / 'serve' / f'{name}.png') for name in ['run-screen-light', 'run-screen-dark', 'run-logcat-light', 'run-logcat-dark', 'run-logcat-narrow-light', 'run-logcat-narrow-dark', 'run-inline-light']))
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
