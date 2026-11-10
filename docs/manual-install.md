# Install the macOS preview

This preview includes the plugin, broker and worker, runtime and embedded SDK.
Native surfaces are hosted by the bundled runtime through `elide tern`. It requires
Tern with its `tern` command available, and macOS on Apple Silicon. No source checkout,
Rust compiler or separate Elide installation is needed.

The repository currently has Internal visibility, so downloading requires repository access.
Download the macOS archive and `SHA256SUMS` from the GitHub release, then verify and unpack:

```sh
shasum -a 256 -c SHA256SUMS
tar -xzf elide-tern-0.1.0-preview.1-macos-arm64.tar.gz
```

Move the extracted directory to a permanent location of your choice. From that directory:

```sh
sh ./install.sh
```

The installer checks the bundle, writes its local configuration if absent, and registers
the plugin with Tern. It preserves an existing configuration. Keep the directory in place:
Tern links to it rather than copying the runtime and SDK into its plugin folder.

Run `tern` in a directory containing `elide.pkl`, or any child directory, and choose
**Open project workspace** in the command palette. The workspace includes Files, the
native editor, a project terminal, and the Build/Test/Run/Debug toolbar. **Open REPL**
also works without a project.

Compose-enabled bundles also include `dist/elide-tern-compose` and its `.LICENSE`
notice. Choose **Open Compose preview** on a saved Kotlin file, or **Preview** in
the workspace toolbar. This additionally requires an Android-capable runtime,
the project's Android SDK/dependencies and a JDK 17+; layoutlib downloads on first
use. Bun and VSCode are not required. See [Compose previews](../README.md#compose-previews)
for the supported snapshot subset and configuration.

Android device management also requires `dist/elide-tern-android` and its `.LICENSE`
notice, plus a separately installed Android SDK (Emulator, Platform-Tools, Command-line
Tools and system images) and JDK. **Manage Android Virtual Devices** works without a
project; the project menu and workspace toolbar resolve Android project configuration.
**View** embeds an interactive ADB screenshot mirror in a browser pane. See
[Android Virtual Devices](../README.md#android-virtual-devices) for CLI commands and limits.

To remove the integration, run `tern plugin unlink elide`. Install a later preview into
a separate directory and run its installer to switch versions; keep the old directory
until its running sessions have closed.
