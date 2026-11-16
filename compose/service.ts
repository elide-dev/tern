import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, constants, openSync } from "node:fs";
import { access, mkdir, mkdtemp, open as openFile, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { promisify } from "node:util";
import {
  ElideCli, MANIFEST_NAME, buildProjectModels, composePreviewApplications, composePreviewBuildTargets,
  findEnclosingWorkspace, whichExecutable, type AndroidTargetModel, type ProjectModel,
} from "@elide/ide-core";
import type { CompileMessage, PreviewGallery, PreviewRequest } from "@elide/compose-backend";
import type { PreviewImage } from "@elide/compose-render";
import { ensureComposeRuntime, type ComposeRuntime } from "@elide/compose-runtime";
import helperSources from "@elide/compose-helpers";
import { createStack, type Stack } from "./live";
import { createPreviewServer, type DocumentsPost, type EndReason, type PreviewServer } from "./server";
import { PreviewChanges } from "./changes";

const run = promisify(execFile);
const MAX_SOURCE = 8 * 1024 * 1024;
const MAX_DOCUMENTS = 32 * 1024 * 1024;
const LOG_LINES = 200;
const NO_APPLICATION = "No Android APK consumes this saved file's production source set. Open a Kotlin source owned by an Android application or one of its workspace libraries; test-only and unowned sources cannot be previewed.";

export type OpenArgs = { runtime: string; root: string; file: string; cache: string; java?: string; komodo?: string; "keep-alive"?: string };
export type ServeArgs = { runtime: string; root: string; cache: string; state: string; java?: string; komodo?: string };
type ServiceRecord = { pid: number; port: number; control: string };
type EditorDocument = { file: string; text: string };

export function under(root: string, file: string): boolean {
  const relative = path.relative(root, file);
  return relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

export function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function sourceBytes(file: string): Promise<Buffer> {
  const handle = await openFile(file, "r");
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.size > MAX_SOURCE) throw new Error("The saved Kotlin source must be a regular file no larger than 8 MiB.");
    // Bounded even if the source is being extended while it is read.
    const bytes = Buffer.alloc(info.size + 1);
    const { bytesRead } = await handle.read(bytes, 0, bytes.length, 0);
    if (bytesRead !== info.size) throw new Error("The source changed while being read. Save it and rebuild the preview.");
    return bytes.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

/** A file's saved text, undefined when it is gone or not a readable regular file. */
async function diskText(file: string): Promise<string | undefined> {
  try { return (await sourceBytes(file)).toString("utf8"); }
  catch { return undefined; }
}

/** Remove Kotlin comments and literals, not backtick identifiers, before looking for the declaration. */
function packageName(source: string): string {
  const pieces: string[] = [];
  let cursor = 0;
  let copied = 0;
  while (cursor < source.length) {
    const start = cursor;
    if (source.startsWith("//", cursor)) {
      cursor = source.indexOf("\n", cursor + 2);
      if (cursor < 0) cursor = source.length;
    } else if (source.startsWith("/*", cursor)) {
      cursor += 2;
      let depth = 1;
      while (cursor < source.length && depth) {
        if (source.startsWith("/*", cursor)) { depth++; cursor += 2; }
        else if (source.startsWith("*/", cursor)) { depth--; cursor += 2; }
        else cursor++;
      }
    } else if (source.startsWith('"""', cursor)) {
      const end = source.indexOf('"""', cursor + 3);
      cursor = end < 0 ? source.length : end + 3;
    } else if (source[cursor] === '"' || source[cursor] === "'") {
      const quote = source[cursor++];
      while (cursor < source.length) {
        if (source[cursor] === "\\") cursor += 2;
        else if (source[cursor++] === quote) break;
      }
    } else if (source[cursor] === "`") {
      const end = source.indexOf("`", cursor + 1);
      cursor = end < 0 ? source.length : end + 1;
      continue;
    } else { cursor++; continue; }
    pieces.push(source.slice(copied, start), source.slice(start, cursor).replace(/[^\r\n]/g, " "));
    copied = cursor;
  }
  pieces.push(source.slice(copied));
  const text = pieces.join("");
  const identifier = "(?:`[^`\\r\\n]+`|[\\p{L}_][\\p{L}\\p{N}_]*)";
  const declaration = new RegExp(`^\\s*package\\s+(${identifier}(?:\\s*\\.\\s*${identifier})*)`, "mu").exec(text);
  return declaration?.[1]?.replace(/`/g, "").replace(/\s*\.\s*/g, ".") ?? "";
}

async function executable(value: string, label: string): Promise<string> {
  const candidate = value.includes("/") || value.includes("\\") ? path.resolve(value) : whichExecutable(value);
  if (!candidate) throw new Error(`${label} executable not found: ${value}`);
  const resolved = await realpath(candidate);
  if (!(await stat(resolved)).isFile()) throw new Error(`${label} is not an executable file: ${resolved}`);
  await access(resolved, constants.X_OK);
  return resolved;
}

async function extractHelpers(cache: string, signal: AbortSignal): Promise<string> {
  const names = ["CompileRenderer.java", "DiscoverPreviews.java", "RenderServer.java"];
  const hash = createHash("sha256");
  for (const name of names) {
    if (typeof helperSources[name] !== "string" || !helperSources[name]) throw new Error(`The helper binary is missing embedded ${name}. Reinstall the plugin.`);
    hash.update(name).update("\0").update(helperSources[name]);
  }
  const root = path.join(cache, "compose-sources");
  const destination = path.join(root, hash.digest("hex"));
  const ready = async (): Promise<boolean> => {
    try {
      for (const name of names) if (await readFile(path.join(destination, name), "utf8") !== helperSources[name]) return false;
      return true;
    } catch { return false; }
  };
  if (await ready()) return destination;
  await mkdir(root, { recursive: true });
  const staging = await mkdtemp(path.join(root, "staging-"));
  try {
    for (const name of names) {
      signal.throwIfAborted();
      await writeFile(path.join(staging, name), helperSources[name], { flag: "wx" });
    }
    signal.throwIfAborted();
    try { await rename(staging, destination); }
    catch (error) { if (!await ready()) throw error; }
    return destination;
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

/** The saved `.kt` file and the outermost Elide workspace that contains `root` and it. */
async function resolveSource(file: string, suppliedRoot: string): Promise<{ source: string; root: string }> {
  if (!path.isAbsolute(file) || path.extname(file) !== ".kt") throw new Error("Open an existing .kt file using its absolute path; untitled files and .kts scripts are not supported.");
  let root = await realpath(path.resolve(suppliedRoot));
  if (!(await stat(root)).isDirectory()) throw new Error("The project root is not a directory.");
  const source = await realpath(file);
  if (!under(root, source)) throw new Error("The saved Kotlin file is outside the selected project/workspace root.");
  for (let workspace = findEnclosingWorkspace(root); workspace; workspace = findEnclosingWorkspace(root)) {
    root = await realpath(workspace.root);
  }
  if (!(await stat(path.join(root, MANIFEST_NAME)).catch(() => undefined))?.isFile()) throw new Error(`No ${MANIFEST_NAME} found at ${root}. Open an Elide project or workspace.`);
  if (!under(root, source)) throw new Error("The source resolves outside its Elide workspace.");
  await sourceBytes(source);
  return { source, root };
}

function editorDocuments(value: unknown): EditorDocument[] {
  if (!value || typeof value !== "object" || !("documents" in value) || !Array.isArray(value.documents)) throw new Error("Invalid editor documents on stdin.");
  return value.documents.map((entry: unknown) => {
    if (!entry || typeof entry !== "object" || !("file" in entry) || !("text" in entry) || typeof entry.file !== "string" || typeof entry.text !== "string") throw new Error("Invalid editor document on stdin.");
    return { file: entry.file, text: entry.text };
  });
}

async function readRecord(file: string): Promise<ServiceRecord | "invalid" | undefined> {
  let text: string;
  try { text = await readFile(file, "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
  try {
    const value = JSON.parse(text);
    if (Number.isSafeInteger(value?.pid) && value.pid > 0 && Number.isSafeInteger(value.port) && value.port > 0 && value.port < 65536
      && typeof value.control === "string" && /^[0-9a-f]{64}$/.test(value.control)) return { pid: value.pid, port: value.port, control: value.control };
  } catch {}
  return "invalid";
}

function running(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code !== "ESRCH"; }
}

/** The command line that runs this helper again: the compiled binary itself, or Bun with the script in development. */
function helperCommand(): [string, string[]] {
  return Bun.main.includes("$bunfs") ? [process.execPath, []] : [process.execPath, [Bun.main]];
}

/**
 * Opens a preview session in the workspace's service, starting the service when none answers.
 * One service per workspace, runtime, JDK and Komodo launcher: its state file names its port.
 */
export async function open(args: OpenArgs, stdin: string): Promise<{ url: string; root: string }> {
  const { source, root } = await resolveSource(args.file, args.root);
  const runtime = await executable(args.runtime, "Elide");
  const java = args.java ? await executable(args.java, "Java") : undefined;
  const komodo = args.komodo ? path.resolve(args.komodo) : undefined;
  const keepAlive = args["keep-alive"] === undefined ? 10 : Number(args["keep-alive"]);
  if (!Number.isFinite(keepAlive) || keepAlive < 0) throw new Error("--keep-alive must be a nonnegative number of minutes.");
  const documents = stdin.trim() ? editorDocuments(JSON.parse(stdin)) : [];
  const cache = path.resolve(args.cache);
  const services = path.join(cache, "compose-service");
  await mkdir(services, { recursive: true, mode: 0o700 });
  const id = createHash("sha256").update([root, runtime, java ?? "", komodo ?? ""].join("\0")).digest("hex").slice(0, 32);
  const state = path.join(services, `${id}.json`);
  const log = path.join(services, `${id}.log`);
  const deadline = Date.now() + 15_000;
  let spawnedAt = -Infinity;
  while (Date.now() < deadline) {
    const record = await readRecord(state);
    let answered = false;
    if (record === "invalid") {
      // A service writes its record right after creating it; one still unreadable later is left from a crash.
      const info = await stat(state).catch(() => undefined);
      if (info && Date.now() - info.mtimeMs > 2000) await rm(state, { force: true });
      else answered = true;
    } else if (record) {
      let response: Response | undefined;
      try {
        response = await fetch(`http://127.0.0.1:${record.port}/${record.control}/open`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ file: source, documents, keepAlive }),
          signal: AbortSignal.timeout(5000),
        });
      } catch {
        if (!running(record.pid)) await rm(state, { force: true });
      }
      if (response) {
        answered = true;
        const body = await response.json().catch(() => ({})) as { url?: unknown; root?: unknown; error?: unknown };
        if (response.ok && typeof body.url === "string" && typeof body.root === "string") return { url: body.url, root: body.root };
        if (response.status >= 400 && response.status < 500) throw new Error(typeof body.error === "string" ? body.error : `The preview service refused the request (${response.status}).`);
      }
    }
    if (!answered && Date.now() - spawnedAt > 2000) {
      spawnedAt = Date.now();
      const [command, prefix] = helperCommand();
      const output = openSync(log, "w", 0o600);
      try {
        spawn(command, [...prefix, "serve", "--runtime", runtime, "--root", root, "--cache", cache, "--state", state,
          ...java ? ["--java", java] : [], ...komodo ? ["--komodo", komodo] : []],
        { cwd: root, detached: true, stdio: ["ignore", "ignore", output] }).unref();
      } finally {
        closeSync(output);
      }
    }
    await delay(25);
  }
  throw new Error(`The Compose preview service did not answer within 15 s. Its log: ${log}`);
}

