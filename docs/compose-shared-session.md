# Intent: one Komodo session per application, across files

Status: not started. Recorded 2026-11-11.

## Problem

Switching the Compose preview to another file of the same application (retarget, or reopening a
different file while the service is warm) takes 7–8 s on `elide-android-sample`, although the
language server and preview process are reused. Upstream `KomodoBackend` keys a session by the
previewed file, so every switch closes the session, reconfigures and re-hosts:

| Step | PlanScreen (3 cards) | PreviewGallery (13 cards) |
|---|---|---|
| Previous session closes | ~0.4 s | ~0.3 s |
| `configure` (compiles the file's program) | ~1.6 s | ~2.0 s |
| Hosting the cards (first frames) | ~4.8 s | ~5.8 s |
| Total | 6.9 s | 8.1 s |

Returning to a file previewed before costs the same. Re-hosting on an already configured program
(an `entries`-only change, measured by renaming a preview) takes ~1.5 s for 13 cards, with no
`configure`.

## Intended change

Keep one session per application and switch files by changing which previews it hosts:

- Use upstream `PreviewRequest.selection`. The session key
  (`KomodoBackend.previewNow`) covers `sourceFile` and `selection.files`, not
  `selection.previews`, so keep `sourceFile` fixed (the first previewed file) and pass the other
  program files as `selection.files`. Changing only the shown previews re-hosts on the same
  daemon (`reconfigure` feature) without `configure`.
- Add files to the program as they are visited. A new file changes the file set and pays one full
  switch; revisits take ~1.5 s.
- Host only the current file's cards (no background rendering of other files' cards, and the
  32-card page limit stays per file).
- With `selection` upstream skips discovery: `compose/service.ts` must discover each file's
  previews through Komodo `previews` (as the old `compose/live.ts` did) and keep the last good
  result when a file has errors.

## Alternatives considered

- Put every preview-bearing file of the application in the program at open: every switch cheap,
  but a larger first compile and an error in any file affects all previews.
- Keep visited files' cards hosted and filter in the page: instant switch back, at the cost of
  background rendering, idle clock frames for all hosted cards, memory and a shared 32-card limit.

## Caveats

- A compile error in any program file affects every file's previews in the session.
- Files of another application in the workspace still need their own backend and session.
- Edited dependency files already join the program through upstream `joining`; the selection's
  file set must not drop them.

## Verify

Retarget between `PreviewGallery.kt`, `ui/DeparturesScreen.kt` and `ui/PlanScreen.kt` on
`elide-android-sample` with the service warm: the first visit to a file stays ~7–8 s, revisits
should paint in ~1.5 s with no `komodo-preview: main … ready` line in the service log.
