import path from "node:path";

// The shared Elide VSCode sources the Compose helper bundles, by the module names it imports.
export const root = path.resolve(import.meta.dir, "..");
export const upstream = path.resolve(root, process.env.ELIDE_VSCODE_SOURCE ?? "../elide-vscode");
export const vscode = path.join(upstream, "packages/vscode");
export const sources: Record<string, string> = {
  "@elide/ide-core": path.join(upstream, "packages/core/src/index.ts"),
  "@elide/compose-render": path.join(vscode, "src/composeRender.ts"),
  "@elide/compose-backend": path.join(vscode, "src/composeBackend.ts"),
  "@elide/compose-komodo": path.join(vscode, "src/composeKomodo.ts"),
  "@elide/komodo-distribution": path.join(vscode, "src/komodoDistribution.ts"),
  "@elide/compose-runtime": path.join(vscode, "src/composeRuntime.ts"),
};
