# Elide for Tern

A Luau plugin backed by a native broker and disposable embedded Elide workers.
Notebook workers load the same C ABI and Cap'n Proto SDK used by Elide Studio.
Test and server hosts supervise the canonical runtime independently; GraalVM is
never loaded into Tern's UI process.

Native surfaces cover REPL, Tests, Debug, Compose previews, Android devices, serving and trace inspection. Project
sessions share runs and debugger state between views and the built-in agent. SDK LSP/MCP channels
have broker plumbing; standard client transports and live WebSocket MCP attachment
remain follow-up work.

## Install the preview

macOS Apple Silicon users with repository access can install the self-contained
[preview release](https://github.com/elide-dev/tern/releases), including its matched
runtime and SDK. See [installation instructions](docs/manual-install.md).

## Development

Requires Rust via rustup (this checkout pins the nightly required by `../elide`), Cap'n Proto
(capnp compiler), Python 3, Tern, Bun, and StyLua 2.5.2 (`mise install`). Native SDK execution
supports macOS arm64 and Linux amd64, subject to the selected SDK's deployment requirements.
The configured runtime must support `elide tern`; `make link` builds the helpers and links the plugin. The broker links
the runtime crates `elide-embed-host` and `elide-project-session` from a sibling `../elide`
checkout of `elide-dev/runtime`, so building needs access to that repository.

Compose builds also consume `../elide-vscode` (`ELIDE_VSCODE_SOURCE` overrides it).
Install that checkout's dependencies with its pinned pnpm first. `make compose` bundles its
shared project model, layoutlib renderer/runtime installer and Java sources into
`dist/elide-tern-compose`; Bun and the sibling checkout are not needed at runtime.
Release bundles must include this executable and `dist/elide-tern-compose.LICENSE`.
`make android` bundles the same checkout's SDK/manifest utilities into
`dist/elide-tern-android`, including its embedded emulator display. Releases also require
this executable and `dist/elide-tern-android.LICENSE`.

```sh
make build
make test
make check
cp plugin/config.example.json plugin/config.json
# Set sdk to a complete extracted embedded SDK directory.
make smoke SDK=/path/to/elide-embed
make test-surface SDK=/path/to/elide-embed RUNTIME=/path/to/elide
make link
```

`make link` installs the local plugin into Tern. Open **Elide → Open REPL**
from its command palette. The native REPL has a language picker with Tern's Material
language icons; Ctrl+L also opens it, arrows choose and Enter switches. Each language
retains its draft, undo state and history. The entire REPL shares one notebook kernel. Enter evaluates and Shift+Enter
inserts a newline. `/help` lists the shared REPL commands. Clear clears the transcript;
it does not reset the runtime.

### Project workspace

Open Tern in a directory containing `elide.pkl` (or any child directory), then click
**Workspace** in the status bar or choose **Open project workspace** in the palette.
This creates a project tab with Tern's Files browser, native file editor, a terminal,
and a compact icon toolbar for Build, Test, Run, Debug, REPL, and static serving.
The play button runs the project's tests on the full Tests page; `elide test` typed in a
terminal draws inline instead.
Buttons have hover labels and accessible names. All panes use Tern's normal
adjustable splits. Opening the workspace again refreshes its toolbar without resetting
your layout. Project actions retain their original root as focus changes.

The editor starts with `elide.pkl`; ordinary Files clicks reuse that editor within
the active project workspace. Explicit split/tab opens retain Tern's placement,
and modified selection gestures stay native. Unsaved documents remain available
when another file opens over them. The bottom terminal launches in the project
root; reopening a workspace preserves an existing shell's current directory.
Editing, undo, saving, and dirty buffers belong to Tern's native editor. Test/REPL/server
results open beside the editor; clicking their action again focuses the existing pane.
Build and Run currently use the runtime's terminal output and normal Tern process lifetime.
This does not yet register Elide LSP providers, debugger decorations, or coverage gutters.

`make test-workspace` verifies native file routing, unsaved edits, project isolation
and the terminal's actual working directory in an isolated desktop window.

The SDK executes JavaScript and Python with shared live bindings: define
`const y = {hi: 5}` in JavaScript, switch to Python and evaluate `y.hi`.
Statements stay silent and object results render as expandable native JSON trees.
Language labels appear only when the cell language changes. CEL evaluates shared
data snapshots; Pkl evaluates modules and publishes its JSON result as `_`.
Kotlin supports module declarations, not bare expressions or automatic `main`
execution. TypeScript and Wasm still need execution adapters.

`make repl` builds the shared frontend from the sibling `../elide` checkout through
its Makefile. Override `ELIDE_SOURCE` for another checkout. `make test-surface` opens
an isolated headless Tern renderer and tests real kernels, icons, pointer/keyboard
switching, preserved drafts/bindings and teardown. Captures go in `.dev/scratch/`.
The launcher currently supports local hosts; remote hosts require their own native
launcher and SDK installation.

`plugin/config.json` is ignored. The default broker is `../dist/elide-tern-broker`;
keep `elide-tern-worker` beside it. Every native surface launches as
`<runtime> test|serve <subject>` or `<runtime> tern <repl|project|debug>`, so a runtime built from a branch with
that command needs no separate launchers. The plugin probes each runtime path once with
`tern --help` before its first launch and reports a runtime that lacks the command
instead of letting an older runtime resolve `tern` as a project script. The optional `repl`, `serve`, `test`,
`project` and `debug` settings name an explicit launcher executable for one surface,
which the `dist/elide-tern-*` development shims built by `make link` provide. An optional `state` setting selects a short,
private broker directory if Tern's plugin-data path exceeds Unix socket limits.
Never store SDK binaries or machine-specific configuration in source control.
The native SDK is user-supplied; no archive is downloaded automatically.

`make types` exports the installed Tern's Luau definitions. Formatting checks
parse Luau; a successful build does not establish visual acceptance in Tern.

See [architecture](docs/architecture.md), [broker protocol](docs/protocol.md),
and [upstream provenance](third_party/README.md).

### Compose previews

Open a saved Kotlin `.kt` file and choose **Open Compose preview**, or click **Preview**
in the project workspace toolbar. The native gallery renders `@Preview`, multipreview,
member-function and `@PreviewParameter` cards beside the source. Click an image for Tern's
zoom viewer; **Open source** returns to the file.

Opening a preview resolves the enclosing Elide workspace and selects the nearest Android APK
consuming that source set. The initial build prepares JVM classes and Android resources.
The helper then keeps the same shared incremental compiler and renderer
running. Kotlin/Java edits in native and Elide source editors, including unsaved buffers,
refresh automatically; saved dependency sources are watched too. **Refresh** retries without
restarting the helper. Resource and project-configuration saves rebuild the required inputs
automatically. Build-only source processing still requires saving, as in VS Code.
Preview code executes locally with your permissions: open only projects you trust.

During rendering, a progress bar shows the current phase: project loading, renderer setup,
build or preview update. **Show details** expands renderer output. The last gallery stays
visible during updates; progress clears when rendering finishes or fails.

Requires an Android-capable Elide runtime, the project's Android SDK/dependencies, and a JDK 17+.
On first render, the shared installer downloads the pinned, SHA-256-verified layoutlib runtime
from Google Maven. Supported plugin hosts are macOS arm64/x64 and Linux x64.
Optional `plugin/config.json` settings:

- `compose`: helper executable; defaults to `../dist/elide-tern-compose`.
- `compose_java`: JDK's `java` executable; otherwise uses the resolved project JDK.
- `compose_cache`: renderer cache directory; defaults to the plugin's data directory.
- `compose_komodo`: optional compatible Komodo launcher override for live previews.
  Otherwise the helper resolves Komodo from the Elide installation.

Compile/build errors retain the last gallery with an error status; the next edit can recover.
Rendering failures appear on individual cards. **Cancel** and closing the pane stop active work.
Plugin reload cancels work and restores an idle panel; it never automatically executes previews.
Workspace builds serialize, while open previews keep their private compilers and renderers.
After a forced helper kill during a build, remove its lock **only after confirming its
Elide/JVM build processes have stopped**.

**Live preview** switches to a Tern browser pane beside the gallery.
It uses Komodo's protocol-2 `workspace-fir` preview session.
Click to focus a card, drag or scroll to interact, and type when the card reports keyboard
support. Escape releases input. Frames and composition state update without rebuilding.
Wheel input is translated to touch drags for the Android layoutlib host.
Animation fidelity follows the installed Komodo/layoutlib host; the tested Komodo build
can stall infinite transitions at a cycle boundary even while coroutine timers advance.

Live mode requires a compatible Komodo distribution with Compose compiler plugins.
An unavailable or incompatible runtime produces an error.
Both preview modes observe editor and saved-source changes. **Refresh** retries the current
inputs; resource/configuration saves rebuild and reopen the live backend automatically.
Source refreshes reuse the session but may reset composition state.
IME composition and clipboard paste are not supported by the live keyboard protocol.

The native pane owns the live session: **Cancel**, closing it or plugin reload stops the
helper and Komodo. Closing the browser pane also stops the session after a five-second
reload grace period. Only one browser controls a session. Its loopback URL contains a
temporary access token; do not share it.

Layout inspection, arbitrary-composable agent rendering, MCP and prewarming are not
provided. Galleries allow 32 cards, 8 MiB per PNG, 32 MiB in total and 4096 pixels per side.
No embedded SDK is required for Compose itself.

### Android devices

Choose **Show device manager** from the palette, even outside an Elide project. The
native manager lists virtual devices (AVDs) with their running emulator serials, then
attached physical devices; an icon marks each row as virtual or physical. Icon buttons
create and refresh in the header, and start, show, stop and delete on each row, shown only
when applicable; their tooltips name them. Palette commands create, start, stop and delete
virtual devices, and **Show Android device** picks any running emulator or connected
device; they work without a project too. **Refresh** reads changes made by Android Studio
or other terminals; its tooltip names the SDK. A line under the list counts virtual devices
and connected physical devices. Deletion asks for confirmation and refuses running or locked
devices; creation never overwrites an existing device.

The project menu and workspace toolbar offer **Show device manager** for the project.
This evaluates the project's Android configuration using the configured Elide runtime;
workspaces with multiple Android members show a member picker. A header button creates the
project's configured device with Elide's `android-avd` target and configured settings.
Custom creation selects an installed system image, hardware profile and name. Non-Android
projects report a configuration error; use the standalone manager instead.

Requires a local Android SDK with Emulator, Platform-Tools, Command-line Tools and a
JDK for `avdmanager`. Install system images with Android Studio or `sdkmanager` first:
the helper does not install packages or accept licenses. SDK resolution follows Elide:
explicit `android_sdk` override, project `android.sdk`, environment, conventional SDK
locations. An explicit missing path fails rather than silently selecting another SDK.
Optional `plugin/config.json` settings:

- `android`: helper executable; defaults to `../dist/elide-tern-android`.
- `android_sdk`: SDK directory override, distinct from the embedded Elide `sdk` setting.

**Start** opens the device pane at once and starts the emulator there, without an OS
window: the pane shows the device's name, an animated bar and the current step (starting,
connecting, waiting for the screen) with the elapsed time, then the screen. A failed start
stays on screen with its error until the pane is closed; closing the pane before the
emulator registers stops it again. **Show** opens a running device. The device pane takes
the place of an open Compose preview, else of the manager; the manager closes either way.
Showing a device that already has a pane moves that pane there. The pane draws the screen
with the kitty graphics protocol from the emulator's gRPC screenshot stream and updates
whenever the screen changes. Clicks and drags are touches, Alt+drag is a two-finger pinch or
rotate, and the wheel scrolls. Keys and pasted text go to the device. A rounded, outlined,
translucent bar below the screen, only as wide as its buttons, holds quiet icon buttons in
Tern's style, highlighted on hover and press: Back, Home and Recent apps in the pane's center,
Power and the volume keys to their left, the rotation buttons and Close to their right, each
group set off by a separator. Notices show left of the bar. Narrow panes drop the rotation
buttons first, then Power and the volume keys.

