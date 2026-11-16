# Runtime crates

The broker links the runtime crates `elide-embed-host` (supervised embedding worker,
frame protocol and Cap'n Proto bindings) and `elide-project-session` (Apache-2.0)
from a sibling `../elide` checkout of `elide-dev/runtime`. No runtime or Studio
source is vendored. SDK archives/libraries are not vendored either; a selected SDK
directory must retain all of its resources, configuration, compiler workers,
schemas and notices.

## Android helper

`android/elide.ts` is derived from `packages/core` of the `elide-dev/vscode` repository
(MIT, Elide Technologies, Inc.): the Elide distribution, version, build-task, Android SDK
and `adb` helpers, and a reduced project-manifest decoder.

## Elide mark

`plugin/assets/elide-light.svg` and `elide-dark.svg` are `packages/vscode/media/elide.svg` from
the `elide-dev/vscode` repository (MIT, Elide Technologies, Inc.), with its comment dropped and `currentColor`
replaced by a fixed ink per theme kind. `plugin/styles/icons.css` draws them in place of Tern
icons on Elide-owned elements.
