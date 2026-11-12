import { mkdir, rename } from "node:fs/promises";
import path from "node:path";

const root = path.resolve(import.meta.dir, "..");
const dist = path.join(root, "dist");
await mkdir(dist, { recursive: true });
const temporary = path.join(dist, ".elide-tern-android.new");
const result = await Bun.build({
  entrypoints: [path.join(root, "android/main.ts")],
  target: "bun",
  compile: { outfile: temporary, autoloadDotenv: false, autoloadBunfig: false },
  minify: true,
});
if (!result.success) {
  for (const message of result.logs) console.error(message);
  process.exitCode = 1;
} else {
  await rename(temporary, path.join(dist, "elide-tern-android"));
  console.log("Built dist/elide-tern-android");
}
