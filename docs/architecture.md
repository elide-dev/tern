# Architecture

```text
Tern window: palette commands
  → native REPL host: shared session controller + Tern Surface Protocol
    → short-lived elide-tern-broker request process (argument array + JSON stdin)
      → private Unix socket → persistent native broker
        → dedicated supervised worker per session
          → Elide SDK C ABI 1.1 / Cap'n Proto protocol 1.0
```

Native surface tabs open through `cx.layout:new_tab({cwd, command})`; the launcher
is the tab's initial process, never text sent into an interactive shell. The launcher
is the runtime itself: `elide test` and `elide serve` host their own surfaces, and
`elide tern <repl|project|debug> …` hosts the broker-backed ones, each negotiating TSP
on the pane's pty and exiting with status 2 outside Tern. `elide test` and `elide serve` typed into an ordinary Tern terminal
negotiate the same surfaces without the plugin. A host lens renders JSON output of
`elide project` and `--json` commands as a native tree; it never touches TSP surfaces. Launch
arguments are individually shell-quoted because this SDK field takes a command string.
Exercise this path against a desktop window with an isolated daemon (`make test-project`):
the in-process `tern serve` harness can exceed the synchronous launch call's plugin budget.

Project workspaces compose existing Tern primitives: `cx.docs:open` owns the file
editor, `cx:open` reveals the project in Files, `cx.layout` owns adjustable splits,
and an owner-tagged `cx.canvas` holds the action bar. The toolbar carries no test or
document model. Its persisted pane references and explicit project root let actions
survive plugin reloads without following an unrelated focused directory. Results
use native TSP launchers beside the editor. Closing a workspace uses Tern's ordinary
pane lifecycle; project-owned test runs retain their independent lifetime.

Tern's process API captures a process result and closes stdin after writing. It is
not an interactive native FFI or persistent pipe API. A short-lived request
client lets Luau use the existing asynchronous process API while the broker owns
persistent runtime state. Requests never interpolate guest code into a shell.
The socket is local, in an owned 0700 directory, and has no network listener.
Same-user applications are inside the trust boundary.

The broker starts on the first request. Startup and lifetime locks prevent
competing brokers from unlinking a live socket. SDKs load lazily in workers;
the broker never loads the native library. At most eight sessions and sixteen
concurrent socket clients are admitted. A session has one serialized exchange;
concurrent calls to it return busy. Independent sessions run on independent
workers and cannot monopolize each other's runtime exchange lock.

Each request uses Studio's four-byte little-endian framing. Requests are capped
at 4 MiB, responses at 16 MiB; socket reads/writes have deadlines. SDK exchanges
have a ten-second wall deadline including blocked pipe writes and reads.
Transport failure kills/reaps the worker and invalidates its session handles.
Guest-language errors preserve the session. Kernel IDs are decimal strings in
JSON to avoid Luau floating-point precision loss.

Workers have dedicated process groups. Timeout, close, and idle reclamation kill
the group, including SDK children that remain in that group. The worker watches
its broker parent and kills its own group if the broker disappears. This is
process lifecycle management, not an OS sandbox: native descendants can escape a
process group, and trusted code still has the SDK's granted capabilities.
Close removes the session immediately; an already-running exchange finishes or
hits its deadline before the last reference releases its worker. It is not an
instantaneous interrupt API.

The native REPL sends a discovery heartbeat every thirty seconds while open.
Sessions expire after two minutes without an SDK request, and an empty broker
exits after two minutes without clients. The native host closes sessions on exit. Idle reclamation is the backstop after a
crash. Runtime handles are not persisted; a new process starts new kernels.
History is stored by the shared REPL in SQLite; drafts live in the frontend.

## Service ownership

- REPL: one session with one persistent polyglot notebook kernel. The shared
  session controller owns language selection, history and meta-commands. The native
  surface preserves drafts and undo state per language. Guest errors preserve
  variables; worker timeout invalidates the session. SDK cancellation currently
  replaces the entire session, losing bindings in all languages.
- LSP/MCP: callers open separate sessions from interactive execution. The broker
  forwards SDK protocol messages and supports named services, polling, and close.
  Actual LSP clients still require Content-Length framing, asynchronous polling,
  cancellation, workspace roots, and capability negotiation. MCP needs its own
  negotiated client transport. A JSON exchange method alone is not an LSP/MCP
  server endpoint.
- Servers with TUI: a separate service class is required. The SDK's persistent
  evaluation kernel is restricted; discovery does not advertise a general
  start/stop/listen/log-stream server lifecycle. Long-running servers must not be
  implemented by disabling the evaluation deadline. Establish the supported
  embedded job/server contract first, then add lifecycle, readiness, log bounds,
  stop/restart, port ownership, and host-side Tern surfaces. Keep that worker
  separate from language tooling and interactive kernels.

The current window launcher refuses remote hosts. Remote launch support needs
host-side discovery of broker binaries, configuration and a compatible SDK; it
must not silently run a remote pane's code locally.

## Shared implementation

`third_party/studio-embed` is a pinned snapshot of Studio's standalone embedding
crate, with the small process-group lifecycle adaptation recorded alongside it.
This avoids a second C ABI implementation or importing Studio's Tauri/editor
layers. The long-term shared seam should be an independently versioned embedding
host crate consumed by both applications. SDK archive verification, updates and
release packaging belong above that crate; this repository initially consumes
an explicitly selected, complete SDK directory.

Published Tern contracts: [blocks](https://docs.stencil.so/tern/guides/blocks.html),
[process API](https://docs.stencil.so/tern/reference/api-shared.html),
[plugin SDK](https://github.com/stencil-hq/tern-sdk).