/** The per-workspace preview service: one Komodo stack, one page session at a time, kept warm between sessions. */
class PreviewService {
  private readonly controller = new AbortController();
  private readonly signal = this.controller.signal;
  private readonly server: PreviewServer;
  private readonly cli: ElideCli;
  private readonly changes: PreviewChanges;
  private readonly composeRuntime: Promise<ComposeRuntime>;
  private readonly helpers: Promise<string>;
  private models: Promise<ProjectModel[]>;
  private stack: Stack | undefined;
  private readonly logLines: string[] = [];
  private shuttingDown = false;
  /** A session was opened: a service nobody opened within 30 s exits. */
  opened = false;
  // The session: the page's file and its gallery.
  private session = false;
  private source = "";
  private revision = 0;
  private imageRevision = -1;
  private images: PreviewImage[] = [];
  private paintedIn = 0;
  private detectedAt = 0;
  private selected = "";
  private verifying = false;
  private compileFailure: string | undefined;
  // Refresh scheduling.
  private rebuild = true;
  private remodel = false;
  private pending = false;
  private building = false;
  private timer: NodeJS.Timeout | undefined;
  private stopBuild: AbortController | undefined;
  // Editor texts over the files, by origin (host: Elide editors, native: Tern's editors), and the texts handed to the backend.
  private readonly overlays = { host: new Map<string, string>(), native: new Map<string, string>() };
  private readonly documentErrors: { host?: string; native?: string } = {};
  private readonly supplied = new Map<string, string>();
  private queue: Promise<void> = Promise.resolve();
  private nativeArrived: (() => void) | undefined;
  // Lifetime.
  private keepAliveMs = 10 * 60_000;
  private keepAliveTimer: NodeJS.Timeout | undefined;