Typing and the hardware buttons need the AVD's keyboard input (`hw.keyboard = yes` in its
`config.ini`). **Create** enables it, as Android Studio does; for other AVDs the pane names
the setting when it drops a key. Touches land on the center of the terminal cell under the
pointer, because Tern rounds the cell size it reports.

**Show** on a physical device (connected over USB or Wi-Fi, with USB debugging allowed)
mirrors it in the same kind of pane, over adb alone: nothing is installed on the device.
Frames come from `screenrecord`, sized to the pane and sent only when the screen changes;
the pane follows the device's rotation. Each touch is sent when the button is released: a
click is a tap, a held click a long press, a drag one swipe from its start to its end, so the
device shows the drag only afterwards. Alt+drag sends one finger. Typing covers ASCII text
and named keys; modifier shortcuts and the wheel need Android 13 or later (older releases
scroll with a short swipe). The rotation buttons lock the orientation, turning auto-rotate
off on the device. Unauthorized or offline devices are listed without **Show**.

When an emulator's pane closes, through its Close button or Tern's, Tern asks whether to
stop the emulator too, unless it already stopped; **Keep it running** or Escape leaves it
running. **Stop** terminates only the selected emulator; its pane then closes, as does a
mirror whose device disconnects.
Emulators started elsewhere (for example by Android Studio) expose no token-authenticated
gRPC endpoint and cannot be shown: stop them, then start them from Tern. Audio plays on the
host. On macOS, start uses host GPU rendering (`-gpu host`).

