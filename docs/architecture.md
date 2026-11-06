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

## Window integration points

The window half also plugs into Tern's chrome, events and routes. None of these
handlers start a process: formatters have a 4 ms budget and event and route handlers
50 ms, so they read only state the asynchronous project probe already cached.

- **Chrome.** `tern.chrome.tab_title` names a tab after the detected project of its
  focused pane, unless the user named the tab. `tern.chrome.program_icon("elide",
  "bolt")` gives `elide` panes their own icon. The status segment opens the project
  menu on click (`plugin.elide.project`) and is followed by the last `elide test`,
  `build` or `run` outcome in that pane.
- **Events.** `command_finished` recognises `elide test|build|run` lines (leading
  `VAR=value` words skipped, quoting not interpreted), records the outcome and calls
  `tern.chrome.refresh()`. A failing `elide test` (status 1 to 127) toasts "Tests
  failed" with the subject words, or the pane's directory when there are none;
  statuses from 128 up are interrupts and stay quiet.
- **Opens.** The workspace route redirects `files` and `palette` opens inside a
  workspace tab into its editor. Outside a workspace, `elide.pkl` chosen from the
  palette opens that project's workspace, or focuses the one already open.
- **Lenses.** The host half adds `build` (`elide build`, `elide build *`) and `tap`
  (`elide test --reporter=tap*`, `elide test * --reporter=tap*`) beside `json`. Each
  keeps at most 20,000 lines and 4 MiB and falls back to raw output beyond that. `build`
  reads the builder's `error: …` / `In file: path:line:col` / numbered excerpt form and
  compilers' one-line `path:line[:col]: severity: message` form into
  `tern.ui.diagnostic` cards (200 at most, then "… N more"); with no diagnostic it
  shows raw output. `tap` shows `tern.ui.test_summary` and a table of top-level `ok` /
  `not ok` lines (5,000 rows at most) with each failure's YAML `message`.

### `elide://` links

`tern.route.link` claims every `elide://` URL, whether it is an OSC 8 hyperlink in a
terminal, an `href` in a surface, or a URL opened through `cx:open`. This is the
contract Elide emits against:

| URL | Effect |
| --- | --- |
| `elide://source?path=<abs>[&root=<abs>][&line=<n>[&col=<n>]]` | Opens the file in Tern's editor at `line`. |
| `elide://debug?root=<abs>&path=<abs>[&line=<n>]` | Launches the project debugger for `root` with `path` as its source. |
| `elide://tests?root=<abs>` | Opens the project's test runs for `root`. |

Rules, implemented by the pure parser `plugin/lib/links.luau` (unit-tested by
`lua tests/links.lua`) and checked by the window route:

- Keys and values are percent-decoded (`%20`, `%CE%BB`). `+` is a literal plus, so
  encode spaces as `%20`. Unknown keys are ignored; a repeated known key, a malformed
  escape or a decoded control character rejects the URL. Fragments are not allowed.
- `root` and `path` must be absolute with no empty, `.` or `..` segments (a trailing
  slash is dropped), and `root` cannot be `/`. `line` and `col` are positive integers;
  `col` needs `line`.
- `path` must lie strictly inside `root`. A `root` must contain `elide.pkl`. Without
  `root` (`source` only), `path` must lie inside a project this window already
  detected. The linked file must exist. Links act on local hosts only.
- A rejected `elide://` URL is claimed and dropped with an info toast, so it never
  reaches the system's URL handlers; every other scheme returns `nil` to the next route.
- Limits of this version: `col` is validated but not applied (`cx.docs:open` takes a
  line only), `debug`'s `line` is validated but not applied (the debug launcher takes
  no breakpoint), and confinement is lexical: `tern.fs` cannot resolve symlinks, so a
  symlink inside the project that points outside it is followed.

### Why workspaces don't use `cx.layout:tab`

`cx.layout:tab(spec)` builds a tab in one call, but its leaves launch only a shell,
a command or a plugin block. The workspace's editor is a `cx.docs` document and its
toolbar an owner-tagged `cx.canvas` panel; neither is a launch. Building the tab with
`layout:tab` would still need `cx.docs:open` and `cx.canvas:open` afterwards, aimed at
panes the spec created, which is longer than the current sequence of opens and splits
and gives the same result. The workspace keeps the incremental calls.

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