  constructor(
    private readonly root: string,
    private readonly runtime: string,
    private readonly java: string | undefined,
    private readonly komodo: string | undefined,
    private readonly cache: string,
    private readonly state: string,
  ) {
    this.server = createPreviewServer({
      signal: this.signal,
      info: () => ({ root: this.root, file: this.source }),
      open: (request) => this.open(request),
      documents: (post) => this.enqueue(() => this.applyDocuments(post, true)),
      retarget: (file) => this.retarget(file),
      refresh: () => this.schedule(true),
      stop: () => { setTimeout(() => void this.shutdown(), 0); },
      ended: (reason) => this.ended(reason),
      input: () => this.session && this.imageRevision === this.revision ? this.stack?.backend : undefined,
    });
    this.cli = new ElideCli({ bin: runtime, home: path.dirname(path.dirname(runtime)) }, root);
    this.models = this.resolveModels();
    this.composeRuntime = ensureComposeRuntime(cache, this.signal, (text) => { if (this.imageRevision !== this.revision) this.status("runtime", text); });
    this.composeRuntime.catch(() => {});
    this.helpers = extractHelpers(cache, this.signal);
    this.helpers.catch(() => {});
    let models: ProjectModel[] = [];
    this.models.then((value) => { models = value; }, () => {});
    this.changes = new PreviewChanges(root, this.signal, (file) =>
      /\.(kt|java|xml|pkl)$/.test(file) || models.some((model) =>
        model.modules.some((module) => module.contentRoots.some((content) =>
          content.sourceRoots.some((input) => input.kind === "resource" && under(input.path, file))))),
    (files) => this.enqueue(() => this.changed(files)),
    (error) => this.log(`File watcher failed: ${message(error)}`));
  }

