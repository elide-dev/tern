# Ledger: Tern integration points run (2026-11-06)

Hand-off record for the plan in `2026-11-06-tern-integration-points.md`. Keep it current: one line per event, newest at the bottom of each section. A new session resumes from this file plus `git log` in each checkout.

## Standing facts

- Plugin repo: `/Users/sam/workspace/elide-tern`, branch `main`. Uncommitted working-tree edits in `tests/` are deliberate (see "Uncommitted"); never `git add -A` there.
- Runtime repo: `/Users/sam/workspace/elide`. Integration branch `feat/tern-integration-pr` in worktree `/Users/sam/workspace/elide/.dev/scratch/tern-pr` (PR #2757). Head before this run: `606b63dca` (packaging) over `87a5b5867` (dropped `tern test`/`tern serve`).
- Runtime binary for all harness runs: `/Users/sam/workspace/elide/.dev/scratch/tern-pr/.dev/artifacts/dist/current/bin/elide` = `1.6.3+87a5b5867` (has `tern repl|project|debug` only; `elide test`/`elide serve` host their own surfaces). Embedded SDK: same dist, `embedder/`. Fallback older runtime: `/Users/sam/workspace/elide/.dev/artifacts/dist/current/bin/elide`.
- Cargo in any Elide checkout needs `PATH=/usr/bin:$PATH`. Never `./builder build` from a worker. Full release build recipe (18 min): `PATH=/usr/bin:$PATH CARGO_PROFILE_RELEASE_DEBUG=0 ./builder build --release --with-python --embedder` in `tern-pr`, after `./builder toolchains install elide-toolchain` matched the pin.
- Disk: hit 100% at 10:45; freed 48 GB by deleting `.worktrees/tern-native-surfaces/target` (mine). Main `elide/target` (275 GB) is Sam's; not touched.
- Policy: no pushes until Sam says so; commits stay local in each worktree. Worker commits end with `Co-Authored-By: Claude Opus 5.5`; controller commits with `Claude Fable 5.1`.

## Workers

| Worker | Task | Worktree / branch | Status |
| --- | --- | --- | --- |
| W1 | Tests + project Tests surfaces on the page recipe, Coverage view redesign (Sam's addition 10:53) | `/Users/sam/workspace/elide/.worktrees/tern-tests-surface`, `feat/tern-tests-surface` | Running. Uncommitted `testing/state.rs` (10 unit tests), coverage paging helper. Symlinking its `target` to `tern-pr/target` was approved. Decisions approved: tabs role `test-views`, totals/test-running in dock, run-status badge in head row, two harness click selectors change, coverage test calls a page-setting method. |
| W2 | Serve + Debug surfaces on the recipe | `/Users/sam/workspace/elide/.worktrees/tern-serve-debug-surface`, `feat/tern-serve-debug-surface` | Running. Approved: wrapper-script runtime for debug.py; dual-compatible selector edits in main-checkout tests, uncommitted. |
| W3 | Plugin chrome, events, `elide://` link route, palette route, lenses, docs | `/Users/sam/workspace/elide-tern/.worktrees/plugin-integration`, `feat/tern-integration-points` | Running (lens smoke in progress). Committed `af28ffe` (link parser + `tests/links.lua`). Uncommitted: chrome, events, routes, lenses, tap-lens fix at `host.luau:157`, docs. Did not adopt `cx.layout:tab` (leaves cannot hold docs editor/canvas). Rejected `elide://` links toast instead of returning nil. |
| W4 | `elide://` links emitted from Elide (Task 4) | `tern-pr`, after W1+W2 merge | Not started. |
| W5 | Elide source block with coverage/debug/hotness overlays (Task 6, added 11:00) | new plugin worktree from `main` after W3 merges | Not started. |

## Uncommitted edits in `/Users/sam/workspace/elide-tern` (controller commits at integration)

- `tests/testing.py:61` → launches `dist/elide-tern-test <runtime> <script>` (was `<runtime> tern test …`). Mine.
- `tests/telemetry.py:111` → launches `dist/elide-tern-serve <runtime> <subject>` (was `<runtime> tern serve …`). Mine.
- `tests/serve.py` → modified by W2 (selector edits); W2 reports exact lines.
- Expected later: W1's two click selectors in `tests/testing.py`, one coverage test method change in `tests/coverage.py`.

## Integration steps (controller)

1. When W1 reports PASS ×3: `cd tern-pr && git merge --ff-only feat/tern-tests-surface` (or merge); same for W2. Modules are disjoint.
2. Commit the harness edits on plugin `main` as one commit, then `git merge feat/tern-integration-points`.
3. Dispatch W4 (Task 4) in `tern-pr`; dispatch W5 (Task 6) in a new plugin worktree from `main`.
4. Fresh Opus reviewer over both ranges; fix pass; rebuild runtime; full harness: testing, sessions, coverage, serve, telemetry, debug, surface (`--sdk`), project (`--sdk --runtime`), workspace (`--headless`), lens smoke, source block test.
5. Update memory, report, wait for Sam before pushing.

## Event log

- 10:29 Plan written and committed (`f5b9034`); worktrees created; W1, W2, W3 dispatched (Opus).
- 10:41 Release rebuild finished: `1.6.3+87a5b5867`. Smoke: `elide test` and `elide serve` host their surfaces in a headless pane.
- 10:43 Harness `tests/testing.py`, `tests/telemetry.py` repointed at the shims (uncommitted).
- 10:45 Disk full; W1 and W3 idle; freed 48 GB; all workers resumed.
- 10:53 Sam: Coverage view needs a full redesign; forwarded to W1 with concrete requirements.
- 11:00 Sam approved the Elide source block; Task 6 added and committed (`bf8f159`).
- 11:03 This ledger created.
- 11:04 Security review flagged W2 commits (inspect/view.rs tree fan-out; serve/surface.rs request href authority); forwarded to W2 to fix with tests before reporting.
- 11:06 W1 done: c8a02b17d on feat/tern-tests-surface; testing/sessions/coverage PASS; merged ff into feat/tern-integration-pr. tests/testing.py lines 75/77/79 selector edits (W1, uncommitted). coverage.py needs a one-line shim change (W1 to supply). Asked W1 for truncated tail + PNG.
- 11:10 Reviewed W1 shots: Tests page on recipe; Coverage view clipped head row in narrow pane, no meter column, text summary instead of stats. Sent W1 follow-up (5 items) for a second commit on feat/tern-tests-surface; merge again after.
- 11:12 Controller hit its usage limit. W1 (coverage follow-up), W2 (serve/debug + two security fixes), W3 (plugin finish) still running in their worktrees. Next controller: collect their reports, merge W1 follow-up and W2 into tern-pr, commit harness edits on plugin main and merge W3, then dispatch W4 and W5 per "Integration steps".
- 14:52 Limit reset. Workers W1/W2/W3 had all died on the 5-hour limit at 11:05 mid-step; resumed all three via messages. Sam: add `elide help` rendering docs browsably in Tern with full TSP support (Task 7).
- 14:55 Task 7 added: `elide help` as a native docs surface (TSP md/nav/breadcrumb/picker), worker W6 after W1+W2 merge, new harness tests/help.py.
- 14:58 W2 done: 2318156ae, c7666b0a6 (security fixes), 63944d263 on feat/tern-serve-debug-surface; serve/telemetry/debug PASS; merged into feat/tern-integration-pr. Harness edits uncommitted in main checkout: serve.py:59-60, telemetry.py (TRACE selector etc.), debug.py (2 tab clicks). W2 wrapper runtime: scratchpad/wrapped-runtime/elide. Created tern-help-surface worktree (target symlinked to tern-pr/target); dispatching W6.
- 15:00 Disk down to 9.9 GB; deleted W2 worktree target (11 GB) and removed superseded tern-native-surfaces worktree+branch (commits already in tern-pr); 23 GB free. W6 (help surface, Opus) dispatched in .worktrees/tern-help-surface. Running: W1 (coverage follow-up), W3 (plugin finish), W6.
