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