  get port(): number { return this.server.port; }
  get control(): string { return this.server.control; }

  private log(line: string): void {
    this.logLines.push(line);
    if (this.logLines.length > LOG_LINES) this.logLines.splice(0, this.logLines.length - LOG_LINES);
    process.stderr.write(`${line}\n`);
  }

  private status(phase: string, text: string): void {
    this.server.status(phase, text);
  }

  /** Document posts and file events apply one at a time, in arrival order. */
  private enqueue(task: () => Promise<void>): Promise<void> {
    const next = this.queue.then(task);
    this.queue = next.catch((error: unknown) => this.log(`Preview input update failed: ${message(error)}`));
    return next;
  }

  private resolveModels(): Promise<ProjectModel[]> {
    const signal = this.signal;
    const models = (async () => buildProjectModels(this.cli, await this.cli.manifest({ signal, onCommand: this.onCommand("resolving") }), {
      signal, onCommand: this.onCommand("resolving"),
      onProgress: (text) => { if (this.imageRevision !== this.revision) this.status("resolving", text); },
      jdk: {
        ...(this.java ? { override: path.dirname(path.dirname(this.java)) } : {}),
        javaVersionOutput: async (home) => {
          try {
            const result = await run(path.join(home, "bin", process.platform === "win32" ? "java.exe" : "java"), ["-version"], { signal, timeout: 15_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024 });
            return `${result.stdout}${result.stderr}`;
          } catch { signal.throwIfAborted(); return undefined; }
        },
      },
    }))();
    // A failure resolves again on the next refresh.
    models.catch(() => { this.remodel = true; });
    return models;
  }

  /** Output lines of a CLI command: the log, and the status line while nothing of this revision is shown. */
  private onCommand(phase: string) {
    return () => ({
      line: (text: string) => {
        this.log(text);
        if (this.session && this.imageRevision !== this.revision) this.status(phase, text.slice(-1800));
      },
      end() {},
    });
  }

  private async javaFor(model: ProjectModel): Promise<string> {
    const java = this.java ?? (model.jdk ? await executable(path.join(model.jdk.home, "bin", process.platform === "win32" ? "java.exe" : "java"), "Model JDK Java") : undefined);
    if (!java) throw new Error(`No JDK was resolved for ${model.name}. Configure the project's Java home or compose_java with a JDK 17+ java executable.`);
    return java;
  }

  // Sessions ------------------------------------------------------------------------------------

