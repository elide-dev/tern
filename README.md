# Elide for Tern

A Luau plugin backed by a native broker and disposable embedded Elide workers.
Notebook workers load the same C ABI and Cap'n Proto SDK used by Elide Studio.
Test and server hosts supervise the canonical runtime independently; GraalVM is
never loaded into Tern's UI process.

Native surfaces cover REPL, Tests, serving and trace inspection. Project testing
sessions share live runs between views and the built-in agent. SDK LSP/MCP channels
have broker plumbing; standard client transports and live WebSocket MCP attachment
remain follow-up work.

## Development

Requires Rust with edition 2024 support, Cap'n Proto (capnp compiler), Python 3, Tern, and StyLua 2.5.2
(`mise install`). Native SDK execution supports macOS arm64 and Linux amd64,
subject to the selected SDK's deployment requirements.

```sh
make build repl
make test
make check
cp plugin/config.example.json plugin/config.json
# Set sdk to a complete extracted embedded SDK directory.
make smoke SDK=/path/to/elide-embed
make test-surface SDK=/path/to/elide-embed
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
and an action bar for Build, Test, Run, REPL, and static serving. All panes use Tern's
normal adjustable splits. Opening the workspace again focuses it without resetting
your layout. Project actions retain their original root as focus changes.

The editor starts with `elide.pkl`; select source files in Files to work on code.
Editing, undo, saving, and dirty buffers belong to Tern's native editor. Test/REPL/server
results open beside the editor; clicking their action again focuses the existing pane.
Build and Run currently use the runtime's terminal output and normal Tern process lifetime.
This does not yet register Elide LSP providers, debugger decorations, or coverage gutters.

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
`repl` defaults to `../dist/elide-tern-repl`.
Keep `elide-tern-worker` beside it. An optional `state` setting selects a short,
private broker directory if Tern's plugin-data path exceeds Unix socket limits.
Never store SDK binaries or machine-specific configuration in source control.
The native SDK is user-supplied; no archive is downloaded automatically.

`make types` exports the installed Tern's Luau definitions. Formatting checks
parse Luau; a successful build does not establish visual acceptance in Tern.

See [architecture](docs/architecture.md), [broker protocol](docs/protocol.md),
and [upstream provenance](third_party/README.md).

### Servers

Run `make serve` and choose **Serve directory or script** in Tern's command palette.
The launcher uses the canonical Rust serving surface, independently of REPL workers.
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

Build the native test host with `make testing`, then choose **Run tests** in Tern.
Enter a project directory or test file. The surface provides live results, failure
filtering, original diagnostics, per-test output, source links, rerun and cancel.
It uses `config.runtime`; `config.test` optionally overrides the launcher path.
Inside a detected project, Tests attaches to a shared project host. Closing its view
leaves tests running; **Cancel** stops them explicitly. **View project test runs**
reconnects to recent results, and another view can observe the same run without
launching it again. Recent runs are selectable in the native UI.
Whole-project runs include JVM tests; individual paths remain explicit test filters.

Build this host with `make project` (`make link` includes it). `config.project`
can override the launcher and `config.project_state` selects a short private host
directory. Development builds currently consume the shared `elide-project-session`
crate from the sibling Elide checkout, alongside the existing surface build dependency.

Raw reports are saved under the target directory's `.dev/reports/tests/tern/`.
Run the real Tern integration test with `make test-testing RUNTIME=/path/to/elide`.
Run `make test-sessions RUNTIME=/path/to/elide` for two-window attachment, live shared
results, duplicate-command protection, reconnect, rerun and cancellation checks.
`make test-project PROJECT=/path/to/project` opens an isolated desktop Tern window
and verifies native tab launches, REPL, serving, and tests in that existing project.

### Built-in agent project tools

Carly receives a cached project hint and five asynchronous exports:
`project_open(root)`, `project_read(binding)`, `test_run(binding, subject, command)`,
`test_cancel(binding, run)`, and `project_close(binding)` under `plugins.elide`.
Opening returns an explicit project binding; changing focused tabs cannot retarget
it. Reads renew the 60-second attachment lease and return bounded run/failure summaries.
Use a fresh UUID command for an intentional run and retain it for retries. Native
Tests views observe agent-started runs through the same project host.

This bridge uses Tern's callable exports and local IPC. It does not claim WebSocket
MCP or automatic attachment to other agent harnesses. `make test-project` exercises
actual Carly Lua exports against native Elide and verifies visible results and retry
deduplication without invoking a model.
