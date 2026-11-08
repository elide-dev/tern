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