  private async open(request: { file: string; documents: EditorDocument[]; keepAlive?: number }): Promise<{ url: string; root: string }> {
    if (this.shuttingDown) throw new Error("The preview service is stopping.");
    const { source, root } = await resolveSource(request.file, this.root);
    if (root !== this.root) throw new Error("The source belongs to another Elide workspace.");
    if (request.keepAlive !== undefined) {
      if (!Number.isFinite(request.keepAlive) || request.keepAlive < 0) throw new Error("Invalid keep-alive period.");
      this.keepAliveMs = request.keepAlive * 60_000;
    }
    clearTimeout(this.keepAliveTimer);
    this.keepAliveTimer = undefined;
    // Native drafts belong to the window that posts them for this session; its first post replaces them.
    await this.enqueue(async () => {
      await this.applyDocuments({ origin: "native", replace: true, documents: [] }, false);
      await this.applyDocuments({ origin: "host", replace: true, documents: request.documents }, false);
      // Saved files changed while no page was open.
      for (const [file, text] of this.supplied) {
        if (this.overlay(file) !== undefined) continue;
        const disk = await diskText(file);
        if (disk === undefined) this.supplied.delete(file);
        else if (disk !== text) { this.supplied.set(file, disk); this.stack?.backend.edit(file, disk); }
      }
    });
    const url = this.server.begin({ name: path.basename(source), path: path.relative(this.root, source) });
    this.session = true;
    this.opened = true;
    this.source = source;
    this.imageRevision = -1;
    this.images = [];
    this.rebuild = true;
    this.revision++;
    const revision = this.revision;
    const { promise: native, resolve } = Promise.withResolvers<void>();
    this.nativeArrived = resolve;
    void Promise.race([native, delay(250)]).then(() => {
      if (this.session && this.revision === revision) this.schedule(true);
    });
    return { url, root: this.root };
  }

  private async retarget(file: string): Promise<void> {
    if (!this.session) throw new Error("No preview is open.");
    const { source, root } = await resolveSource(file, this.root);
    if (root !== this.root) throw new Error("The source belongs to another Elide workspace.");
    if (source === this.source || !this.session) return;
    this.source = source;
    this.server.file({ name: path.basename(source), path: path.relative(this.root, source) });
    this.server.pane("retarget", source);
    this.images = [];
    this.imageRevision = -1;
    this.server.show([], () => false);
    this.schedule(true);
  }

  private ended(reason: EndReason): void {
    this.session = false;
    this.stopBuild?.abort();
    clearTimeout(this.timer);
    this.timer = undefined;
    this.pending = false;
    this.revision++;
    this.nativeArrived = undefined;
    // `retargeted`: another session begins at once.
    if (reason === "retargeted" || reason === "stopped" || this.shuttingDown) return;
    this.log(`Preview session ended (${reason}).`);
    clearTimeout(this.keepAliveTimer);
    if (this.keepAliveMs <= 0) void this.shutdown();
    else this.keepAliveTimer = setTimeout(() => void this.shutdown(), this.keepAliveMs);
  }

  async shutdown(): Promise<void> {
    if (this.shuttingDown) return;
    this.shuttingDown = true;
    clearTimeout(this.keepAliveTimer);
    try {
      const record = await readRecord(this.state).catch(() => undefined);
      if (record && record !== "invalid" && record.pid === process.pid) await rm(this.state, { force: true });
      this.server.end("stopped");
      this.changes.dispose();
      await this.stack?.dispose().catch((error: unknown) => this.log(`Komodo cleanup failed: ${message(error)}`));
      this.controller.abort(new Error("Compose preview service stopped."));
      await this.server.dispose();
    } finally {
      process.exit(0);
    }
  }

  // Editor documents and file events ------------------------------------------------------------

  /** The editor text of `file`: Tern's native editor over an Elide editor's. */
  private overlay(file: string): string | undefined {
    return this.overlays.native.get(file) ?? this.overlays.host.get(file);
  }

  private merged(): Map<string, string> {
    return new Map([...this.overlays.host, ...this.overlays.native]);
  }

  /** The texts a preview compiles: editor texts, saved texts handed to the backend before, and the previewed file. */
  private requestDocuments(sourceText: string): Map<string, string> {
    const documents = new Map(this.supplied);
    for (const [file, text] of this.merged()) documents.set(file, text);
    documents.set(this.source, sourceText);
    return documents;
  }

