import { plugin } from "bun";
import { sources } from "../scripts/compose-sources";

// Compose tests load the helper's modules from source: the shared upstream modules resolve as the build aliases them.
plugin({
  name: "elide-compose-sources",
  setup(build) {
    for (const [name, file] of Object.entries(sources)) build.module(name, async () => ({ exports: await import(file), loader: "object" }));
  },
});
