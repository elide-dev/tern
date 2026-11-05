# Elide for Tern

A Luau plugin backed by a native broker and disposable embedded Elide workers.
The worker loads the same C ABI and Cap'n Proto SDK used by Elide Studio; it does
not invoke the Elide CLI or load GraalVM into Tern's UI process.

This is an initial integration, with the shared native REPL surface and a working broker transport
for persistent kernels and SDK LSP/MCP channels. Server lifecycle/TUI controls and
standard LSP/MCP client transports are not implemented yet.

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

In the serving dashboard, **Restart with tracing** enables a local, authenticated
OTLP receiver and starts a fresh server run. **Traces** shows request groups,
span timing, attributes and correlated logs. Click a trace, then a span for details.
**Server** returns to the serving dashboard; **Detach tracing** releases local
collection while leaving the server and existing remote exporters running.
Reattaching requires restarting the server.

The receiver accepts OTLP/HTTP protobuf and JSON (including gzip), with a 2 MiB
payload limit. Retention is bounded to 512 records, 4 MiB, and five minutes;
eviction, rejection and truncation are visible. Metrics, profiles and gRPC ingestion
are not included yet. Static server spans measure handler work through response
construction, not network delivery.

`make test-telemetry RUNTIME=/path/to/elide` checks real nested runtime spans,
correlated logs, trace rendering, preservation of a second exporter, detach and
teardown. `python3 tests/telemetry.py --static` checks the static server path.
