import { watch, type FSWatcher } from "node:fs";
import path from "node:path";

export interface Changes {
  revision: number;
  files: Set<string>;
}

/** Watch directories, not file inodes: atomic saves and new/deleted sources survive. */
export class PreviewChanges {
  revision = 0;
  private files = new Set<string>();
  private pending = false;
  private settled = false;
  private timer?: ReturnType<typeof setTimeout>;
  private waiter?: { resolve: (value: Changes) => void; reject: (error: unknown) => void };
  private failure?: unknown;
  private watchers: FSWatcher[] = [];

  constructor(root: string, job: string, private readonly signal: AbortSignal, accepts: (file: string) => boolean) {
    const workspace = watch(root, { recursive: true }, (_event, name) => {
      const relative = name?.toString();
      if (relative && relative.split(path.sep).some(part => part.startsWith(".") || part === "node_modules")) return;
      const file = relative ? path.resolve(root, relative) : root;
      if (!relative || accepts(file)) this.request(file);
    });
    this.watchers.push(workspace);
    try {
      this.watchers.push(watch(job, (_event, name) => {
        if (["refresh", "documents.json", "native-documents.json"].includes(name?.toString() ?? "")) this.request();
      }));
    } catch (error) { this.dispose(); throw error; }
    for (const watcher of this.watchers) watcher.on("error", error => {
      this.failure = error;
      this.waiter?.reject(error);
      this.waiter = undefined;
    });
    signal.addEventListener("abort", this.abort, { once: true });
    if (signal.aborted) this.abort();
  }

  request(file?: string): void {
    if (this.signal.aborted) return;
    if (file) this.files.add(file);
    this.revision++;
    this.pending = true;
    this.settled = false;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => { this.settled = true; this.deliver(); }, 200);
  }

  next(): Promise<Changes> {
    this.signal.throwIfAborted();
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      this.waiter = { resolve, reject };
      this.deliver();
    });
  }

  private deliver(): void {
    if (!this.pending || !this.settled || !this.waiter) return;
    const { resolve } = this.waiter;
    const files = this.files;
    this.files = new Set();
    this.waiter = undefined;
    this.pending = false;
    resolve({ revision: this.revision, files });
  }

  private abort = (): void => {
    this.waiter?.reject(this.signal.reason);
    this.waiter = undefined;
    this.dispose();
  };

  dispose(): void {
    clearTimeout(this.timer);
    this.signal.removeEventListener("abort", this.abort);
    for (const watcher of this.watchers) watcher.close();
    this.watchers = [];
  }
}