  private async applyDocuments(post: DocumentsPost, live: boolean): Promise<void> {
    if (post.origin === "native") { this.nativeArrived?.(); this.nativeArrived = undefined; }
    if (post.error !== undefined) {
      this.documentErrors[post.origin] = post.error;
      if (live && this.session) this.suspend(post.error, "error");
      return;
    }
    const entries: { file: string; text: string | null }[] = [];
    for (const entry of post.documents) {
      if (!path.isAbsolute(entry.file) || !/\.(kt|java)$/.test(entry.file) || (entry.text !== null && Buffer.byteLength(entry.text) > MAX_SOURCE)) {
        throw new Error("Invalid Kotlin/Java editor preview document.");
      }
      const file = await realpath(entry.file).catch((error: NodeJS.ErrnoException) => {
        if (error.code === "ENOENT") return undefined;
        throw error;
      });
      // A draft of a deleted file has nothing to overlay; its removal still names the path it was stored under.
      if (!file) { if (entry.text === null) entries.push({ file: entry.file, text: null }); continue; }
      if (!under(this.root, file)) throw new Error("Editor preview document resolves outside the workspace.");
      entries.push({ file, text: entry.text });
    }
    const origin = this.overlays[post.origin];
    const next = new Map(post.replace ? [] : origin);
    for (const { file, text } of entries) {
      if (text === null) next.delete(file);
      else next.set(file, text);
    }
    let total = 0;
    for (const text of next.values()) total += Buffer.byteLength(text);
    if (total > MAX_DOCUMENTS) throw new Error("Editor preview documents exceed 32 MiB.");
    const changed = new Set<string>();
    for (const [file, text] of next) if (origin.get(file) !== text) changed.add(file);
    for (const file of origin.keys()) if (!next.has(file)) changed.add(file);
    const before = new Map([...changed].map((file) => [file, this.overlay(file)]));
    origin.clear();
    for (const [file, text] of next) origin.set(file, text);
    const recovered = this.documentErrors[post.origin] !== undefined;
    this.documentErrors[post.origin] = undefined;
    let refresh = recovered;
    for (const file of changed) {
      const text = this.overlay(file);
      if (text === before.get(file)) continue;
      const backend = this.stack?.backend;
      if (text !== undefined) {
        if (live && this.session && backend?.compiler && !backend.compiles(file)) {
          this.suspend(`Save ${path.basename(file)} to rebuild the preview's source inputs.`);
          return;
        }
        backend?.edit(file, text);
        this.supplied.set(file, text);
      } else {
        const disk = await diskText(file);
        if (disk === undefined) { this.supplied.delete(file); continue; }
        backend?.edit(file, disk);
        this.supplied.set(file, disk);
      }
      refresh = true;
    }
    if (live && refresh && this.session) this.schedule(false);
  }

  private async changed(files: ReadonlySet<string>): Promise<void> {
    let rebuild = false;
    let refresh = false;
    for (const file of files) {
      if (file === this.root || file.endsWith(".pkl")) { this.remodel = true; rebuild = true; continue; }
      if (!this.session) continue;
      const backend = this.stack?.backend;
      const disk = /\.(kt|java)$/.test(file) ? await diskText(file) : undefined;
      if (disk === undefined || !backend?.compiles(file)) { rebuild = true; continue; }
      if (this.overlay(file) !== undefined || this.supplied.get(file) === disk) continue;
      this.supplied.set(file, disk);
      backend.edit(file, disk);
      if (file === this.source) refresh = true;
      else rebuild = true;
    }
    if (!this.session) return;
    if (rebuild) this.schedule(true);
    else if (refresh) this.schedule(false);
  }

  // Refresh --------------------------------------------------------------------------------------

