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
