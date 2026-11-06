# Native editor inspection

Status: proposed Tern SDK extension, audited against Tern 0.9.12 and the installed
plugin declarations on 2026-11-05. None of the proposed APIs below are implemented
or advertised by this plugin. This refines the document/inspection milestones in
[the project session plan](../PROJECT_SESSION_PLAN.md).

Upstream proposal: [stencil-hq/tern-sdk#263](https://github.com/stencil-hq/tern-sdk/issues/263).

The integration should enhance Tern's existing file editor. Tern owns buffers,
undo, editing, navigation, layout, accessibility, and rendering. Elide owns test
measurements, debugger control, source attribution, and instrumentation. Luau
connects providers to the project session; it does not own another source buffer.

## What exists

| Facility | Available now | Missing for native source overlays |
| --- | --- | --- |
| Native documents | `cx.docs:open/read/edit/save`, native undo and dirty state | Exposed revisions, atomic snapshot/change subscription, annotation providers |
| Native profiling | `cx.procs:profile(pid, {seconds})` opens Tern's profile block | Returned function counts have no source URI/line identity |
| TSP editor nodes | Decoration, gutter, and virtual-line primitives | They belong to program-owned editor nodes, not native file buffers |
| Guest debugging | Elide Graal DAP/CDP launch facilities | Project-owned adapter client, stop state, native breakpoint/stack UI |
| JVM debugging | JDWP launch for run/test | A JVM debugger adapter behind the shared controller |
| Coverage | JS LCOV and JaCoCo analysis | Versioned line/branch projection, correct union/deduplication, native provider |
| Source profiling | Elide OTLP guest profile source locations | Loaded-source identity, completeness, aggregation, native heat provider |

The native document API is documented in the [Tern window API](https://docs.stencil.so/tern/reference/api-window.html).
[TSP editor decorations](https://docs.stencil.so/tern/elements/input.html) are useful
rendering primitives, but replacing the native file editor with a custom TSP
editor would duplicate document ownership. Canvas panels also exclude editor nodes.

## The first vertical slice

Deliver **run tests with coverage → select a file → see measured lines in the
native editor → edit → see the measurement become stale → rerun**. Include both
JavaScript and the Kotlin/JUnit workflow. Debugging and hotness then reuse the same
source/provider contract instead of each inventing its own editor integration.

Tern changes:

1. Expose an atomic document snapshot plus ordered change subscription.
2. Add owner-scoped, revision-checked annotation layers to native file editors.
3. Expose source reveal and annotation/gutter interactions.

Elide changes:

1. Project in-memory coverage analysis into immutable line/branch records with
   run identity and the actual measured source identity.
2. Fix coverage aggregation before presenting it as a reliable line overlay.
3. Publish bounded artifact references/events through the shared project service.

Plugin changes:

1. Attach the document and annotation providers to the explicit project binding.
2. Add coverage controls to the existing Tests/workspace surfaces.
3. Capability-gate native overlays. Until Tern exposes the provider API, offer
   source navigation and measurement detail in native panels, without claiming
   those panels are editor gutters.

## Proposed generic SDK contract

These are API concepts, not callable names in the current SDK.

| Operation | Required semantics |
| --- | --- |
| Attach documents | Return a snapshot and event cursor atomically; subsequent ordered events cannot miss changes between read and subscribe |
| Read document | Return document ID, overlay ID, URI, language, revision, exact text/digest and dirty state |
| Register provider | Allocate an owner-scoped handle for supported annotation kinds and bounded interaction callbacks |
| Replace layer | Atomically replace one document/layer generation only if its expected document revision and measured content identity still match |
| Clear/dispose | Remove the owner's layer; unloading/reloading/disconnecting cannot leave active-looking stale markers |
| Reveal source | Reveal a URI/range with source identity, focus policy, and explicit current/historical/unavailable outcome |
| Handle interaction | Deliver gutter toggle, annotation hover/action, and range context events with document revision and stable item ID |
| Apply edits | Compare-and-swap on exposed revision; preserve native undo and report conflicts rather than overwriting newer edits |

Document revisions are opaque strings, not floating-point counters or timestamps.
Split views of one buffer share its identity. Divergent unsaved buffers get distinct
overlay IDs even when their file URI matches. Rename, delete, external modification,
save and close are explicit events. Subscription overflow requires a resnapshot;
silently skipping changes is invalid.

Each measurement references project/session incarnation, workload/run, source URI,
loaded content digest, and any generated/original source-map identities. A file
path alone is not proof of which source executed. Capture content identity from
the compiler/runtime source artifact or an immutable execution snapshot; hashing
today's file after execution cannot prove that it is the measured version.

Elide already has `SourceAnalysis.Document.contentDigest()`: SHA-256 over big-endian
UTF-16 code units, including unpaired surrogates. Reuse or explicitly adapt this
existing convention; tag the algorithm/encoding and do not silently compare it
with a byte-level disk digest. Preserve line-ending differences. Native provider
ranges should use a declared coordinate convention; a proposed default is zero-based
lines and UTF-16 columns with exclusive ends. DAP, LSP and runtime adapters convert
their negotiated conventions at the boundary.

Publication includes both the measured source digest and the native buffer revision
observed during preparation. Tern checks both at application time. On mismatch,
reject publication and return the current revision; keep the result available as
historical data. A visible layer becomes stale immediately after a text edit.
Breakpoint *intent* may track edits through native anchors, but verified runtime
bindings do not silently move with those anchors.

Bound layers by document and item count. Send visible ranges on demand for large
files. Coalesce updates by generation and reject late generations; do not append
unbounded per-line events. Layer teardown also cancels subscriptions. Annotations
carry data and registered action IDs, never executable scripts or arbitrary HTML.

## What the editor shows

| Layer | Presentation | Meaning |
| --- | --- | --- |
| Debugger | Breakpoint gutter, current execution arrow/range, bounded hover values | Requested/verified/unbound breakpoints; exact paused source and stop identity |
| Coverage | Quiet line/branch gutter marks, optional uncovered-line shading | Covered, uncovered, partial branch coverage, excluded, or unknown |
| Hotness | Optional intensity strip and hover breakdown | Sampled self/inclusive share, call count, or measured duration, explicitly labeled |
| Diagnostics | Native ranges and related-source actions | Diagnostics from semantic tools or attributed runtime observations |

Keep lanes independent: coverage cannot hide a breakpoint or execution marker.
Prioritize the current stop and breakpoint affordances over optional heat shading.
Use labels/icons alongside color, support keyboard actions and reduced motion,
and preserve caret, selection, undo and scroll during provider updates.

The surrounding native Debug, Tests and Observe surfaces hold lists, controls and
detail. The editor presents source-local context. Agent inspection uses the same
project state as those views; attaching another observer does not resume execution.

## Debugging semantics

A gutter click requests a breakpoint from the project debugger controller. Render
it as pending until the adapter acknowledges a verified location or an unbound
reason. Conditional, log and exception breakpoints appear only when supported.
Debug launch is the first target; late attachment is a separate capability.

Scope frames and variable handles to a debugger generation and stop epoch. Resume
invalidates them. Control requests include that epoch and the controller lease so
a delayed agent action cannot resume a later pause. Native inline/hover inspection
uses bounded passive previews; invoking getters or evaluating guest code is an
explicit operation, not a rendering side effect.

When the runtime loaded older source than the open buffer, reveal the historical
source when available. Otherwise show that source is unavailable. Never point the
current execution arrow at a merely similar line in edited code.

## Coverage and hotness semantics

JaCoCo report files are optional: `--coverage` does not guarantee an XML file.
Elide's shared JVM coverage rows currently omit line detail, and its aggregate
merge selects a better-covered row rather than performing a proper coverage union.
Project the existing JaCoCo analysis directly, preserving executable lines and
branch covered/missed counters. Do not present binary coverage as an execution
count. Preserve JS measurement semantics rather than inventing parity across engines.

Deduplicate shard/attempt records and combine only compatible measurements of the
same source version. Uninstrumented, filtered, incomplete and unavailable data are
not zero coverage. Test-to-line attribution is a separate capability; it cannot
be inferred from a file's aggregate coverage.

Tern's current native profile result contains function self/total sample counts,
not source lines. Elide's OTLP guest profile data retains source locations, while
some CLI profiling paths discard them. Preserve those locations through a shared
profile artifact instead of guessing hot lines from function names. Unmapped native
frames remain valid profile data but do not become source decorations.

The current inspection receiver accepts OTLP traces/logs, not profiles. Guest
sampling currently starts from runtime initialization settings, and Insight's
existing MCP operation creates a fresh execution context. Profile ingestion and
live collection/attachment controls need explicit lifecycle work before the UI
can promise on-demand instrumentation of an already running project workload.
Python capabilities depend on the installed runtime; current JS/JVM test coverage
must not be advertised as universal polyglot coverage.

Show sample period/window, sample totals, dropped records, attribution scope and
self/inclusive semantics. Sampling share is not exact elapsed time; execution
counts are not CPU cost. Insight instrumentation can supply separate call/line
observations where supported, with explicit overhead controls, bounded aggregation
and cancellation. Do not emit one OTLP event per execution just to animate a gutter.

## Acceptance gates

- JS and JVM fixtures produce real line/branch detail; missing optional reports do
  not produce false zeroes. Replayed shards and separate runs do not inflate counts.
- Editing an observed line invalidates its measurement before the next paint;
  stale publication cannot restore it. Undo can restore compatibility only after
  content identity is checked again.
- CRLF, Unicode, generated sources, rename, unsaved overlays and divergent windows
  preserve source identity and correct range conversion.
- Requested versus verified breakpoints are visible; stop/resume rejects stale
  handles and preserves one controller with multiple observers.
- A known CPU-heavy function is hot in a source-aware sampled profile; unsupported
  line attribution stays unknown. Count-based instrumentation is labeled separately.
- Provider disposal, plugin reload, process exit and reconnect remove or explicitly
  stale their layers without discarding user edits or resetting pane layout.

The sequencing is coverage, debugger stop/breakpoint integration, then sampled
source heat and targeted Insight observations. Native profiling panels can be
integrated independently while the editor provider contract is developed.

## Runtime audit references

- [Debugger instruments](../../elide/packages/base/main/dev/elide/engine/DebuggerComponent.kt)
- [Shared coverage aggregation](../../elide/packages/base/main/dev/elide/tooling/testing/TestCoverage.kt)
- [JaCoCo projection](../../elide/packages/base/main/dev/elide/tooling/jvm/test/JvmTestCoverageService.kt)
- [Source-aware guest profiles](../../elide/packages/base/main/dev/elide/engine/TelemetryProfilesComponent.kt)
- [Current inspection receiver](../../elide/crates/cli/src/inspect/server.rs)
- [Insight execution](../../elide/packages/base/main/dev/elide/project/agents/debug/DebugMcpContributor.kt)
- [Document digest convention](../../elide/packages/base/main/dev/elide/engine/analysis/SourceAnalysis.java)