The compiled helper also works directly from any terminal, with no Tern, Bun, sibling
checkout or Elide runtime required unless `--root` is supplied:

```sh
dist/elide-tern-android list
dist/elide-tern-android images
dist/elide-tern-android profiles
dist/elide-tern-android create --name demo \
  --image 'system-images;android-36;default;arm64-v8a' --device pixel_6
dist/elide-tern-android start --name demo              # no OS window
dist/elide-tern-android display --name demo            # in a kitty-graphics terminal
dist/elide-tern-android display --name demo --start    # start it there, showing progress
dist/elide-tern-android display --serial R5CT1234ABC   # mirror a physical device
dist/elide-tern-android stop --name demo               # or --serial emulator-5554
dist/elide-tern-android delete --name demo --yes
dist/elide-tern-android create --root /path/to/android-project --runtime elide
```

Choose an image/ABI reported by `images` for your machine. `--sdk PATH` overrides SDK
discovery; `--json` emits structured results/errors. For ambiguous workspaces, CLI callers
pass the Android member directory as `--root`. A conflicting manifest `android.sdk`
cannot be overridden for Elide's configured creation target: correct it or create a
custom AVD. Helpers support macOS/Linux SDK tools; Windows `.bat` launchers are not supported.

With an installed, host-compatible image, run
`make test-android ANDROID_IMAGE='system-images;android-34;default;arm64-v8a'`
(optionally `ANDROID_SDK=/path/to/sdk`). This creates an isolated AVD, checks its keyboard
setting, overwrite and deletion protection, starts/stops/restarts it, draws one display frame
over a pseudo-terminal, then deletes it. It also covers the persistent advisory lock
Android leaves behind after a clean emulator exit.

