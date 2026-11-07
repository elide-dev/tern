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
- **Opens.** The workspace route redirects only `files` opens inside a workspace tab
  into its editor. `palette` opens are left to Tern (the control socket's `file open`
  arrives that way, and claiming it broke `tests/coverage.py`), except `elide.pkl`:
  chosen from the palette, it opens that project's workspace, or focuses the open one.
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
| `elide://source?path=<abs>[&root=<abs>][&line=<n>[&col=<n>]]` | Opens the Elide source block on the file at `line` when it is a JavaScript, TypeScript, Python or Kotlin source in a known project (`root`, or a detected project containing `path`) and the plugin is configured; otherwise opens the file in Tern's editor at `line`. |
| `elide://debug?root=<abs>&path=<abs>[&line=<n>]` | Launches the project debugger for `root` with `path` as its source. |
| `elide://tests?root=<abs>` | Opens the project's test runs for `root`. |
| `elide://help?topic=<slug>` | Runs `<runtime> --ignore-version help elide://help?topic=<slug>` in a new pane beside the link's pane (a new tab when the link came from no pane); `elide help` resolves the URL to its topic. |

Rules, implemented by the pure parser `plugin/lib/links.luau` (unit-tested by
`lua tests/links.lua`) and checked by the window route:

- Keys and values are percent-decoded (`%20`, `%CE%BB`). `+` is a literal plus, so
  encode spaces as `%20`. Unknown keys are ignored; a repeated known key, a malformed
  escape or a decoded control character rejects the URL. Fragments are not allowed.
- `root` and `path` must be absolute with no empty, `.` or `..` segments (a trailing
  slash is dropped), and `root` cannot be `/`. `line` and `col` are positive integers;
  `col` needs `line`.
- Paths are compared as written, so emit canonical (symlink-resolved) paths, as the
  project probe reports roots: `/tmp/x` does not match a root at `/private/tmp/x`.
- `path` must lie strictly inside `root`. A `root` must contain `elide.pkl`. Without
  `root` (`source` only), `path` must lie inside a project this window already
  detected. The linked file must exist. Links act on local hosts only.
- A rejected `elide://` URL is claimed and dropped with an info toast, so it never
  reaches the system's URL handlers; every other scheme returns `nil` to the next route.
- `help` takes no path or root. `topic` must match `[a-z0-9][a-z0-9-]*` after
  percent-decoding and is at most 128 bytes; anything else is rejected like any other
  malformed link. The command line carries a URL rebuilt from the validated slug, never
  the URL as received, and the runtime is the one `config.runtime` names. Elide's native
  help surface puts these links on its internal `href`s, so its own navigation arrives
  here rather than at the program.
- Limits of this version: `col` is validated but not applied (`cx.docs:open` takes a
  line only), `debug`'s `line` is validated but not applied (the debug launcher takes
  no breakpoint), and confinement is lexical: `tern.fs` cannot resolve symlinks, so a
  symlink inside the project that points outside it is followed.

`python3 tests/integration.py --runtime /path/to/elide` drives the lenses, links (through
`tern ctl open-url`, the path the system takes), chrome and `command_finished` in an isolated
desktop window. Plugin lenses need the daemon-backed window; the in-process `tern serve`
harness shows built-in lenses only.

### Source block

`elide.source` is Elide's code editor: a host-half plugin block (`plugin/host.luau`) over a pure
text model (`plugin/lib/buffer.luau`) and helpers (`plugin/lib/source.luau`), both unit-tested
under plain Lua by `lua tests/source.lua`, non-BMP text included. Tern draws every pane from the
surface node tree, so no foreign editor widget can be embedded; the block owns the text and draws
it in Tern's `editor` node with `lang`, a per-line `gutter`, `virt` notes and `decor` ranges.
Offsets are UTF-16 code units.

- **Arguments.** The absolute file, then optionally the project root and a one-based line.
  Without a root the block looks for the nearest `elide.pkl` above the file.
- **Opening.** `elide://source` (above), the workspace toolbar's **Source** button (the workspace
  editor's file), the project menu's **Open Elide source…** and the `plugin.elide.source` command
  (the focused file, else a prompted project path), and "Open with Elide source" from the `files`
  globs in `plugin.toml`. It is not in the palette: it always needs a file.
