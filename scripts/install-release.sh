#!/bin/sh
set -eu

bundle_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]; then
  echo "This preview requires macOS on Apple Silicon." >&2
  exit 1
fi
if ! command -v tern >/dev/null 2>&1; then
  echo "Install Tern and enable its command-line tool before running this installer." >&2
  exit 1
fi
for name in broker worker android; do
  if [ ! -x "$bundle_root/dist/elide-tern-$name" ]; then
    echo "Incomplete release: missing executable dist/elide-tern-$name" >&2
    exit 1
  fi
done
if [ ! -x "$bundle_root/runtime/bin/elide" ] || [ ! -f "$bundle_root/sdk/embedder.json" ] ||
  [ ! -f "$bundle_root/sdk/lib/libelide_embed.dylib" ] || [ ! -f "$bundle_root/plugin/plugin.toml" ]; then
  echo "Incomplete release: runtime, SDK, or plugin is missing." >&2
  exit 1
fi

if [ ! -e "$bundle_root/plugin/config.json" ]; then
  cat > "$bundle_root/plugin/config.json" <<'JSON'
{
  "sdk": "../sdk",
  "broker": "../dist/elide-tern-broker",
  "runtime": "../runtime/bin/elide"
}
JSON
fi
tern plugin link "$bundle_root/plugin"
# Pkl highlighting: Tern loads grammars from its Syntaxes folder. Link ours unless the user keeps their own.
syntaxes="${TERN_CONFIG_DIR:-$HOME/Library/Application Support/tern}/syntaxes"
mkdir -p "$syntaxes"
if [ ! -e "$syntaxes/Pkl.sublime-syntax" ] || [ -L "$syntaxes/Pkl.sublime-syntax" ]; then
  ln -sfn "$bundle_root/plugin/syntaxes/Pkl.sublime-syntax" "$syntaxes/Pkl.sublime-syntax"
fi
echo "Restart Tern to load Pkl highlighting."
echo "Installed. Keep this release directory in place while using the plugin."
echo "Open Tern in a project directory, then choose Open project workspace."
