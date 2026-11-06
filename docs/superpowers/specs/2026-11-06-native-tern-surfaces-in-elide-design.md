# Native Tern surfaces in the shipped `elide` binary

Date: 2026-11-06. Repositories: `elide` (worktree `.worktrees/tern-native-surfaces`,
branch `feat/tern-native-surfaces`, from `feat/tern-integration`) and `elide-tern`.

## Intent

Make Elide a first-class Tern Surface Protocol (TSP) program. Today the REPL and
serving dashboards already negotiate TSP inside the shipped `elide` binary, but the
Tests, project Tests, and Debug surfaces, plus the embedded-SDK REPL host, exist only
as cargo example binaries that this plugin copies into `dist/`. The shipped binary
never enters them, so `elide test` typed into a Tern pane stays plain text, and the
plugin must ship five private launchers beside the broker.

After this change:

1. `elide test` in an interactive terminal probes for TSP and opens the native Tests
   surface, falling back to the existing output when Tern is absent, output is
   redirected, or a reporter was requested.
2. `elide tern <surface> …` (hidden, Advanced) hosts every Tern-only surface:
   `repl` (embedded SDK over the broker), `serve`, `test`, `project`, `debug`. The
   plugin launches `elide tern …` by default and needs no separate launchers.
3. The example binaries remain as thin wrappers over the same library functions so
   the plugin's test harness and packaging keep working without a native-image build.
4. The plugin's dead textbox REPL block is removed. A host lens renders JSON output of
   ordinary `elide` commands as a native tree through `tern.parse.json_tree`.

## Goals, non-goals, anti-goals

Goals: zero-launcher integration; negotiated TSP with faithful fallback; one code path
for each surface whether reached by `elide test` or `elide tern test`.

Non-goals: moving the broker/worker into Elide; LSP, coverage gutters, MCP, notebook
kernels (no Tern extension points exist); static linkage of the embedded SDK into the
plugin; a new Tern release dependency.

Anti-goals: TSP frames in redirected output, in TAP reporters, or in guest stdio;
recursion when the native Tests surface spawns `elide test` as its child; inferring
Tern from an environment variable without negotiation.

## Constraints (from `project/features/27-structured-surfaces.md`)

- Negotiate capability; never infer solely from `TERM_PROGRAM`.
- Unsupported terminals keep the existing frontend.
- Redirected output and machine-readable reporters never receive TSP frames.
- Interactive frontends own terminal input (`InputLease`) and drain replies on exit.

## Decisions

**`elide test` entry.** In the native entry's command match, before the engine path:
when stdin/stdout are interactive, `ELIDE_JOB_PARENT_PID` is unset, and the argv after
`test` has no `--reporter`, call `elidecli::testing::run(current_exe, &native)` where
`native` is derived by `testing::native_test(args, cwd)`. `run` returns `Ok(false)` when
the TSP probe gets no reply; the arm then falls through to the engine unchanged.
Passthrough: every token after `test` except the first bare path token is forwarded to
the child verbatim; `--coverage` anywhere in argv pre-selects coverage collection.

**`elide tern` subcommand.** `TernArgs { surface: TernSurface }` with variants
`Repl { broker, sdk, state, language }`, `Serve { runtime, subject, extra }`,
`Test { runtime, subject }`, `Project { broker, state, runtime, root, subject }`,
`Debug { broker, state, runtime, root, source }`. It is dispatched early, beside
`Studio`, because it never needs the engine. Exit code 2 with a message when Tern is
absent (the surfaces are Tern-only by definition). The embedded REPL host (the broker
engine from `crates/repl/examples/embedded_surface.rs`) moves into
`crates/cli/src/tern/embedded.rs`.

**Examples.** `crates/cli/examples/{embedded_surface,serve_surface,test_surface,
project_surface,debug_surface}.rs` delegate to `elidecli::tern`. The repl crate loses
its example; the Makefile builds `-p cli --example embedded_surface` so the output path
is unchanged for `package-tern.py` and this plugin's Makefile.

**Plugin launch.** `window.luau` builds argv as `{runtime, "tern", kind, …}` unless
`config.<kind>` names an explicit launcher. Config overrides stay for development
against the example binaries. The `runtime` must be a build that has `tern`; an older
runtime prints the usage error in the pane, which is the honest failure.

**Lens.** `plugin.toml` gains `host = "host.luau"` and `[[lenses]] id = "json"` matching
`elide project export*`, `elide * --json`, `elide * --json *`, `elide --json *`. The
host collects stdout lines and returns `tern.parse.json_tree(text)` or nil.

## Left to the builder

Exact i18n handling for the hidden command's help text (plain string, as `studio`
does); the `usage` derive details for a subcommand enum with positional paths.
