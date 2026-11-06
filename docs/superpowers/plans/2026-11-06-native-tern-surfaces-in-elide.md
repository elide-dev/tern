# Native Tern Surfaces in Elide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The shipped `elide` binary hosts every Tern surface (`elide test` natively; `elide tern <surface>` for the rest) and the plugin launches it with no private launchers.

**Architecture:** Surface code already lives in `elidecli` and `eliderepl` behind `Session::connect` negotiation. We add a `tern` module and hidden subcommand in `elidecli`, move the embedded REPL host from a repl example into it, wire `elide test` and `elide tern` into the native entry dispatch, and point the plugin's launch argv at the runtime.

**Tech Stack:** Rust (edition 2024, `usage` derive CLI), `tern-sdk` 0.2.0 via `elidesurfaces`, Luau plugin, Python harness under `tests/`.

**Spec:** `docs/superpowers/specs/2026-11-06-native-tern-surfaces-in-elide-design.md`

Set `$ELIDE` to the runtime checkout and `$TERN` to the plugin checkout.

## Global Constraints

- Negotiate TSP with `Session::connect`; never infer from `TERM_PROGRAM` alone.
- Redirected output, `--reporter=…`, and the Tests surface's own child process never receive TSP frames.
- `elide tern` is `hide = true` under `help_heading = "Advanced"`, like `Classpath`.
- Example output paths `target/<profile>/examples/{embedded_surface,serve_surface,test_surface,project_surface,debug_surface}` are unchanged.
- `cargo clippy -p cli --all-targets -- -D warnings` and `cargo fmt` clean; `stylua --check` clean in `$TERN`.

## Review Focus

1. `elide test --reporter=tap > out.tap` inside Tern: no surface, no APC bytes in the file. Test: `native_test` returns `None` for `--reporter` (Task 1).
2. The surface's child `elide --progress=json test --reporter=tap` must not re-enter the surface. Covered by `--reporter` plus `ELIDE_JOB_PARENT_PID` guard (Task 1, Task 3).
3. `elide test src/api -t 'foo'`: subject is `src/api`, `-t foo` forwarded. Test in Task 1.
4. `elide tern test` outside Tern: exit 2 and a one-line message, not a hang. Task 2 test on `TernOutcome`.
5. Plugin with an older runtime lacking `tern`: pane shows the runtime's usage error; the plugin must not silently run nothing. Manual check in Task 5.

---

### Task 1: `elide test` native host parameters

**Files:**
- Modify: `$ELIDE/crates/cli/src/testing.rs` (`run` signature, new `NativeTest`, `native_test`)
- Modify: `$ELIDE/crates/cli/examples/test_surface.rs`

**Interfaces:**
- Produces: `pub struct NativeTest { pub subject: PathBuf, pub args: Vec<String>, pub coverage: bool }`; `pub fn native_test(args: &[String], cwd: &Path) -> Option<NativeTest>`; `pub fn run(runtime: &Path, test: &NativeTest) -> io::Result<bool>`.

- [ ] **Step 1: Write failing tests** in a `#[cfg(test)] mod tests` at the end of `testing.rs`:

```rust
#[test]
fn native_test_defaults_subject_to_cwd() {
  let t = native_test(&[], Path::new("/w")).unwrap();
  assert_eq!(t.subject, PathBuf::from("/w"));
  assert!(t.args.is_empty() && !t.coverage);
}
#[test]
fn native_test_splits_first_bare_path_and_forwards_flags() {
  let a = ["src/api".into(), "-t".into(), "foo".into(), "--bail=3".into()];
  let t = native_test(&a, Path::new("/w")).unwrap();
  assert_eq!(t.subject, PathBuf::from("/w/src/api"));
  assert_eq!(t.args, vec!["-t", "foo", "--bail=3"]);
}
#[test]
fn native_test_declines_reporters() {
  assert!(native_test(&["--reporter=tap".into()], Path::new("/w")).is_none());
  assert!(native_test(&["--reporter".into(), "tap".into()], Path::new("/w")).is_none());
}
#[test]
fn native_test_preselects_coverage() {
  let t = native_test(&["--coverage".into()], Path::new("/w")).unwrap();
  assert!(t.coverage && t.args == vec!["--coverage"]);
}
```

