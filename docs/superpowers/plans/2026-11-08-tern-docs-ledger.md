# Tern docs and demo clips — hand-off ledger

Approved by Sam 2026-11-08 09:11 PST. Read this first after any context loss.

## Scope
- Tern becomes a docs section in `project/docs` (Elide runtime repo): install at the top of the landing page, then
  terminal surfaces, project workspace (tests UI, source editor, elide:// links, lenses), debugging (step-wise),
  coverage, OTLP telemetry (trace waterfall), build diagnostics, troubleshooting. Existing CLI/guide pages keep
  detail and link in.
- Three-level comparison per command where it exists: plain text (outside Tern or `--reporter`), inline TSP surface,
  full plugin UI.
- Demo clips like the IntelliJ/VS Code ones (zoom, pointer, av1/vp9/hevc/h264 + webp poster), recorded on macOS by
  driving Tern over `tern ctl`; each clip specified in JSON for re-recording. Then backfill JSON specs for the
  VS Code and IntelliJ clips.
- Rulings from Sam: no profiling (not integrated), no "coming soon" text, document only what is true. Trace waterfall
  goes in an OTLP demo. Commits carry no Co-Authored-By or any attribution trailer, ever.

## Branches (runtime repo `/Users/sam/workspace/elide`)
- `docs/tern-guide` at `.dev/scratch/tern-docs`, cut from main c47257746 (PR #2757 squash-merged). Integration branch.
- `docs/tern-recorder` at `.dev/scratch/tern-docs-recorder` (worker: tern-recorder).
- `docs/tern-section` at `.dev/scratch/tern-docs-section` (worker: tern-section).

## Events
- 2026-11-08 09:12 PST: PR #2757 merged as c47257746; worktrees cut; workers briefed.
- 2026-11-08 09:20 PST: tern-recorder and tern-section (Opus) dispatched; base worktree tern-base removed. Clip ids fixed in both briefs: tern-install, tern-test-{plain,inline,workspace}, tern-build-{plain,inline,workspace}, tern-help-{plain,page}, tern-serve, tern-repl, tern-debug, tern-coverage, tern-otlp.
- 2026-11-08 09:30 PST: Ruling: recorder films headless `tern serve --control` via paced `shot` frames on the app clock (2x, ~30 fps), not ScreenCaptureKit and not Tern's lossy `record start` — no Screen Recording permission, no visible window — cost if wrong: clips needing a real OS window fall back to an SCK helper for that clip only.
- 2026-11-08 09:32 PST: recorder step 1 b20b212e1 (JSON specs in scripts/ide-demos/clips, generated src/data/ide-demos.json; VS Code/IntelliJ specs metadata-only until step 5; fixtures tools/demos/fixtures/tern/{shop,build,install}).
- 2026-11-08 09:33 PST: Sam: 60 fps with tolerable compression that stays lossless-looking. Ruling: capture at 60 fps on the app clock with holds over missed slots; keep PNG frames + a lossless master (FFV1/x264 qp0 yuv444) uncommitted; web encodes visually lossless incl. chroma; recorder reports sizes at two settings for Sam to pick — cost if wrong: a re-encode pass.
- 2026-11-08 09:55 PST: tern-section done (32784510f section, ebe6f7dea links); 8 pages under content/en/tern/, top-level nav `tern`. Merged section + recorder step 1 into docs/tern-guide (f7b993574). docs test:unit: 11 regressions vs main (DocsSearchPalette, DocsChrome; main 1 fail) — sent back to tern-section. Worker rulings: top-level nav (Tern out of IDE group); Elide 1.6.3+ on PATH; repo-access requirement row (repo internal); archive name pinned 0.1.0-preview.1; test table has 4 levels, 3 clips. Dropped unverified claims (serve port, notebook Kotlin, Kotlin debugging, profiles wording, roadmap items).
- 2026-11-08 10:05 PST: the 11 docs unit regressions did not reproduce (tern-section: 1390/1 in 5 runs incl. docs/tern-guide; the 1 is worker.test.ts needing a site build, same as main). Treated as a flaky first run in a freshly set-up worktree. Site build + Playwright running in tern-section.
- 2026-11-08 10:15 PST: recorder c0befbcde proves headless capture on tern-test-inline (31 fps achieved, av1 35 KiB, h264 59 KiB). Held the full set until a 60 fps retake + size/quality comparison. Approved: /Users/Shared/elide-demo home, ZDOTDIR/PATH isolation (mise put elide 1.6.2 on PATH), short TMPDIR (socket path limit), tern-test-plain shows the TAP lens with a truthful caption.
- 2026-11-08 10:20 PST: Sam: record dark and light. Ruling: tern clips default to themes [dark, light], one take per theme via Tern `appearance`, outputs <id>.<theme>.<codec> + poster per theme; IdeDemo/player follow the site theme (html.dark / dataset.theme) and switch live keeping position — fallback: switch on load only. Recorder owns IdeDemo.tsx/ide-demo-player.ts for this.
- 2026-11-08 10:45 PST: recorder recorded all 14 (29–33 fps, dark only) without the 60 fps/theme messages; commits 9b323813a (steps, fetch step, --serve, fixtures), 4193286f4 (biome skips clips). Held publish. Rulings: budget per theme variant, decide after numbers (Sam); tune tern-install hevc rather than relax the rule; step 5 = full JSON steps verified by golden action traces from the existing TS clips (Linux re-record is the real proof); 1600x900 workspace / 1280x720 terminal clips. Plugin findings for Sam: TAP/javac lenses don't render headless; status trusts pipeline exit; debugger shows 'Paused elsewhere' after step-into another file.
- 2026-11-08 10:55 PST: tern-section verified site build (check:docs, astro, check:dist 556 pages, check:worker, wrangler dry run) and Playwright 242 pass / 22 skip / 0 fail on f7b993574. Section work complete pending clip publish.
- 2026-11-08 11:20 PST: recorder 41257a294: 60 fps both themes on tern-test-inline (365/366 slots, worst gap 29 ms); masters x264 RGB qp0 kept; 4:4:4 VP9/HEVC/AV1 + 4:2:0 H.264 fallback; source order VP9, HEVC, AV1, H.264 (WebKit stalls on AV1 4:4:4). Sam chose preset text-light; budget raised to AV1 5 / HEVC 8 / VP9 7 / H.264 10 MiB per theme; size rule only between same-chroma encodes. Recorder told to record all 14 x 2 themes, publish, browser-test the live theme swap, then step 5.
- 2026-11-08 11:35 PST: step 5 done 7d62c606e: VS Code/IntelliJ clips run from JSON steps; 14 golden traces (scripts/ide-demos/traces) replay identically; TS clip bodies removed; budget per theme. Resent Sam's decisions; recorder told to record/publish all 14 x 2 and browser-test the theme swap. Sam: finish out, then write a closing ledger.

## State at 2026-11-08 11:00 PST (snapshot in case the session ends)
Done:
- PR #2757 squash-merged to Elide main as c47257746 (CI green; Co-Authored-By trailers stripped from PR and tern main by history rewrite + force-push; clippy collapsible_if and Socket tslib findings fixed). Tern `main` force-pushed fcf327b (trailers removed).
- Binary footprint (local release, macOS arm64, base decc1d0f7 vs PR): bin/elide +2.53 MB (+5.9%, almost all __text), libelideengine +0.19 MB, libelideruntime +0.05 MB; CI dev-build report +12.1 MB macOS / +7.2 MB linux. No new external crates.
- Docs section (docs/tern-section 32784510f, ebe6f7dea): 8 pages under content/en/tern (tern, tern-terminal, tern-workspace, tern-debugging, tern-coverage, tern-build, tern-telemetry, tern-troubleshooting), top-level nav `tern` in all locales. Site build, check:dist, Playwright 242/22/0, cargo test -p help 196 pass.
- Recorder (docs/tern-recorder): b20b212e1 specs, c0befbcde headless macOS recorder, 9b323813a steps/fixtures, 4193286f4 biome skip, 41257a294 per-theme 60 fps 4:4:4, 7d62c606e VS Code/IntelliJ JSON steps + golden traces + per-theme budget.
In flight (tern-recorder): record all 14 Tern clips x dark/light at 60 fps with preset text-light, tune tern-install HEVC < H.264, publish to public/assets/demos/ide, write seconds, regenerate ide-demos.json, update contract (AV1 5 / HEVC 8 / VP9 7 / H.264 10 MiB per theme; size rule same-chroma only), Playwright test of live theme swap in Chromium + WebKit, spot-check frames.
To finish (resume here):
1. When tern-recorder reports: merge docs/tern-recorder (and docs/tern-section if it moved) into docs/tern-guide at `/Users/sam/workspace/elide/.dev/scratch/tern-docs`.
2. `git rebase origin/main` (branch was cut from c47257746, no merge commits yet besides f7b993574 — use `git rebase --onto origin/main c47257746` if needed).
3. Rerun: project/docs `bun run test:unit` (main has 1 known fail: worker.test.ts needs a site build), site build, Playwright, `cargo test -p help` (own CARGO_TARGET_DIR).
4. Do not push until Sam says. Commits never carry Co-Authored-By.
5. Write the closing summary in this ledger.
Plugin findings to raise with Sam (seen headless only): TAP/javac output lenses don't render; status segment trusts a pipeline's exit (`elide build | cat` shows Built); debugger shows "Paused elsewhere" after stepping into another file.
Worker rulings to confirm with Sam: Tern is top-level nav (out of IDE Editors); "Elide 1.6.3+ on PATH"; repo-access requirement row (repo internal); install archive pinned 0.1.0-preview.1; demo home /Users/Shared/elide-demo.
- 2026-11-08 11:02 PST: filed the three possible plugin bugs on elide-dev/tern: #2 TAP/javac lenses don't render, #3 status reports a piped failing build as Built, #4 debugger 'Paused elsewhere' after step-into another file.
- 2026-11-08 13:02 PST: tern-recorder hit the 5-hour limit after publishing all 140 tern assets (uncommitted, 159 changes in its worktree). Resumed it to finish the contract test, Playwright theme swap, spot-checks and commit.
- 2026-11-08 13:40 PST: recorder d6d44f7fa: 140 assets published; text-compact preset (CRF AV1 44/HEVC 28/VP9 40/H.264 25) on 5 long workspace clips to fit budget; per-theme totals dark AV1 4158 / HEVC 8031 / VP9 7062 / H.264 9979 KiB (HEVC, VP9 within ~1.5% of limits); Playwright theme swap passes in Chromium + WebKit; 28 frames spot-checked. docs/tern-guide merged and rebased onto origin/main de570de0c: 9 linear commits (399a01425..96c1dcaca), no trailers. Unit: 1407 pass / 1 fail (worker.test.ts needs dist; first run after build:ui flakes 11 search/chrome tests again). Final site build, Playwright and cargo test -p help running.
- 2026-11-08 13:20 PST: rebased docs/tern-guide: site build + check:dist OK, Playwright 245/22/0, cargo test -p help 196 pass, unit 1492/1 — the 1 is the real-corpus search eval (anchors 0.79 < 0.8). Sent to tern-section to fix on docs/tern-guide directly.
