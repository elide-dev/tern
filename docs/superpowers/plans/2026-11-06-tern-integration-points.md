# Tern Integration Points Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Elide's Tern surfaces look and behave like Tern's own views, and wire the plugin into Tern's routing, chrome, layout, lens and event primitives.

**Architecture:** Elide's Rust surfaces (Tests, project Tests, Serve, Debug) are rebuilt on Tern's page recipe using native node kinds and no stylesheets. The plugin's window half gains routes, chrome formatters, event handlers and more lenses. An `elide://` link scheme bridges plain CLI output to native surfaces.

**Tech Stack:** Rust (`tern-sdk` 0.2.0 via the `elidesurfaces` crate), Luau plugin, Python harness under `tests/`.

**Spec:** The assessment in this session, derived from the Tern docs saved as markdown under
`/private/tmp/claude-501/-Users-sam-workspace-elide-tern/6dc1a6e8-82f4-40f4-8fe6-360f3a19a306/scratchpad/tern-docs/`
(`guides-design.md`, `guides-views.md`, `elements-index.md`, `guides-chrome.md`, `reference-ui.md`, `reference-events.md`, `reference-actions.md`, `guides-layout.md`, `guides-routing.md`). Workers read `guides-design.md` and `elements-index.md` in full before touching a surface. Per-kind props live at `https://docs.stencil.so/tern/elements/<page>.md` (`layout`, `data`, `text`, `lists`, `input`, `motion`, `chrome`, `work`); fetch with `curl -A docs-reader`.

## Global Constraints

- Runtime work happens in the named worktree only. Never edit `crates/surfaces` or any crate outside your module directory; put helpers in your own module.
- Cargo in any Elide checkout needs `PATH=/usr/bin:$PATH` (a mise `cc` shim breaks host linking). Never run `./builder build`; build surfaces with `cargo build -p cli --example <name>` and check with `cargo test -p cli --lib <module>::` and `cargo clippy -p cli --lib --no-deps -- -D warnings` (ignore pre-existing errors in `base`, `debugging/session.rs:137`, `debugging/view.rs`).
- Verification is the plugin harness in `/Users/sam/workspace/elide-tern` (main checkout): `make <shim-target> ELIDE_SOURCE=<your worktree>` copies your example binary into `dist/`, then `python3 tests/<x>.py --runtime <RUNTIME>`. `RUNTIME=/Users/sam/workspace/elide/.dev/scratch/tern-pr/.dev/artifacts/dist/current/bin/elide` (fallback `/Users/sam/workspace/elide/.dev/artifacts/dist/current/bin/elide` if a release build is mid-write). Do not run `make link`, `make build` or any target beyond the ones your task names in that checkout.
- Keep every `data-role` and CSS class the harness queries (listed per task). Adding roles is fine; renaming is not.
- Design rules that apply to every surface: `font: sans` on the surface; a head row (`row` with `justify: between`, title in the `title` token, muted meta, badges and global buttons at the right); a `stats` strip of at most four tiles directly in `main`; `tabs` for more than two panels, only the active view rendered, Tab/⇧Tab switch; the view is a full-width selectable `table` beside the selected item's `card` (`min.w 44ch`, `max.w 56ch`); one `primary` button on screen; `sm` buttons in rows/tables/cards, `md` in the head row and bars; four states (`skeleton`/`shimmer`, `empty`, error `card` with `tone: error` and Retry, success); keys shown via `keys` on buttons and a key legend `text` with `key` spans in `dock`; numbers `align: end` and `mono`; color only through tones and span tokens; no `el`/`html` tables; no stylesheet unless a prop truly does not exist, and then scoped and token-colored.
- Commits: conventional subjects under 72 chars. The Elide repo's hook requires a `project/docs/` change for `feat` commits, so use `refactor(tern): …` for surface rebuilds or touch `project/docs/content/en/guides/repl.md`. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push.

## Review Focus