Note: `-t foo` is two tokens; `foo` follows a flag that takes a value. Treat the token after `-t`, `--test-name-pattern`, `--where`, `--select`, `--include-tag`, `--exclude-tag`, `--reporter-outfile` as a value, not a subject. Absolute subjects stay absolute.

- [ ] **Step 2: Run** `cargo test -p cli testing::tests` → FAIL (missing items).
- [ ] **Step 3: Implement** `NativeTest`, `native_test`, change `run(runtime, test)`: inside `drive`, append `test.args` after `--reporter=tap`, initialize `requested_coverage = test.coverage`, keep the existing subject logic using `test.subject`. Update `test_surface.rs` to build `NativeTest` via `native_test(&rest, &cwd)`.
- [ ] **Step 4: Run** `cargo test -p cli testing::tests` and `cargo check -p cli --example test_surface` → PASS.
- [ ] **Step 5: Commit** `feat(cli): parameterize native test surface host`.

### Task 2: `elide tern` subcommand and embedded REPL host

**Files:**
- Create: `$ELIDE/crates/cli/src/tern.rs`, `$ELIDE/crates/cli/src/tern/embedded.rs`
- Move: `$ELIDE/crates/repl/examples/embedded_surface.rs` → `$ELIDE/crates/cli/examples/embedded_surface.rs` (thin)
- Modify: `$ELIDE/crates/cli/src/lib.rs` (`pub mod tern;`, `pub use tern::TernArgs;`, enum variant), `$ELIDE/crates/cli/Cargo.toml` (deps the moved host needs: `async-trait`, `tokio` mpsc are already workspace deps; add if missing), `$ELIDE/crates/cli/examples/{serve,project,debug}_surface.rs`, `$ELIDE/Makefile` (`build-repl-surface: cargo build -p cli --example embedded_surface`).

**Interfaces:**
- Produces: `pub struct TernArgs { #[usage(subcommand)] pub surface: TernSurface }`, `pub enum TernSurface { Repl(ReplHostArgs), Serve(ServeHostArgs), Test(TestHostArgs), Project(ProjectHostArgs), Debug(DebugHostArgs) }` with positional `String` fields named as in the spec; `pub fn run(args: &TernArgs) -> u32` (0 ok, 1 error printed to stderr, 2 "This surface requires Tern"); `pub mod embedded { pub fn run(broker: &Path, sdk: &Path, state: &Path, language: &str) -> eliderepl::error::Result<()> }`.
- Consumes: Task 1 `native_test`, `testing::run`; `serve::surface::run`, `testing::run_project`, `debugging::run_project`.

- [ ] **Step 1: Failing tests** in `tern.rs`:

```rust
#[test]
fn tern_parses_each_surface() {
  for argv in [vec!["tern","repl","b","s","st"], vec!["tern","serve","elide","."],
               vec!["tern","test","elide","."], vec!["tern","project","b","st","elide","/r"],
               vec!["tern","debug","b","st","elide","/r","/r/a.js"]] {
    assert!(TernArgs::try_parse_from(&crate::commons::test_argv(&argv)).is_ok(), "{argv:?}");
  }
}
#[test]
fn tern_rejects_missing_surface() {
  assert!(TernArgs::try_parse_from(&crate::commons::test_argv(&["tern"])).is_err());
}
#[test]
fn embedded_language_parses_known_ids() {
  assert_eq!(embedded::language("python"), Some(Language::Python));
  assert_eq!(embedded::language("rust"), None);
}
```

