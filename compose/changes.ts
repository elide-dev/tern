import { watch, type FSWatcher } from "node:fs";
import path from "node:path";

/** Watch directories, not file inodes: atomic saves and new/deleted sources survive. */
export class PreviewChanges {
  private files = new Set<string>();
  private timer?: NodeJS.Timeout;
  private watcher: FSWatcher | undefined;

  constructor(
    root: string,
    private readonly signal: AbortSignal,
    accepts: (file: string) => boolean,
    private readonly onChange: (files: ReadonlySet<string>) => void,
    onError: (error: unknown) => void,
  ) {
    this.watcher = watch(root, { recursive: true }, (_event, name) => {
      const relative = name?.toString();
      if (relative && relative.split(path.sep).some(part => part.startsWith(".") || part === "node_modules")) return;
      const file = relative ? path.resolve(root, relative) : root;
      if (!relative || accepts(file)) this.request(file);
    });
    this.watcher.on("error", error => { this.dispose(); onError(error); });
    signal.addEventListener("abort", this.dispose, { once: true });
    if (signal.aborted) this.dispose();
  }

  /** Bursts (an atomic save, a branch switch) arrive as one set once 50 ms pass without another event. */
  private request(file: string): void {
    if (this.signal.aborted) return;
    this.files.add(file);
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      const files = this.files;
      this.files = new Set();
      this.onChange(files);
    }, 50);
  }

  dispose = (): void => {
    clearTimeout(this.timer);
    this.signal.removeEventListener("abort", this.dispose);
    this.watcher?.close();
    this.watcher = undefined;
  };
}