1. A test run with zero results, a failing run, and a cancelled run each show a designed state, not an empty frame.
2. Narrow panes (80 columns) hide low-priority columns rather than clipping; `grow` is on the name column only.
3. Keyboard: ↑/↓ and j/k move selection, Enter opens, Tab/⇧Tab switch views, Escape backs out one layer, `q` quits only when nothing is left.
4. Older Tern without a kind (e.g. `stacktrace`) falls back: check `session.caps().has_kind(..)` before using newer kinds, as the REPL does for `json`.
5. The `elide://` link route never opens a file outside the project root it was asked about, and ignores malformed URLs.

---

### Task 1: Tests surfaces on the page recipe (worker W1)

**Worktree:** `/Users/sam/workspace/elide/.worktrees/tern-tests-surface` (branch `feat/tern-tests-surface`).

**Files:** `crates/cli/src/testing.rs`, `crates/cli/src/testing/view.rs`, `crates/cli/src/testing/project.rs`, `crates/cli/src/testing/coverage.rs`, delete `crates/cli/src/testing/surface.css` and `crates/cli/src/testing/project.css` (if present).

**Harness roles to keep:** `run-status`, `totals`, `test-rerun`, `test-running`, `test-output`, `test-cancel`, `subject`, `coverage-files`, `coverage-view`, `coverage-source`, plus `.sf-dock` holding the controls the harness clicks and `.sf-tbl-row` rows.

- [ ] Read the two design docs in full. Read `tests/testing.py`, `tests/sessions.py`, `tests/coverage.py` in the plugin checkout to learn every selector and click the harness performs.
- [ ] Rebuild the standalone and project Tests views: head row (title "Tests", muted subject path and run id, status `badge` per run state, Run again / Run with coverage / Cancel at the right, `md` size); `stats` strip (passed, failed, skipped or todo, duration) toned by state; `tabs` for Results, Failures, Output, Coverage with counts; Results view = full-width selectable `table` (name `grow`, status word toned, duration `mono` right-aligned, file `truncate: middle`, `priority` set) beside the selected test's `card` (facts as `kv`, failure as `stacktrace` when `has_kind("stacktrace")`, else `code`; "Open source" button with its key); Output view = `scroll` with `stick: end` around `ansi` or `code`; Coverage view keeps the current file list and lines behaviour on the recipe; `dock` = key legend (`text` with `key` spans) and the run-status badge the harness reads. States: `shimmer` while starting, `empty` for no tests, error `card` for failed start.
- [ ] Remove the stylesheet and every `stylesheet(..)` call in this module. Replace any color via class with tones/tokens.
- [ ] Verify: `PATH=/usr/bin:$PATH cargo build -p cli --example test_surface --example project_surface`; in the plugin checkout `make testing project ELIDE_SOURCE=<worktree>` then `python3 tests/testing.py --runtime $RUNTIME`, `python3 tests/sessions.py --runtime $RUNTIME`, `python3 tests/coverage.py --runtime $RUNTIME`. All must print PASS. If a selector must move, keep the role on the new element.
- [ ] Commit on the worktree branch.

### Task 2: Serve and Debug surfaces on the page recipe (worker W2)

**Worktree:** `/Users/sam/workspace/elide/.worktrees/tern-serve-debug-surface` (branch `feat/tern-serve-debug-surface`).

**Files:** `crates/cli/src/serve/surface.rs`, `crates/cli/src/inspect/*.rs`, delete `crates/cli/src/serve/surface.css`; `crates/cli/src/debugging.rs`, `crates/cli/src/debugging/view.rs`, `crates/cli/src/debugging/session.rs`, delete `crates/cli/src/debugging/surface.css`.

**Harness roles to keep:** Serve: `address`, `request`, `restart`, `trace`, `span`, `traces-pause`, `traces-errors`, `capture-status`. Debug: `debug-variables`, `debug-read-values`, `debug-owner`, `debug-continue`, `debug-takeover`, `debug-stop-button`, `debug-path`, `debug-launch-button`, and the `.sf-tbl-row`, `.sf-tree-node`, `.sf-editor`, `.sf-select*` elements the harness drives.