### Debugging

Choose **Debug** in the project workspace or **Debug project source** in the command
palette. If a supported source file is open in the workspace editor, Debug launches
it; otherwise enter a project-relative path in the panel. The toolbar requires saving
an edited source file before launch; targets execute files on disk. JavaScript/TypeScript
and Python use the runtime's guest debugger. Select **Tests** to debug a JavaScript test file through the test runner.

Add `file:line` breakpoints before launch or while stopped. The panel shows adapter
verification, call stacks, scopes, Continue, Step over/in/out, Pause and Stop. Source
links open the selected frame in Tern's native editor. **Inspect values** and nested
**Inspect** buttons explicitly request value formatting, which may execute guest
getters; inspecting never happens automatically. Old values clear when execution resumes.

One attachment controls execution; other panels and Carly can observe the same
pause. **Take control** transfers ownership and revokes queued controls from the
previous owner. Closing the controlling view starts a 30-second grace period for
another attachment to take over, then stops the target. Stop ends it immediately.
Debug-test runs cannot overlap ordinary tests writing to the same project output.

Build the development shim with `make debugging` (`make link` includes it).
`config.debug` can override the launcher; runtime and project-state settings are shared with Tests.
`make test-debug RUNTIME=/path/to/elide` validates JavaScript and Python in a real
Tern desktop, including value browsing, source navigation, agent/UI handoff, stale
commands, debug tests, busy-program Pause and teardown. Native editor gutter
breakpoints, expression watches, late attachment and JVM debugging remain separate work.