- **Editing.** The block opts into the `edit` and `undo` features. With Tern's native editing on,
  clicks, drags, ⇧-arrow selection, plain ↑/↓ and ⌘←/⌘→ arrive as `edit` events and Tern draws
  its own selection; everything else, and every key with native editing off, is handled by the
  block: typing and paste, Enter with the line's indentation (one unit more after `{`, `[`, `(` or a
  colon), Tab/⇧Tab indent and outdent (selected lines, or a unit at the caret), Backspace/Delete
  (⌥ or Ctrl for words, ⌘ to the line start; Backspace in leading spaces goes back to the indent
  stop), arrows with ⇧ selection drawn through `anchor`, ⌥/Ctrl word moves, Home (first non-blank,
  then column 0), End, ⌘←/⌘→, ⌘↑/⌘↓, Ctrl+Home/End, Page Up/Down, ⌘A, ⌘C/⌘X (the line without a
  selection), ⌘/ to toggle `//` or `#` comments, ⌘Enter for a new line below. The indent unit is
  the file's own (a tab, or its smallest space indent). Undo and redo (⌘Z, ⌘⇧Z, Ctrl+Y, or Tern's
  `undo` event) keep up to 1,000 steps; consecutive typing within a word is one step. Native
  selections are Tern's, so Tab and ⌘/ with a native selection act on the caret line only.