- [ ] Read the two design docs in full. Read `tests/serve.py`, `tests/telemetry.py`, `tests/debug.py`.
- [ ] Serve: head row (title "Server", bound URL as a `link` span, Running/Stopped badge, Restart and Stop at the right); `stats` (requests, errors, p95 or latest latency, uptime as text re-rendered); `tabs` Requests, Traces, Logs; Requests = selectable table (method, path `grow`, status word toned, duration mono) beside the selected request's `card` (`kv` details); Traces = selectable table beside the selected trace's card with the span tree as `tree` and attributes as `kv`, keeping Pause/Resume/Errors/Clear as `buttons` in the view's toolbar row; Logs = `scroll` `stick: end` of `ansi`. Key legend in `dock`.
- [ ] Debug: head row (target path in `mono`, state badge, Launch/Take control at the right); `tabs` Inspect, Breakpoints, Output; Inspect = frames as `stacktrace` (`has_kind` fallback to a table) beside a card with scopes/values as `tree`; Breakpoints = table with row menus and the add-breakpoint `input`; controls (Continue, Next, Step in, Step out, Pause, Stop) as a `buttons` group in the head or toolbar with `keys`; key legend in `dock`.
- [ ] Remove both stylesheets and all `stylesheet(..)` calls in these modules.
- [ ] Verify: `cargo build -p cli --example serve_surface --example debug_surface`; `make serve debugging ELIDE_SOURCE=<worktree>` in the plugin checkout, then `tests/serve.py`, `tests/telemetry.py` (pass `--runtime $RUNTIME`), `tests/debug.py`. All PASS.
- [ ] Commit on the worktree branch.

### Task 3: Plugin routes, chrome, events, lenses and the `elide://` route (worker W3)