- [ ] **Step 2: Run** `cargo test -p cli tern::` → FAIL.
- [ ] **Step 3: Implement** `tern.rs` (`run` matches the variant and calls the existing functions; `Serve` mirrors the serve example including the `is_script_child` static-worker branch; `Repl` language defaults to `js`) and `tern/embedded.rs` (verbatim move of the example's `Broker` engine and `run`, plus `pub fn language(id: &str) -> Option<Language>`). Register `Tern(TernArgs)` hidden under Advanced. Rewrite the five examples as argument shims over `elidecli::tern::run`. Update the Makefile target.
- [ ] **Step 4: Run** `cargo test -p cli tern::`, `cargo build -p cli --examples`, `cargo clippy -p cli --all-targets -- -D warnings`, `cargo fmt --check -p cli` → PASS.
- [ ] **Step 5: Commit** `feat(cli): add hidden tern surface host command`.

### Task 3: Native entry dispatch

**Files:**
- Modify: `$ELIDE/packages/entry/bin/main.rs` (early dispatch beside `Studio` ~line 1779; `Test` arm in the command match ~line 2130)

- [ ] **Step 1: Add early dispatch** `if let Some(ElideCommands::Tern(args)) = &cli.command { return elidecli::tern::run(args) as c_int; }` next to Studio.
- [ ] **Step 2: Add the `Test` arm**: when `elidebase::tty::is_interactive()` and `std::env::var_os(elidecli::job::PARENT_ENV).is_none()` and `elidecli::testing::native_test(&args.args, &cwd)` is `Some(t)`: `match elidecli::testing::run(&current_exe, &t) { Ok(true) => return teardown_and_exit!(0), Ok(false) => {}, Err(e) => { eprintln!("tests: {e}"); return teardown_and_exit!(1) } }`. Fall through otherwise. Confirm `args.args` is accessible (make the field `pub` in `test.rs` if needed).
- [ ] **Step 3: Verify** `cargo check -p entry` (or the workspace member that owns `packages/entry`) → PASS. If a full native build is feasible (`make` target used for `.dev/artifacts/dist/current`), run it in the background and smoke `elide tern` and `elide test` in Tern.
- [ ] **Step 4: Commit** `feat(entry): host native test and tern surfaces from the elide binary`.

### Task 4: Plugin launches the runtime

**Files:**
- Modify: `$TERN/plugin/window.luau` (`launch`, `launch_job`, `launch_debug`), `$TERN/plugin/config.example.json`, `$TERN/README.md`, `$TERN/docs/architecture.md`, `$TERN/Makefile` (`repl` target builds `-p cli --example embedded_surface`).

**Interfaces:**
- Produces: `local function launcher(config, kind): {string}` returning `{ path(config[kind]) }` when set, else `{ runtime(config), "tern", kind }`.

- [ ] **Step 1: Implement** `launcher` and use it in the three launch functions; `launch` passes `broker, sdk, state, language`; project test passes `broker, state, runtime, cwd, subject`; plain `test`/`serve` pass `runtime, subject`; debug passes `broker, state, runtime, root, [source]`. Config example: drop `serve`, document optional per-surface overrides.
- [ ] **Step 2: Run** `stylua --check plugin` and `make link` → PASS; open **Elide → Run tests** in Tern against `config.runtime` built from Task 3 if available, else set `test = "../dist/elide-tern-test"` and confirm the override path still works.
- [ ] **Step 3: Commit** `feat(plugin): launch surfaces through elide tern`.

### Task 5: JSON lens and dead block removal

**Files:**
- Rewrite: `$TERN/plugin/host.luau`
- Modify: `$TERN/plugin/plugin.toml` (`host = "host.luau"`, `[[lenses]] id = "json" match = [...]`)

- [ ] **Step 1: Write** `host.luau`: state `{ lines: {string} }`; `line` appends `l.text`; `view` returns `tern.parse.json_tree(table.concat(state.lines, "\n"))` (nil when not JSON). No toasts or processes.
- [ ] **Step 2: Verify** `tern plugin reload elide` reports Ready; in a Tern shell run `elide project export` in a project and confirm the Native/Raw toggle shows a tree; run `echo hi` to confirm it is not claimed.
- [ ] **Step 3: Commit** `feat(plugin): render elide json output as native trees`.

### Task 6: Harness and docs

**Files:**
- Modify: `$TERN/tests/*.py` only if example argv changed (it should not); `$TERN/README.md`, `$TERN/docs/architecture.md` describe `elide tern` and the lens; `$ELIDE/docs` entry in `project/features/27-structured-surfaces.md` "Embedding and plugins" noting the shipped binary hosts surfaces.

- [ ] **Step 1: Run** `make check` in `$TERN`; `make test-testing RUNTIME=<built elide>` and `make test-serve RUNTIME=<built elide>` if a Tern desktop is available.
- [ ] **Step 2: Commit** `docs: describe native surface hosting in the elide binary`.
