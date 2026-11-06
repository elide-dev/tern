# Install the macOS preview

This preview includes the plugin, native helpers, runtime and embedded SDK. It requires
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

To remove the integration, run `tern plugin unlink elide`. Install a later preview into
a separate directory and run its installer to switch versions; keep the old directory
until its running sessions have closed.
