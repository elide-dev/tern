# Runtime crates

The broker links the runtime crates `elide-embed-host` (supervised embedding worker,
frame protocol and Cap'n Proto bindings) and `elide-project-session` (Apache-2.0)
from a sibling `../elide` checkout of `elide-dev/runtime`. No runtime or Studio
source is vendored. SDK archives/libraries are not vendored either; a selected SDK
directory must retain all of its resources, configuration, compiler workers,
schemas and notices.