### Servers

Choose **Serve directory or script** in Tern's command palette, or type `elide serve`
in any Tern terminal. Both use the canonical Rust serving surface, independently of REPL workers.
Directories bind an available loopback port; scripts use `runtime` from
`plugin/config.json` (default `elide` on PATH). Relative runtime paths resolve from
the plugin directory. The `serve` setting overrides the surface launcher.

The dashboard provides actual bound URLs, observed request status/latency, clickable
request details, bounded logs, stop and restart. Closing it stops the supervised
server process group. Runtime readiness/request events currently require
`Elide.serve`; other APIs, including `node:http`, expose process controls and logs
without guessed readiness or request data. Local OTLP trace inspection is described below.

`make test-serve RUNTIME=/path/to/elide` exercises static and runtime HTTP requests,
failures, restart and teardown in an isolated Tern renderer. Without `RUNTIME`, it
runs the static serving checks.

### Trace inspection

Local capture starts with the server. **Traces** opens a compact trace list beside
the selected request's waterfall and browsable span details. The server URL and
status stay visible. **Errors** filters failures; **Requests** returns to request history.
**Pause capture**, **Resume capture**, and **Clear traces** work live without
restarting the server or changing its application state or remote exporters.
Pausing retains the existing bounded history; closing the session releases the receiver.

The receiver accepts OTLP/HTTP protobuf and JSON (including gzip), with a 2 MiB
payload limit. Retention is bounded to 512 records, 4 MiB, and five minutes;
eviction, rejection and truncation are visible. Metrics, profiles and gRPC ingestion
are not included yet. Static server spans measure handler work through response
construction, not network delivery.

`make test-telemetry RUNTIME=/path/to/elide` checks real nested runtime spans,
correlated logs, trace rendering, preservation of a second exporter, repeated live pause/resume, clear, runtime state
continuity and teardown. `python3 tests/telemetry.py --static` checks the static server path.

### Tests

Choose **Run tests** in Tern and enter a project directory or test file, or type
`elide test` in any Tern terminal: the shipped binary negotiates the surface itself and
keeps plain output for reporters and redirected output. The surface provides live results, failure
filtering, original diagnostics, per-test output, source links, rerun and cancel.
It uses `config.runtime`; `config.test` optionally overrides the launcher path.
Inside a detected project, Tests attaches to a shared project host. Closing its view
leaves tests running; **Cancel** stops them explicitly. **View project test runs**
reconnects to recent results, and another view can observe the same run without
launching it again. Recent runs are selectable in the native UI.
Whole-project runs include JVM tests; individual paths remain explicit test filters.

**Run with coverage** collects a measured artifact for that invocation. The
**Coverage** tab shows file coverage and covered/uncovered line details, with branch
counters where the runtime supplies them. Select a line and follow **Open current
source** into Tern's native editor, then save and rerun. Reruns preserve the selected
run's coverage option; earlier measurements remain unchanged. JavaScript fingerprints
come from the text evaluated by Truffle. These panels show measured source versions;
they do not claim live buffer freshness or install native editor gutters.

Build the development shim with `make project` (`make link` includes it). `config.project`
can override the launcher and `config.project_state` selects a short private host
directory. Development builds currently consume the shared `elide-project-session`
crate from the sibling Elide checkout, alongside the existing surface build dependency.

Raw reports are saved under the target directory's `.dev/reports/tests/tern/`.
Run the real Tern integration test with `make test-testing RUNTIME=/path/to/elide`.
Run `make test-sessions RUNTIME=/path/to/elide` for two-window attachment, live shared
results, duplicate-command protection, reconnect, rerun and cancellation checks.
`make test-project PROJECT=/path/to/project` opens an isolated desktop Tern window
and verifies native tab launches, REPL, serving, and tests in that existing project.
`make test-coverage RUNTIME=/path/to/elide` exercises coverage, native source/line
navigation, editing, reruns and paged agent reads in an isolated desktop window.

