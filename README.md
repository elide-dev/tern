# Elide for Tern

A Luau plugin backed by a native broker and disposable embedded Elide workers.
Notebook workers load the same C ABI and Cap'n Proto SDK used by Elide Studio.
Test and server hosts supervise the canonical runtime independently; GraalVM is
never loaded into Tern's UI process.

Native surfaces cover REPL, Tests, Debug, serving and trace inspection. Project
sessions share runs and debugger state between views and the built-in agent. SDK LSP/MCP channels
have broker plumbing; standard client transports and live WebSocket MCP attachment
remain follow-up work.

## Install the preview

macOS Apple Silicon users with repository access can install the self-contained
[preview release](https://github.com/elide-dev/tern/releases), including its matched
runtime and SDK. See [installation instructions](docs/manual-install.md).

## Development

Requires Rust with edition 2024 support, Cap'n Proto (capnp compiler), Python 3, Tern, and StyLua 2.5.2
(`mise install`). Native SDK execution supports macOS arm64 and Linux amd64,
subject to the selected SDK's deployment requirements. The configured runtime must support
`elide tern`; `make link` builds the broker and worker, then links the plugin.

```sh
make build
make test
make check
cp plugin/config.example.json plugin/config.json
# Set sdk to a complete extracted embedded SDK directory.
make smoke SDK=/path/to/elide-embed
make test-surface SDK=/path/to/elide-embed RUNTIME=/path/to/elide
make link
```

`make link` installs the local plugin into Tern. Open **Elide → Open REPL**
from its command palette. The native REPL has a language picker with Tern's Material
language icons; Ctrl+L also opens it, arrows choose and Enter switches. Each language
retains its draft, undo state and history. The entire REPL shares one notebook kernel. Enter evaluates and Shift+Enter
inserts a newline. `/help` lists the shared REPL commands. Clear clears the transcript;
it does not reset the runtime.

### Project workspace

Open Tern in a directory containing `elide.pkl` (or any child directory), then click
**Workspace** in the status bar or choose **Open project workspace** in the palette.
This creates a project tab with Tern's Files browser, native file editor, a terminal,
and a compact icon toolbar for Build, Test, Run, Debug, REPL, and static serving.
Buttons have hover labels and accessible names. All panes use Tern's normal
adjustable splits. Opening the workspace again refreshes its toolbar without resetting
your layout. Project actions retain their original root as focus changes.

The editor starts with `elide.pkl`; ordinary Files clicks reuse that editor within
the active project workspace. Explicit split/tab opens retain Tern's placement,
and modified selection gestures stay native. Unsaved documents remain available
when another file opens over them. The bottom terminal launches in the project
root; reopening a workspace preserves an existing shell's current directory.
Editing, undo, saving, and dirty buffers belong to Tern's native editor. Test/REPL/server
results open beside the editor; clicking their action again focuses the existing pane.
Build and Run currently use the runtime's terminal output and normal Tern process lifetime.
This does not yet register Elide LSP providers, debugger decorations, or coverage gutters.

`make test-workspace` verifies native file routing, unsaved edits, project isolation
and the terminal's actual working directory in an isolated desktop window.

The SDK executes JavaScript and Python with shared live bindings: define
`const y = {hi: 5}` in JavaScript, switch to Python and evaluate `y.hi`.
Statements stay silent and object results render as expandable native JSON trees.
Language labels appear only when the cell language changes. CEL evaluates shared
data snapshots; Pkl evaluates modules and publishes its JSON result as `_`.
Kotlin supports module declarations, not bare expressions or automatic `main`
execution. TypeScript and Wasm still need execution adapters.

`make repl` builds the shared frontend from the sibling `../elide` checkout through
its Makefile. Override `ELIDE_SOURCE` for another checkout. `make test-surface` opens
an isolated headless Tern renderer and tests real kernels, icons, pointer/keyboard
switching, preserved drafts/bindings and teardown. Captures go in `.dev/scratch/`.
The launcher currently supports local hosts; remote hosts require their own native
launcher and SDK installation.

`plugin/config.json` is ignored. The default broker is `../dist/elide-tern-broker`;
keep `elide-tern-worker` beside it. Every native surface launches as
`<runtime> test|serve <subject>` or `<runtime> tern <repl|project|debug>`, so a runtime built from a branch with
that command needs no separate launchers. The plugin probes each runtime path once with
`tern --help` before its first launch and reports a runtime that lacks the command
instead of letting an older runtime resolve `tern` as a project script. The optional `repl`, `serve`, `test`,
`project` and `debug` settings name an explicit launcher executable for one surface,
which the `dist/elide-tern-*` development shims built by `make link` provide. An optional `state` setting selects a short,
private broker directory if Tern's plugin-data path exceeds Unix socket limits.
Never store SDK binaries or machine-specific configuration in source control.
The native SDK is user-supplied; no archive is downloaded automatically.

`make types` exports the installed Tern's Luau definitions. Formatting checks
parse Luau; a successful build does not establish visual acceptance in Tern.

See [architecture](docs/architecture.md), [broker protocol](docs/protocol.md),
and [upstream provenance](third_party/README.md).

### Debugging

Choose **Debug** in the project workspace or **Debug project source** in the command
palette. If a supported source file is open in the workspace editor, Debug launches
it; otherwise enter a project-relative path in the panel. The toolbar requires saving
an edited source file before launch; targets execute files on disk. JavaScript/TypeScript
and Python use the runtime's guest debugger. Select **Tests** to debug a JavaScript test file through the test runner.

Add `file:line` breakpoints before launch or while stopped. The panel shows adapter
verification, call stacks, scopes, Continue, Step over/in/out, Pause and Stop. Source
links open the selected frame in Tern's native editor. **Inspect values** and nested
**Inspect** buttons explicitly request value formatting, which may execute guest
getters; inspecting never happens automatically. Old values clear when execution resumes.

One attachment controls execution; other panels and Carly can observe the same
pause. **Take control** transfers ownership and revokes queued controls from the
previous owner. Closing the controlling view starts a 30-second grace period for
another attachment to take over, then stops the target. Stop ends it immediately.
Debug-test runs cannot overlap ordinary tests writing to the same project output.

Build the development shim with `make debugging` (`make link` includes it).
`config.debug` can override the launcher; runtime and project-state settings are shared with Tests.
`make test-debug RUNTIME=/path/to/elide` validates JavaScript and Python in a real
Tern desktop, including value browsing, source navigation, agent/UI handoff, stale
commands, debug tests, busy-program Pause and teardown. Native editor gutter
breakpoints, expression watches, late attachment and JVM debugging remain separate work.

### Servers

Choose **Serve directory or script** in Tern's command palette, or type `elide serve`
in any Tern terminal. Both use the canonical Rust serving surface, independently of REPL workers.
Directories bind an available loopback port; scripts use `runtime` from
`plugin/config.json` (default `elide` on PATH). Relative runtime paths resolve from
the plugin directory. The `serve` setting overrides the surface launcher.

The dashboard provides actual bound URLs, observed request status/latency, clickable
request details, bounded logs, stop and restart. Closing it stops the supervised
server process group. Runtime readiness/request events currently require
`Elide.serve`; other APIs, including `node:http`, expose process controls and logs
without guessed readiness or request data. Local OTLP trace inspection is described below.

`make test-serve RUNTIME=/path/to/elide` exercises static and runtime HTTP requests,
failures, restart and teardown in an isolated Tern renderer. Without `RUNTIME`, it
runs the static serving checks.

### Trace inspection

Local capture starts with the server. **Traces** opens a compact trace list beside
the selected request's waterfall and browsable span details. The server URL and
status stay visible. **Errors** filters failures; **Requests** returns to request history.
**Pause capture**, **Resume capture**, and **Clear traces** work live without
restarting the server or changing its application state or remote exporters.
Pausing retains the existing bounded history; closing the session releases the receiver.

The receiver accepts OTLP/HTTP protobuf and JSON (including gzip), with a 2 MiB
payload limit. Retention is bounded to 512 records, 4 MiB, and five minutes;
eviction, rejection and truncation are visible. Metrics, profiles and gRPC ingestion
are not included yet. Static server spans measure handler work through response
construction, not network delivery.

`make test-telemetry RUNTIME=/path/to/elide` checks real nested runtime spans,
correlated logs, trace rendering, preservation of a second exporter, repeated live pause/resume, clear, runtime state
continuity and teardown. `python3 tests/telemetry.py --static` checks the static server path.

### Tests

Choose **Run tests** in Tern and enter a project directory or test file, or type
`elide test` in any Tern terminal: the shipped binary negotiates the surface itself and
keeps plain output for reporters and redirected output. The surface provides live results, failure
filtering, original diagnostics, per-test output, source links, rerun and cancel.
It uses `config.runtime`; `config.test` optionally overrides the launcher path.
Inside a detected project, Tests attaches to a shared project host. Closing its view
leaves tests running; **Cancel** stops them explicitly. **View project test runs**
reconnects to recent results, and another view can observe the same run without
launching it again. Recent runs are selectable in the native UI.
Whole-project runs include JVM tests; individual paths remain explicit test filters.

**Run with coverage** collects a measured artifact for that invocation. The
**Coverage** tab shows file coverage and covered/uncovered line details, with branch
counters where the runtime supplies them. Select a line and follow **Open current
source** into Tern's native editor, then save and rerun. Reruns preserve the selected
run's coverage option; earlier measurements remain unchanged. JavaScript fingerprints
come from the text evaluated by Truffle. These panels show measured source versions;
they do not claim live buffer freshness or install native editor gutters.

Build the development shim with `make project` (`make link` includes it). `config.project`
can override the launcher and `config.project_state` selects a short private host
directory. Development builds currently consume the shared `elide-project-session`
crate from the sibling Elide checkout, alongside the existing surface build dependency.

Raw reports are saved under the target directory's `.dev/reports/tests/tern/`.
Run the real Tern integration test with `make test-testing RUNTIME=/path/to/elide`.
Run `make test-sessions RUNTIME=/path/to/elide` for two-window attachment, live shared
results, duplicate-command protection, reconnect, rerun and cancellation checks.
`make test-project PROJECT=/path/to/project` opens an isolated desktop Tern window
and verifies native tab launches, REPL, serving, and tests in that existing project.
`make test-coverage RUNTIME=/path/to/elide` exercises coverage, native source/line
navigation, editing, reruns and paged agent reads in an isolated desktop window.

### Terminal integration

Inside a detected project, tabs take the project's name (names you give a tab win)
and the status bar shows the project, **Workspace**, and how the pane's last
`elide test`, `build` or `run` ended. Click the project segment for the project menu.
A failing `elide test` typed in a terminal toasts "Tests failed". Choosing `elide.pkl`
from the palette opens that project's workspace.

`elide build` in a Tern terminal shows compile errors as diagnostic cards linked to
their source, and `elide test --reporter=tap` shows a pass/fail summary with a table of
results. Both fall back to the raw output when nothing parses or the output is very large.

`elide://source`, `elide://debug` and `elide://tests` links open a source line (in the
[source view](#source-view) for project sources), the debugger or project test runs. Elide prints them; any program can, as OSC 8 hyperlinks.
Links that leave their project root are ignored. See
[the contract](docs/architecture.md#elide-links). Run `lua tests/links.lua` for the
parser's unit tests and `python3 tests/integration.py --runtime /path/to/elide` for the
lenses, links and status line in an isolated window.

### Source view

**Open with Elide source** (from a file's menu), the workspace toolbar's **Source**
button, or **Open Elide source…** in the project menu shows a project source file
read-only with Tern's highlighting and three overlays: **Coverage** marks covered,
uncovered and partially covered lines from the newest coverage run (or runs one),
**Debug** sets breakpoints with `b` on the caret line, launches with F5 and shows where
the target paused, and **Hotness** waits on source-located profile data the project
session does not record yet. Press `e` to edit the file in Tern. `elide://source`
links open this view for sources inside a project. Run `lua tests/source.lua` for its
helpers and `python3 tests/source.py --runtime /path/to/elide` for the block itself.

### Built-in agent project tools

Carly receives a cached project hint and asynchronous exports:
`project_open(root)`, `project_read(binding)`, `test_run(binding, subject, command)`,
`test_cancel(binding, run)`, and `project_close(binding)` under `plugins.elide`.
Opening returns an explicit project binding; changing focused tabs cannot retarget
it. Reads renew the 60-second attachment lease and return bounded run/failure summaries.
Use a fresh UUID command for an intentional run and retain it for retries. Native
Tests views observe agent-started runs through the same project host.

`test_cover(binding, subject, command)` starts tests with coverage.
`coverage_read(binding, run, {})` lists measured files; pass `{file=N}` for the
zero-based file index's lines. Both forms accept `offset` and `limit` (maximum 100)
and return `next` for pagination. `project_read` includes coverage state and totals.

This bridge uses Tern's callable exports and local IPC. It does not claim WebSocket
MCP or automatic attachment to other agent harnesses. `make test-project` exercises
actual Carly Lua exports against native Elide and verifies visible results and retry
deduplication without invoking a model.