  private schedule(rebuild: boolean): void {
    if (!this.session) return;
    // A rebuild supersedes the running build: stop it rather than wait for output nothing uses.
    if (rebuild) this.stopBuild?.abort();
    this.revision++;
    this.detectedAt = performance.now();
    this.rebuild ||= rebuild;
    this.pending = true;
    this.compileFailure = undefined;
    this.server.invalidate();
    this.status(this.stack?.backend.compiler?.ready && !this.rebuild ? "refreshing" : "building", "");
    clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.refresh(), 0);
  }

  /** Show no gallery for the current revision and refresh nothing until the next change: `text` says what has to happen. */
  private suspend(text: string, phase = "refreshing"): void {
    this.stopBuild?.abort();
    this.revision++;
    this.pending = false;
    clearTimeout(this.timer);
    this.server.invalidate();
    this.status(phase, text);
  }

  private async build(model: ProjectModel, target: AndroidTargetModel, models: ProjectModel[]): Promise<void> {
    const stop = new AbortController();
    this.stopBuild = stop;
    try {
      await this.cli.build(composePreviewBuildTargets(model, target, models), { signal: AbortSignal.any([this.signal, stop.signal]), onCommand: this.onCommand("building") });
    } finally {
      if (this.stopBuild === stop) this.stopBuild = undefined;
    }
  }

  private async refresh(): Promise<void> {
    if (!this.session || this.building) return;
    this.building = true;
    this.pending = false;
    const revision = this.revision;
    let preparing = false;
    let backend: Stack["backend"] | undefined;
    try {
      if (this.remodel) {
        this.status("resolving", "Updating preview project inputs…");
        await this.stack?.dispose();
        this.stack = undefined;
        this.models = this.resolveModels();
        this.remodel = false;
        this.rebuild = true;
      }
      const models = await this.models;
      if (revision !== this.revision) return;
      const application = composePreviewApplications(this.source, models)[0];
      if (!application) throw new Error(NO_APPLICATION);
      const { model, target } = application;
      this.selected = `${model.name}:${target.name}`;
      const key = `${model.root}\0${target.name}`;
      const java = await this.javaFor(model);
      const needsBuild = this.rebuild || !this.stack?.backend.compiler || this.stack.key !== key;
      let buildFailed = false;
      // The build starts now, beside the language server's start and session.
      const built = needsBuild ? this.build(model, target, models).catch((error: unknown) => { buildFailed = true; throw error; }) : undefined;
      built?.catch(() => {});
      try {
        if (!this.stack || this.stack.java !== java) {
          await this.stack?.dispose();
          this.stack = undefined;
          this.status("runtime", "Starting the Komodo language server…");
          this.stack = await createStack({
            runtime: this.runtime, root: this.root, models, java, launcher: this.komodo, cache: this.cache,
            helpers: await this.helpers, key, signal: this.signal, log: (line) => this.log(line),
            overlays: () => this.merged(),
            clockActive: () => this.server.connected,
            onImages: (images) => this.pushImages(images),
            onCompile: (outcome) => this.compiled(outcome.failed, outcome.messages),
            onInputReset: () => this.server.reset(),
            onSessionLost: () => this.schedule(false),
            onUnavailable: (reason) => this.status("error", reason),
          });
        } else if (this.stack.key !== key) this.stack.replaceBackend(key);
        backend = this.stack.backend;
        await backend.prepareSession(this.source, false, this.signal);
      } catch (error) {
        this.stopBuild?.abort();
        throw error;
      }
      const text = this.overlay(this.source) ?? (await sourceBytes(this.source)).toString("utf8");
      const request: PreviewRequest = { sourceFile: this.source, packageName: packageName(text), documents: this.requestDocuments(text) };
      let gallery: PreviewGallery | undefined;
      if (needsBuild) {
        preparing = true;
        this.rebuild = false;
        const build = { model, artifact: target, models, bin: this.runtime };
        await backend.startRenderer(await this.composeRuntime);
        const live = backend;
        // While Elide confirms the build, paint from a warm compiler or the last build's classes.
        const provisional = (async () => {
          if (!live.compiler) await live.configure(build, request.documents, false);
          const early = await live.preview(request, false);
          return early && !buildFailed && this.show(early, revision, true) ? early : undefined;
        })().catch(() => undefined);
        await built;
        const shown = await provisional;
        const changed = await backend.configure(build, request.documents, true);
        // New build classes hold the saved texts: only editor texts still differ from them.
        if (changed) for (const file of [...this.supplied.keys()]) if (this.overlay(file) === undefined) this.supplied.delete(file);
        preparing = false;
        if (revision !== this.revision) return;
        if (shown && !changed) gallery = shown;
      }
      if (revision !== this.revision) return;
      if (!gallery) {
        gallery = await backend.preview(request, true);
        if (!this.show(gallery, revision, false)) return;
      }
      this.confirm(revision);
    } catch (error) {
      if (backend && !backend.disposed) backend.preempt("The preview did not complete; refresh to try again.");
      if (preparing) this.rebuild = true;
      if (this.session && revision === this.revision) this.fail(error);
    } finally {
      this.building = false;
      if (this.session && this.pending) void this.refresh();
    }
  }

  /** Publish `gallery` for `revision` unless a newer change superseded it. */
  private show(gallery: PreviewGallery, revision: number, verifying: boolean): boolean {
    const backend = this.stack?.backend;
    if (!this.session || revision !== this.revision || !backend) return false;
    if (!gallery.images.length) throw new Error("No compiled @Preview functions found in this file.");
    // A failing card keeps its last good pixels; the others update.
    const previous = new Map(this.images.map((image) => [image.id, image]));
    this.images = backend.latestImages(gallery.images).map((image) => {
      const retained = image.error ? previous.get(image.id) : undefined;
      return retained?.data ? { ...image, data: retained.data, width: retained.width, height: retained.height } : image;
    });
    this.verifying = verifying;
    this.imageRevision = revision;
    this.paintedIn = Math.round(performance.now() - this.detectedAt);
    this.server.show(this.images, (id) => backend.keyboardSupported(id));
    this.report();
    return true;
  }

  private confirm(revision: number): void {
    if (!this.session || revision !== this.revision) return;
    this.verifying = false;
    this.report();
  }

  private report(): void {
    if (!this.session || this.imageRevision !== this.revision) return;
    if (this.compileFailure) {
      this.status("error", this.compileFailure);
      return;
    }
    const failed = this.images.filter((image) => image.error).length;
    const count = this.images.length;
    this.status("live", `${count} live preview${count === 1 ? "" : "s"} · ${this.selected} · ${this.paintedIn} ms`
      + `${failed ? ` · ${failed} failed card${failed === 1 ? "" : "s"}` : ""}${this.verifying ? " · verifying build…" : ""}`);
  }

  /** Cards a live session updated after their gallery was shown, replaced in place. */
  private pushImages(updates: PreviewImage[]): void {
    const backend = this.stack?.backend;
    if (!this.session || this.imageRevision !== this.revision || !backend) return;
    const updated = new Map(updates.map((image) => [image.id, image]));
    this.images = this.images.map((image) => updated.get(image.id) ?? image);
    this.server.push(updates.filter((image) => this.images.some((shown) => shown.id === image.id)), (id) => backend.keyboardSupported(id));
  }

  private compiled(failed: boolean, messages: CompileMessage[]): void {
    const lines = messages.map((entry) => {
      const at = entry.file ? `${entry.file}${entry.line === undefined ? "" : `:${entry.line}${entry.column === undefined ? "" : `:${entry.column}`}`}: ` : "";
      return `${at}${entry.level}: ${entry.text}`;
    });
    for (const line of lines) this.log(line);
    const first = messages.find((entry) => entry.level === "error") ?? messages[0];
    this.compileFailure = failed ? `Live preview does not compile: ${first?.text ?? "see the output"}\n${lines.join("\n")}` : undefined;
    this.report();
  }

  private fail(error: unknown): void {
    const text = message(error);
    this.log(text);
    this.verifying = false;
    const output = this.logLines.join("\n").slice(-8192);
    this.status("error", output && output !== text ? `${text}\n\n${output}` : text);
  }
}