- **Saving and the disk.** ⌘S (or **Save**) writes through `tern.fs.write`, keeping the file's
  CRLF or LF endings, and asks before overwriting a file that changed on disk since it was loaded.
  Unsaved changes show as an **Unsaved** badge, a **Modified** status segment and a `●` in the
  pane title. `tern.fs` has no `stat`, so the block re-reads the file every 2 s and compares it with
  the text it last loaded or saved: a clean buffer reloads (as one undoable step, with a toast), a
  dirty one gets an error-toned confirm strip in the dock (Reload with Enter, keep editing with
  Escape). Running coverage or launching the debugger with unsaved changes asks to save first
  (accent strip, **Save and run**/**Save and launch**). Escape backs out one layer (confirm strip,
  find or go-to-line, the overlay) and then closes the block, asking first when there are unsaved
  changes. Tern has no block-close hook, so closing the pane itself cannot ask; unsaved text up to
  64 KiB is kept in the block's saved state and restored as one undoable edit after a plugin reload
  or daemon restart.
- **Find and go to line.** ⌃F or ⌘F opens a find field in the dock (`input` with the search icon;
  in the desktop harness ⌘F did not reach the block, presumably taken by a window binding, so
  the harness uses ⌃F). Matches are
  `mark` decorations (the current one `mark accent`), case-insensitive unless the query has a
  capital, at most 2,000; Enter and ⇧Enter select the next and previous match; Escape closes it.
  `/` is not a find key, because it types a slash in the editor. ⌃G opens go to line
  (`line` or `line:column`). Program moves (find, go to line, a new debugger stop, a linked line)
  set `topline` for one frame; otherwise Tern keeps the caret in view.
- **Chrome.** The block is laid out like an IDE editor and shows a control only when it can act.
  One toolbar row at Tern's `md` height: a `path` `breadcrumb` (project and file, the folders
  between folded into "…"; a parent crumb opens that folder), a `warning` `●` while dirty, and the
  overlay's state `badge` ("Paused at 9", "80% covered"); at the right the overlay switch (only the
  overlays that can act: Coverage with a project, Debug with a project and a JavaScript, TypeScript
  or Python source; Hotness is hidden while no profile data exists; nothing when only None is left),
  the overlay's controls, an editor well of icon buttons (Save `save`, only while dirty and then the
  screen's `primary` unless an overlay shows its own; Find `search`; Go to line `hash`; Soft wrap
  `corner-down-right` with `on`; Edit in Tern `open`, the escape hatch to Tern's own editor) and a
  `keyboard` `menu` listing only the shortcuts that act now (its rows run them). The editor well
  shows its shortcuts in tooltips and that menu. Split panes (under about 150 columns) get a compact
  row so it does not wrap: the overlay switch becomes a well of icon toggles (None `eye-off`,
  Coverage `list-checks`, Debug `bug`, the active one `on`; a `menu` was tried, but in the harness a
  click on its row only closed it), the editor well keeps only Save (its commands stay in the keyboard menu), the debugger's keycaps move
  into the tooltips, and the state badge leaves it to the status bar while the debugger's wells
  show; as a last resort the row wraps rather than clips. Below it `gap: "sm"` separates the
  toolbar, the editor (the only element that grows, with `maxLines` from the pane's rows) and the
  dock, which holds only open strips (find, go to line, confirm) and a `status` bar whose segments
  appear only when they mean something: the path; the overlay state; `Ln, Col`; the selection
  length; language; indentation; LF/CRLF; Modified. Nothing is ever inserted above or below the editor, so the
  code never moves: every overlay state (attaching, running tests, fetching coverage, no coverage
  yet, not measured, launching, paused elsewhere, failures) is the state badge's text, with details
  in its tooltip, and the status bar's overlay segment; actions sit in the toolbar (Run with
  coverage, `primary` while there is no coverage; Retry after a failed attach). The harness checks
  the first line's text rect before, during and after a coverage run. The gutter is `[sign] [number] │ ` (one sign cell, numbers
  right-aligned to the widest, a cell of space on each side, a `dim` box-drawing hairline that spans
  the line's height, one cell before the code), identical in width on every line; the caret line's
  number is `strong`. The dirty marker is a small `•` in `warning` with the tooltip "Unsaved
  changes". Rows cannot get more vertical room without changing the editor's line height: Tern's
  renderer does not grow a line box for a padded inline-block, so the padding overlapped the next
  row instead. ⌥1 to ⌥3 pick an available overlay (in the desktop harness they did not
  reach the block, presumably taken by window bindings, so the harness uses the switch).
- **Stylesheet.** `plugin/styles/source.css` (the manifest's `styles`) is scoped to
  `[data-surface="plugin.elide.source"]` and colored only with Tern's tokens; it is the design
  guide's sanctioned escape hatch where no prop exists. It removes the regions' side padding so the
  editor runs full-bleed, keeps Tern's vertical rhythm with 6 px × 10 px padding on the toolbar and
  dock fields, and draws the line tints below.
- **Line tints, and overlays that move nothing.** Probed in the editor kind: `mark` is the only span
  token that paints a background, untoned; `ins` colors text, `del` strikes it, tone tokens color
  text, and unknown tokens are dropped. Every line
  (in files up to 600 lines; past that only tinted lines) carries one `mark <tone>` run on its first
  character at all times, `mark dim` when no overlay applies, so switching overlays only changes a
  token: no run, sign cell or note slot appears or disappears and no text moves (the harness checks
  the first line's text rect across None, Coverage, Debug and None). The stylesheet gives the run a tint mixed into the page color
  and forced opaque (the glass themes make the page translucent, and translucent copies stripe), 1 px of vertical padding (so adjacent rows meet without a hairline, without changing
  the line's layout) and zero-spread shadows of the same tint every 0.9ch to the right, which overlap
  so no seams show; the scroller clips the band, and later text, the caret and the end-of-line note
  paint over it. Other attempts left visible blocks or did not render: a background on every run
  broke at spaces and token edges; copies every 1ch seamed at fractional pixel edges; a single
  `100vw` shadow showed nothing past the text; and a `::before` band is not positioned against an
  inline run by Tern's renderer: with `top: 0; bottom: 0; left/right: -100vw`, `z-index: -1` and an
  isolated text block, the band covered the whole text block and painted over the text. The harness
  checks the band in the screenshots' pixels: a tinted row differs from an untinted one past its
  text, the neighbouring row stays untinted, and the text stays visible over it. `dim` is transparent. Tints fade over 140 ms (`ease-out`), not under reduced motion.
  Covered lines are `success`, `inferred` lines (closers, blanks and comment-only lines
  that inherit their block's coverage, a state the coverage page is gaining) the success tint at half
  strength, partial `warning`, uncovered `error`, lines changed since the measurement `muted`;
  states the block does not know are treated as unmeasured, a breakpoint line `error` and the paused line a stronger `accent`.
- **Large files.** The block sends the whole text, because the node needs it for offsets, and
  refuses files over 512 KiB (the `tern.fs.read` limit it passes) with an `empty` state that says
  so; unreadable and non-UTF-8 files get the same. Tern's highlighter recolors the whole text on
  every change to the editor node, which measured 0.1 s per keystroke at 300 lines, 0.3 to 0.6 s at
  900, 3.5 s at 2,000 and over 10 s at 5,000. Files over 600 lines are therefore shown without
  `lang` (the status bar says "no highlighting"), which keeps 5,000 lines at about 0.05 to 0.4 s,
  and the caret-line accent (which resends the gutter) stops past 2,000 lines. Upstream item for
  Tern: highlighting incrementally, or not re-highlighting on caret-only
  prop changes, would let the threshold go.
- **Attachment.** With a root the block attaches through the same broker state as the native
  project surfaces (`project_attach`), renews its lease with `project_snapshot` every 30 s, and
  detaches on `pane_exited` or when a background callback finds its pane gone. The binding is not
  saved; a restarted block attaches again.
- **Overlays survive edits.** Each overlay keeps a line map in the buffer (current line to the line
  of the text it was measured against), updated by every edit: lines inserted above shift the
  marks, edited lines keep theirs, deleted lines drop theirs. Breakpoint lines move the same way.
  A coverage tint whose line text differs from the measured text turns `muted`, and
  when the artifact's `sourceDigest` (`sha256-utf16be`: sha256 of the UTF-16BE source, checked with
  the system's `shasum`/`sha256sum`) does not match the file on disk every tint does and a strip
  says "Coverage measured an older version".
- **Coverage.** The newest snapshot run with `options.coverage` is paged through
  `project_coverage_page` until the file whose path matches, then its lines through `next`. The
  tints sit on the same editor, which stays editable in every overlay; partial lines carry their
  branch count in `virt`. The badge and status bar show the file's percentage. The artifact records
  only covered/uncovered and branch counts (no hit counts), and the JavaScript producer reported no
  branch counts for the harness's ternary, so partial lines have not been seen with real data yet.
  With no coverage run the overlay offers **Run with coverage** (F5; `project_test` on the root with
  `coverage: true`) and polls each second until it finishes; F6 refreshes.
- **Debug.** While active the block polls `project_debug_snapshot` (`compact`) every 500 ms and
  re-renders only when the revision, pending flag, controller or error changes. The stop is a `▶`
  `accent` sign, its line number in `accent`, the line's `accent` band and a ` paused` note; a
  breakpoint is a `●` `error` sign with its number in `error` and a light `error` band (`○` and `warning` with the adapter's
  message while unverified); where both fall on one line the stop wins. The caret jumps to each new
  stop and F7 returns to it. F9 toggles a breakpoint on the caret line: before a launch it is kept
  locally and passed to `project_debug_launch`; with a live target the file's replacement `lines`
  (mapped back to the launched text) go through `project_debug_request` `breakpoints`. Debug
  controls follow the session: none outside the Debug overlay; a single `primary` Launch (`play`,
  F5) while no target exists; and while a target is launched, running or paused, the Debug
  surface's two wells of icon-only buttons with keycaps: run control (Resume `play` F5, `primary`
  only while it can act; Pause `pause` F6; Stop `stop` ⇧F5, `danger`) and stepping (Step over
  `redo` F10, Step into `arrow-down` F11, Step out `arrow-up` ⇧F11), each with `aria`, a `title`
  naming the action and key, and a `disabled` reason. F6, F7, F10, F11 and ⇧F5 act only while a
  target exists. Test files launch in `test` mode, all with `stop_on_entry` false. Control needs
  `controller == "you"`. Every command carries a fresh UUID and is resent with the same UUID and
  payload only when no response arrived.
- **Hotness** is hidden. Neither the broker nor
  `elide-project-session` keeps source-located profile samples, so a read-only
  `project_profile_page` op cannot be added from existing data. The missing piece is a profile
  collector in the project session that records samples by `{path, line}` for a run, and a
  `project_profile_page` op paging per-line sample counts like `project_coverage_page`; the block
  would then draw per-line share as `▁▂▃▅▇` gutter glyphs toned `warning`/`error`. Until then the
  Hotness tab is hidden.

`python3 tests/source.py --runtime /path/to/elide [--sdk /path/to/embedder]` opens the block from
an `elide://source` link in an isolated desktop window and drives it by keys: go to line, typing,
save (checked on disk), undo and redo, auto-indent, a reload after an outside write, find, a
coverage run from the block with covered and uncovered marks and their behavior across an unsaved
edit, a breakpoint with F9 and a launch with F5 checked against the broker's own snapshot, a large
file taking edits without highlighting, and an oversized file's empty state. It takes light and
dark screenshots, split beside a terminal and wide in a tab of its own.

### Context-sensitive controls

The window half shows a control only when it can act or has something to show:

- Status segments appear only inside a detected project, and the outcome segment only
  after an `elide test`, `build` or `run` finished in that pane.
- The workspace toolbar follows its editor's file on `focus` and `title` events (no
  timer, and a redraw only when the file changed). **Source** appears only for a file
  the source block shows. **Debug** stays, because without a debuggable file it opens
  the debugger's target picker; its tooltip says which it will do.
- The project menu lists **View test runs** only once the project has a `run-*` report
  directory under `.dev/reports/tests/tern/`.

Follow-ups this leaves: the menu does not ask the project host for live runs (a run
whose reports were deleted still has history in a running host); Build and Run stay
visible in projects without a JVM or script entry point, which would need the manifest
evaluated; and Files pane and palette commands are not filtered by project yet.

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
