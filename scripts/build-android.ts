import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

// Bundle the shared SDK/manifest/workspace implementation; no sibling source is read at runtime.
const root = path.resolve(import.meta.dir, "..");
const upstream = path.resolve(root, process.env.ELIDE_VSCODE_SOURCE ?? "../elide-vscode");
const license = `Elide VSCode/core (MIT)\n\n${await readFile(path.join(upstream, "LICENSE"), "utf8")}`;
const dist = path.join(root, "dist");
await mkdir(dist, { recursive: true });
const temporary = path.join(dist, ".elide-tern-android.new");
const result = await Bun.build({
  entrypoints: [path.join(root, "android/main.ts")],
  target: "bun",
  compile: { outfile: temporary, autoloadDotenv: false, autoloadBunfig: false },
  minify: true,
  plugins: [{
    name: "elide-android-sources",
    setup(build) {
      build.onResolve({ filter: /^@elide\/ide-core$/ }, () => ({
        path: path.join(upstream, "packages/core/src/index.ts"),
      }));
    },
  }],
});
if (!result.success) {
  for (const message of result.logs) console.error(message);
  process.exitCode = 1;
} else {
  await writeFile(path.join(dist, "elide-tern-android.LICENSE"), license);
  await rename(temporary, path.join(dist, "elide-tern-android"));
  console.log("Built dist/elide-tern-android (shared Android/project core embedded)");
}