/** Runs the workspace's preview service until it is stopped or its keep-alive period ends. */
export async function serve(args: ServeArgs): Promise<void> {
  const root = await realpath(path.resolve(args.root));
  if (!(await stat(root)).isDirectory()) throw new Error("The workspace root is not a directory.");
  const runtime = await executable(args.runtime, "Elide");
  const java = args.java ? await executable(args.java, "Java") : undefined;
  const komodo = args.komodo ? path.resolve(args.komodo) : undefined;
  const cache = path.resolve(args.cache);
  await mkdir(cache, { recursive: true });
  const state = path.resolve(args.state);
  const service = new PreviewService(root, runtime, java, komodo, cache, state);
  const record = JSON.stringify({ pid: process.pid, port: service.port, control: service.control });
  for (let attempt = 0; ; attempt++) {
    try {
      await writeFile(state, record, { flag: "wx", mode: 0o600 });
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST" || attempt) throw error;
      const owner = await readRecord(state);
      if (owner && owner !== "invalid" && owner.pid !== process.pid && running(owner.pid)) {
        const ping = await fetch(`http://127.0.0.1:${owner.port}/${owner.control}/ping`, { signal: AbortSignal.timeout(2000) }).catch(() => undefined);
        if (ping?.ok) {
          process.stderr.write("Another preview service serves this workspace.\n");
          process.exit(0);
        }
      }
      await rm(state, { force: true });
    }
  }
  process.on("SIGINT", () => void service.shutdown());
  process.on("SIGTERM", () => void service.shutdown());
  // Started for an `open` that never arrived (it timed out or its client was killed).
  setTimeout(() => { if (!service.opened) void service.shutdown(); }, 30_000);
  process.stderr.write(`Compose preview service for ${root} on 127.0.0.1:${service.port}\n`);
}