**Worktree:** `/Users/sam/workspace/elide-tern/.worktrees/plugin-integration` (branch `feat/tern-integration-points`). Run `PATH=/usr/bin:$PATH make build` there first so `dist/elide-tern-broker` exists for the harness. Never run `tern plugin link` (it would repoint the user's live plugin); the harness copies the plugin from the checkout it runs in.

**Files:** `plugin/window.luau`, `plugin/host.luau`, `plugin/plugin.toml`, `plugin/lib/*.luau`, `README.md`, `docs/architecture.md`.

- [ ] Read `guides-chrome.md`, `guides-routing.md`, `guides-layout.md`, `reference-events.md`, `guides-views.md` (lens section) and `reference-ui.md`.
- [ ] **Chrome:** `tern.chrome.tab_title` naming a tab after the project when its focused pane sits in a detected project (respect `tab.name`); `tern.chrome.program_icon("elide", <icon>)` with a valid Tern icon name (verify it does not raise); the existing status segment gets `command = "plugin.elide.project"` so a click opens the project menu.
- [ ] **Events:** window `command_finished` for lines whose program is `elide` and subcommand `test`, `build` or `run`: refresh the status segment and, on nonzero status for `test`, toast "Tests failed" with the subject; keep handlers under the 50 ms budget (no process spawns inside).
- [ ] **Routes:** `tern.route.link` for the `elide://` scheme. Contract: `elide://source?path=<abs>&line=<n>&col=<n>` opens the file at that line (`cx:open`), `elide://debug?root=<abs>&path=<abs>&line=<n>` launches the debugger for that root with that source, `elide://tests?root=<abs>` opens project test runs for that root. Percent-decode values; ignore URLs whose `path` does not lie under `root` (or under a detected project when `root` is absent); return `nil` for anything else. Extend the existing `tern.route.open` so `elide.pkl` opened from the palette (origin `palette`) opens the project workspace like the `files` origin does.
- [ ] **Workspace:** evaluate replacing the incremental splits in `lib/workspace.luau` with one `cx.layout:tab(spec)` call; adopt it only if `tests/workspace.py --headless` still passes and the code gets simpler. Otherwise record why not in `docs/architecture.md`.
- [ ] **Lenses** in `host.luau` with `[[lenses]]` entries: `build` matching `elide build` and `elide build *`, collecting lines and rendering `file:line[:col]: <severity>: <message>` diagnostics as `tern.ui.diagnostic` cards (use `tern.parse.location`; fall back to nil when none parsed); `tap` matching `elide test --reporter=tap*` and `elide test * --reporter=tap*`, rendering `tern.ui.test_summary` plus a table of `ok`/`not ok` lines. Bound buffers as the json lens does.
- [ ] Verify: `stylua --check plugin`; `python3 tests/workspace.py --headless`; `python3 tests/project.py --sdk <SDK> --runtime $RUNTIME` with `SDK=/Users/sam/workspace/elide/.dev/scratch/tern-pr/.dev/artifacts/dist/current/embedder`; a headless lens smoke modelled on `/private/tmp/claude-501/-Users-sam-workspace-elide-tern/6dc1a6e8-82f4-40f4-8fe6-360f3a19a306/scratchpad/lens_smoke.py` for one `elide build` and one `elide test --reporter=tap` command; a headless route smoke that runs `printf '\e]8;;elide://source?path=...&line=2\e\\open\e]8;;\e\\'` in a pane and clicks the link via `tern ctl` (if clicking is not scriptable, unit-test the URL parser as a pure Luau function through `tern ctl ... carly lua` or a small harness).
- [ ] Update `README.md` and `docs/architecture.md` for the new primitives. Commit on the worktree branch.

### Task 4: `elide://` links from Elide (worker W4, after Tasks 1 and 2 merge)

**Worktree:** `/Users/sam/workspace/elide/.dev/scratch/tern-pr` (branch `feat/tern-integration-pr`), after W1 and W2 are merged in.

- [ ] In the Tests surfaces, give test rows, failure locations and report links `href` values using the Task 3 contract; in plain `elide test` output under a terminal, print OSC 8 hyperlinks for failure locations only when stdout is a terminal (never into reporters or redirected output).
- [ ] In the Serve traces view, give trace ids `href = elide://trace?…` only if Task 3 added a handler; otherwise skip.
- [ ] Verify with the Task 1 and 2 harness commands plus a plain `elide test` run redirected to a file containing no `\e]8` bytes.
- [ ] Commit.

### Task 6: Elide source block with coverage, debugger and profile overlays (worker W5)

**Worktree:** a fresh plugin worktree from `main` after Task 3 merges (`/Users/sam/workspace/elide-tern/.worktrees/source-block`, branch `feat/source-block`). Run `PATH=/usr/bin:$PATH make build` there first. Never run `tern plugin link`.

**Why a plugin block:** Tern draws every pane from the TSP node tree; no foreign widget can be embedded. The `editor` node kind (see `elements-input.md` lines 152-375 in the scratchpad `tern-docs` directory) gives a program-owned code viewport: `lang` for Tern's syntax highlighting, `decor` ranges with span tokens, a per-line `gutter`, per-line `virt` inlays, `topline`/`followCursor`, `readonly`, and with the `edit` feature a click arrives as a caret-moving edit that yields the clicked line. Gutter spans are not clickable, so line actions are keys on the caret line.

**Files:** `plugin/host.luau` (block definition; blocks are host-half), `plugin/plugin.toml` (`[[blocks]] id = "source"`, `title = "Elide source"`, `files = ["*.js", "*.mjs", "*.cjs", "*.ts", "*.mts", "*.cts", "*.py", "*.kt"]`), a new `plugin/lib/source.luau` for pure helpers (line/offset math in UTF-16, overlay merging), `plugin/lib/broker.luau` (reuse the request client), `plugin/window.luau` (route `elide://source` to the block when a project is attached; a "Source" action in the workspace toolbar and project menu), `README.md`, `docs/architecture.md`, `tests/source.py` (new harness).

- [ ] Read `guides/blocks.md` (fetch `https://docs.stencil.so/tern/guides/blocks.md`), `reference/api-host.md`, `elements-input.md` (editor), `docs/protocol.md` in this repo (broker ops `project_attach`, `project_coverage`, `project_coverage_page`, `project_debug_snapshot`, `project_debug_request`), and `plugin/tern.d.luau` for `BlockDef`, `cx:frame`, `tern.fs.read` limits and the block `features` field.
- [ ] Block `init(cx, args, saved)`: `args[1]` is the absolute file, optional `args[2]` the project root; read the file with `tern.fs.read` (respect its size limit; refuse files above it with an `empty` state saying so), detect `lang` from the extension, attach to the project through the broker when a root is known (lease renewed on a 30 s timer while open; detach on `pane_exited`). State: text, cursor, topline, overlay mode (`none`, `coverage`, `debug`, `hotness`), overlay data, selected run.
- [ ] View: `font = "sans"` block; head row (file name in `title`, muted root-relative path and project name, badges for the active overlay's state, buttons "Edit in Tern" (`actions = {click = "open"}` with the file `href`) and the overlay switch as segmented `tabs` None / Coverage / Debug / Hotness); the `editor` node `readonly`, `lang`, `nowrap`, `maxLines` sized to the pane (`cx.pane` rows from `resize`), `gutter` = line numbers plus the overlay sign, `virt` = overlay inlay, `decor` = overlay ranges; a `dock` key legend. States: `shimmer` while attaching, `empty` with "Run with coverage" when no coverage artifact exists, error `card` on broker failures.
- [ ] Coverage overlay: fetch `project_coverage_page` for the file index matching this path (page through `next`), mark lines covered (`success` dot), uncovered (`error`), partial branches (`warning`), hit counts in `virt`; a stats `badge` with the file percentage in the head row.
- [ ] Debug overlay: poll `project_debug_snapshot` (compact) every 500 ms while the Debug overlay is active; show the stop location as a `pending`/`accent` gutter marker with the line decorated `mark`, breakpoints as `●` gutter signs; keys: `b` toggles a breakpoint on the caret line through `project_debug_request` `breakpoints` (replacement lines for this path), `F5`/`c` continue, `F10`/`n` next, `F11`/`s` step in, ⇧F11/`o` step out, only when `controller == "you"`; ↑/↓, j/k move the caret line; `g` jumps to the stop line. Use the UUID/command retry contract from `docs/protocol.md`.
- [ ] Hotness overlay: consume profile data only if the broker or project session exposes source-located profile samples (check `crates/broker/src` and the `elide-project-session` crate in `/Users/sam/workspace/elide/.dev/scratch/tern-pr/crates/project-session`); if a read-only op exists or can be added to the broker in this repo in under ~150 lines reusing existing data, add it (`project_profile_page`) and draw per-line sample share as a `gutter` bar of `▁▂▃▅▇` glyphs toned `warning`/`error` by share; otherwise disable the Hotness tab with a `disabled` reason string and record the missing op in `docs/architecture.md`.
- [ ] Routes and entry points: `elide://source` opens this block (keeping the existing file open as fallback when no project is attached); the workspace toolbar gains a "Source" button for the focused file; `files` globs give "Open with Elide source".
- [ ] Harness `tests/source.py` modelled on `tests/coverage.py` and `tests/debug.py`: open the block on a test file after a coverage run, assert gutter marks for a covered and an uncovered line via `tern ctl tree '.sf-editor .sf-ed-gutter'`, switch to Debug, set a breakpoint with `b`, launch, assert the stop marker; take a `shot`. Run `stylua --check plugin`, `tests/workspace.py --headless`, `tests/project.py`, and the new test against `RUNTIME`/`SDK` from Task 3.
- [ ] Commit in small steps; report the PNG path.

### Task 5: Integration, review, rebuild (controller)

- [ ] Merge W1 and W2 branches into `feat/tern-integration-pr` (fast-forward or merge; no conflicts expected since modules are disjoint), merge W3 into plugin `main`, dispatch W4, then a fresh Opus reviewer over both repos' ranges.
- [ ] Rebuild the runtime, rerun the full harness, update memory, report. Push only when the user says so.
