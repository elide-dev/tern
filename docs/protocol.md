# Broker protocol v1

Run `dist/elide-tern-broker request /private/state/directory` with one JSON request
on stdin. The client starts/reuses the broker, writes a framed request over its
Unix socket, and prints one JSON response. Configuration and source travel as
data, not command-line arguments. Response envelopes are
`{"ok":true,"result":...}` or `{"ok":false,"error":"..."}`. Transport/usage
failures exit nonzero. SDK errors use the error envelope.

| Operation | Fields | Result |
| --- | --- | --- |
| `ping` | none | protocol version, broker PID, session count |
| `open` | `sdk`: complete extracted SDK directory | opaque `session` string |
| `discover` | `session` | languages, named language servers, LSP/MCP availability |
| `open_kernel` | `session`, `language` | opaque decimal `kernel` string |
| `evaluate` | `session`, `kernel`, `language`, `source` | value, display, stdout, stderr, truncated |
| `protocol` | `session`, `kind`: `lsp` or `mcp`, optional `service`, `json`, `poll`, `close` | JSON-RPC message strings |
| `close` | `session` | empty object |

An open response establishes a worker process, not SDK readiness. `discover` or
`open_kernel` completes the native handshake under the exchange deadline. Use language `polyglot` when opening a notebook kernel; its evaluation requests
select the cell language. Language-specific kernels require matching cell languages. SDK limits and capabilities remain
runtime-authoritative.

Protocol `json` contains one serialized JSON-RPC message without stream headers.
Use `poll: true` without JSON to drain asynchronous messages; polls currently do
not wait. `close: true` closes the selected SDK channel. Empty `service` selects
the SDK's built-in adapter; discover named services before selecting them.
Do not poll in an unbounded tight loop. Each session permits one request at a time.

```sh
printf '%s' '{"op":"ping"}' | dist/elide-tern-broker request /private/state/directory
```

The request helper bounds stdin and checks its shape before starting the broker.
The broker revalidates all socket input. Local state paths must be short enough
for Unix sockets and have mode 0700; symlinks and foreign-owned directories are
rejected. The initial transport is Unix-only; Windows and iOS are unsupported.
# Shared project test sessions

These additive operations use the existing private broker socket and response envelope.
They are separate from SDK runtime/kernel session handles and do not initialize the SDK.

| Operation | Fields | Result |
| --- | --- | --- |
| `project_attach` | absolute `root`, absolute or PATH `runtime` | `binding`: the result itself is `{session, epoch, lease}` |
| `project_snapshot` | `binding`, optional `after` revision | versioned snapshot, or null when unchanged |
| `project_summary` | `binding` | compact run counts, handles, reports and two failure previews per run |
| `project_test` | `binding`, UUID `command`, `subject`, optional `options: {coverage: boolean}` | `{run}` |
| `project_coverage` | `binding`, `run` | immutable bounded coverage artifact, or null if unavailable |
| `project_coverage_page` | `binding`, `run`, optional `file`, `offset`, `limit` | bounded file listing or measured lines, with `next` offset |
| `project_cancel` | `binding`, `run` | empty object; cancellation is asynchronous |
| `project_detach` | `binding` | empty object; a finite test continues |

Use the entire binding returned by attachment. Each view has its own 60-second lease;
snapshot reads renew it. IDs from an old host epoch or another project are rejected.
Subject paths resolve inside the attached root and must remain there after resolving
symlinks. One active test run per project prevents conflicting writes to build outputs.
The same UUID, subject and collection options return the same run; changing arguments under that UUID fails.

Snapshots include four recent runs with complete aggregate counts and bounded details
for the latest 32 results, raw report paths, status and duration. Unchanged snapshots
return null. Raw artifacts remain under `.dev/reports/tests/tern/`. There is a five-minute
run deadline, 128 retained command IDs per project incarnation, and a two-minute idle
reclamation period. Expired result retries fail explicitly rather than launching again.

Each run includes `options.coverage` and a compact coverage summary. Coverage states
are `not_requested`, `collecting`, `ready`, `incomplete`, `unavailable`, and `error`.
Artifact reads retain measured source identity and never reread current source to
invent it. A digest is optional; missing identity and missing branch counts stay
unknown. Native views fetch the bounded artifact separately from test snapshots.

For agent reads, `project_coverage_page` lists files when `file` is omitted, or
returns lines for the chosen zero-based file index. `offset` defaults to zero and
`limit` to 50 (maximum 100). `next` is the next offset, or null at the end. Indices
are stable within the immutable run artifact. File pages also cap encoded entries at
256 KiB, so use `next` even when fewer than `limit` entries arrive. Each page includes the producer's
`complete` flag; consult the run summary for process and collection status.

This layer reports configuration as `discovered`. It does not evaluate manifests,
resolve workspace dependencies, provide streaming subscriptions, or implement MCP.

## Shared debugging

These operations use the same project binding. Source paths are canonicalized
inside its root. One target may be active per project/runtime session.

| Operation | Fields | Result |
| --- | --- | --- |
| `project_debug_launch` | `binding`, UUID `command`, `subject`, optional `options` | `{generation}` |
| `project_debug_snapshot` | `binding`, optional `compact` | `{debug, controls, controller, grace_seconds}`, or null |
| `project_debug_request` | `binding`, UUID `command`, `request` | empty object; accepted asynchronously |
| `project_debug_takeover` | `binding`, `generation` | empty object; explicit control transfer |

Launch options default to `{mode:"run", stop_on_entry:true, breakpoints:[]}`.
Mode `test` runs the selected JS test file. Breakpoints are `{path, line}` entries
with one-based lines. Debug tests share ordinary tests' output-writer exclusion
across overlapping roots and different runtimes.

A request contains `{generation, stop_epoch, action}`. Action uses a `kind` tag:
`continue`, `next`, `step_in`, `step_out`, `pause`, `stop`,
`stack` with `thread`, `scopes` with `frame`, `variables` with `reference` and
`allow_side_effects`, or `breakpoints` with `path` and replacement `lines`.
Generation IDs belong to launches; stop epochs belong to pauses. Never reuse frame
or value handles after resume. Retain the UUID and exact payload for transport
retries; observe snapshot `last_command`, `pending`, `error`, state and revision
for execution completion. Acknowledgement alone does not mean a step completed.

Snapshots include bounded frames, scopes, values, breakpoint verification, output,
capabilities and explicit truncation. `compact:true` caps encoded snapshots at
512 KiB and may remove trailing entries. `project_summary` includes a small debug
summary. These remain local operations, not a WebSocket MCP implementation.

`controls` is attachment-local; `controller` is `you`, `another attachment` or
`unclaimed`, never another attachment's lease ID. Only the controller may change
execution/breakpoints or request side-effect-capable values. Observers may read
stacks/scopes. `passive_variables:false` requires explicit `allow_side_effects:true`
for values; the current adapter may run guest getters or formatting code. No
automatic watches, arbitrary evaluation or setters are exposed.

Controller detach/lease expiry revokes queued controls and starts 30 seconds for
takeover, then stops the supervised process group. Stop remains available under
queue backpressure. Native UI and Carly use this same model through
`plugins.elide.debug_launch`, `debug_read`, `debug_control`, and `debug_takeover`.
