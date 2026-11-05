# Embedded host provenance

`studio-embed/` comes from `elide-dev/studio`, revision
`68657fe0f1942a40bf6fd901af3b0a34a439f309`, directory `crates/studio-embed`.
`studio-embed/upstream.json` records original source SHA-256 hashes. Sources were
read from the committed revision, not from Studio's modified working tree.

Local adaptation: `Cargo.toml` adds libc; `src/lib.rs` creates a dedicated Unix
process group for spawned workers and kills that group before reaping on stop.
Bindings are regenerated at build time from the updated SDK schema to support
the additive evaluation display discriminator. The original generated source is
retained for provenance but is not compiled. The ABI implementation, framing,
deadlines, and standalone worker remain upstream code. The broker's worker entry adds parent-death
monitoring outside this snapshot. Preserve this delta when refreshing upstream;
do not reformat the vendored files.

`embedding.capnp` is the matching canonical SDK schema. Its Apache-2.0 notice is
in the schema, with the SDK license in `ELIDE-LICENSE.txt`. This notice does not
assign a new license to Studio source. Review redistribution terms before release.
SDK archives/libraries are not vendored. A selected SDK directory must retain all
of its resources, configuration, compiler workers, schemas and notices.