### Terminal integration

Inside a detected project, tabs take the project's name (names you give a tab win)
and the status bar shows the project, **Workspace**, and how the pane's last
`elide test`, `build` or `run` ended. Click the project segment for the project menu.
A failing `elide test` typed in a terminal toasts "Tests failed". Choosing `elide.pkl`
from the palette opens that project's workspace.

`elide build` in a Tern terminal draws Elide's Build surface on runtimes that have one.
On older runtimes, and for `elide javac` and `elide kotlinc`, the build lens shows the
compiler's errors and warnings as cards grouped by file, with counts and an **Open** link to
each location; `elide test --reporter=tap` shows a pass/fail summary with a table of results.
Both fall back to the raw output when nothing parses or the output is very large. After a
typed `elide build`, the status bar reads, for example, "Build failed · 3 errors, 1 warning",
and the workspace's Build button opens the full Build page when the runtime has one.

`elide://source`, `elide://debug`, `elide://tests` and `elide://help` links open a source line (in the
[source editor](#source-editor) for project sources), the debugger, project test runs or a help topic. Elide prints them; any program can, as OSC 8 hyperlinks.
Links that leave their project root are ignored. See
[the contract](docs/architecture.md#elide-links). Run `lua tests/links.lua` for the
parser's unit tests and `python3 tests/integration.py --runtime /path/to/elide` for the
lenses, links and status line in an isolated window.

### Source editor

**Open with Elide source** (from a file's menu), the workspace toolbar's **Source** button,
or **Open Elide source…** in the project menu opens a project source file in Elide's own
editor: Tern's highlighting, undo and redo, auto-indent, indent and comment toggles, find
(⌃F), go to line (⌃G), soft wrap (⌥Z), save with ⌘S, and a reload when the file changes on
disk. Overlays appear when they can act: **Coverage** tints covered, uncovered and
partially covered rows from the newest coverage run (F5 runs one) while you keep editing, and **Debug** sets breakpoints with F9 and launches with F5,
then shows Resume, Pause, Stop and stepping controls (F5, F6, ⇧F5, F10, F11, ⇧F11) only
while a debug session exists, with breakpoint and paused rows tinted. Switching overlays only
fades colors; no text moves. A hotness overlay will appear once
the project session records source-located profile samples. Files over 600 lines are shown without highlighting
to keep typing fast. `elide://source` links open this editor for sources inside a project.
Once a build has left a report, **Diagnostics** marks its errors and warnings: a gutter sign,
a tinted row, a dotted underline on the token and the message beside the line; F8 and ⇧F8
step through them. Java files open here too.
Run `lua tests/source.lua` for its text model and `python3 tests/source.py --runtime
/path/to/elide` for the editor itself.
`lua tests/diagnostics.lua` checks the shared compiler-output parser, and
`python3 tests/diagnostics_overlay.py --runtime /path/to/elide` checks the overlay, the
build lens, the status segment and the Build button.

### Built-in agent project tools

Carly receives a cached project hint and asynchronous exports:
`project_open(root)`, `project_read(binding)`, `test_run(binding, subject, command)`,
`test_cancel(binding, run)`, and `project_close(binding)` under `plugins.elide`.
Opening returns an explicit project binding; changing focused tabs cannot retarget
it. Reads renew the 60-second attachment lease and return bounded run/failure summaries.
Use a fresh UUID command for an intentional run and retain it for retries. Native
Tests views observe agent-started runs through the same project host.

`test_cover(binding, subject, command)` starts tests with coverage.
`coverage_read(binding, run, {})` lists measured files; pass `{file=N}` for the
zero-based file index's lines. Both forms accept `offset` and `limit` (maximum 100)
and return `next` for pagination. `project_read` includes coverage state and totals.

This bridge uses Tern's callable exports and local IPC. It does not claim WebSocket
MCP or automatic attachment to other agent harnesses. `make test-project` exercises
actual Carly Lua exports against native Elide and verifies visible results and retry
deduplication without invoking a model.
