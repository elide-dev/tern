import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

// The same source dependency as the native Elide surfaces: bundle the shared implementation,
// not a second copy of its project/classpath rules. No sibling files are read at runtime.
const root = path.resolve(import.meta.dir, "..");
const upstream = path.resolve(root, process.env.ELIDE_VSCODE_SOURCE ?? "../elide-vscode");
const vscode = path.join(upstream, "packages/vscode");
const resolve = createRequire(path.join(vscode, "package.json"));
const yauzl = resolve.resolve("yauzl");
const yauzlRoot = path.dirname(yauzl);
const pendRoot = path.dirname(createRequire(yauzl).resolve("pend/package.json"));
const licenses = (await Promise.all([
  ["Elide VSCode/core and Java renderer helpers (MIT)", path.join(upstream, "LICENSE")],
  ["yauzl (MIT)", path.join(yauzlRoot, "LICENSE")],
  ["pend (MIT)", path.join(pendRoot, "LICENSE")],
].map(async ([name, file]) => `${name}\n\n${await readFile(file!, "utf8")}`))).join("\n\n---\n\n");
const helpers = Object.fromEntries(await Promise.all(
  ["CompileRenderer.java", "DiscoverPreviews.java", "RenderServer.java"].map(async (name) =>
    [name, await readFile(path.join(vscode, "media/compose", name), "utf8")]),
));
const aliases: Record<string, string> = {
  "@elide/ide-core": path.join(upstream, "packages/core/src/index.ts"),
  "@elide/compose-render": path.join(vscode, "src/composeRender.ts"),
  "@elide/compose-backend": path.join(vscode, "src/composeBackend.ts"),
  "@elide/compose-komodo": path.join(vscode, "src/composeKomodo.ts"),
  "@elide/komodo-distribution": path.join(vscode, "src/komodoDistribution.ts"),
  "@elide/compose-runtime": path.join(vscode, "src/composeRuntime.ts"),
  yauzl,
};
const virtual: Record<string, unknown> = {
  "@elide/compose-helpers": helpers,
  "@elide/compose-licenses": licenses,
};
const dist = path.join(root, "dist");
await mkdir(dist, { recursive: true });
const temporary = path.join(dist, ".elide-tern-compose.new");
const result = await Bun.build({
  entrypoints: [path.join(root, "compose/main.ts")],
  target: "bun",
  compile: { outfile: temporary, autoloadDotenv: false, autoloadBunfig: false },
  minify: true,
  plugins: [{
    name: "elide-compose-sources",
    setup(build) {
      build.onResolve({ filter: /^(@elide\/(ide-core|compose-render|compose-backend|compose-komodo|komodo-distribution|compose-runtime|compose-helpers|compose-licenses)|yauzl)$/ }, (args) => {
        if (Object.hasOwn(virtual, args.path)) return { path: args.path, namespace: "embedded" };
        return { path: aliases[args.path]! };
      });
      build.onLoad({ filter: /.*/, namespace: "embedded" }, (args) => ({
        contents: `export default ${JSON.stringify(virtual[args.path])};`, loader: "js",
      }));
    },
  }],
});
if (!result.success) {
  for (const message of result.logs) console.error(message);
  process.exitCode = 1;
} else {
  await writeFile(path.join(dist, "elide-tern-compose.LICENSE"), licenses);
  await rename(temporary, path.join(dist, "elide-tern-compose"));
  console.log("Built dist/elide-tern-compose (shared renderer and Java helpers embedded)");
}
