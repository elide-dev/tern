# Runtime crates

The broker links the runtime crates `elide-embed-host` (supervised embedding worker,
frame protocol and Cap'n Proto bindings) and `elide-project-session` (Apache-2.0)
from a sibling `../elide` checkout of `elide-dev/runtime`. No runtime or Studio
source is vendored. SDK archives/libraries are not vendored either; a selected SDK
directory must retain all of its resources, configuration, compiler workers,
schemas and notices.

## Compose build dependency

`scripts/build-compose.ts` bundles the editor-independent core model,
`composeRender.ts`, `composeRuntime.ts` and `media/compose/*.java` from
`../elide-vscode` (or `ELIDE_VSCODE_SOURCE`). These remain shared source dependencies,
not a fork in this directory. The upstream repository's MIT license covers them.
The build embeds that notice plus the bundled `yauzl` and `pend` MIT notices,
exposes them through `elide-tern-compose --licenses`, and writes
`dist/elide-tern-compose.LICENSE` for release archives.

Google's renderer/layoutlib artifacts are downloaded on first use, not embedded
in the binary. The upstream installer pins versions and SHA-256 hashes, retains
the original jars and their notices, and preserves licenses during extraction.
