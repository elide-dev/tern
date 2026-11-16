import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtemp, open, readdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { writeKomodoProject, type ProjectModel } from "@elide/ide-core";
import type { CompiledPreview } from "@elide/compose-render";
import { resolveKomodo } from "@elide/komodo-distribution";

const MAX_HEADER = 8 * 1024;
const MAX_MESSAGE = 16 * 1024 * 1024;
const MAX_SOURCE = 8 * 1024 * 1024;
const REQUEST_TIMEOUT = 30_000;

type Json = Record<string, unknown>;
const object = (value: unknown): value is Json => value !== null && typeof value === "object" && !Array.isArray(value);

export class KomodoError extends Error {
  constructor(message: string, readonly code: string | number, readonly method?: string, readonly data?: unknown) {
    super(message);
    this.name = "KomodoError";
  }
}

export interface KomodoClient {
  previews(file: string): Promise<{ previews: CompiledPreview[]; errors: { message: string }[] }>;
  session(file: string): Promise<{ protocol: number; port: number; token: string; pid?: number }>;
  sync(files: readonly string[]): Promise<void>;
  dispose(): Promise<void>;
}

export interface KomodoOptions {
  runtime: string;
  root: string;
  models: readonly ProjectModel[];
  java: string;
  signal: AbortSignal;
  log: (line: string) => void;
  launcher?: string;
  getDocuments: () => ReadonlyMap<string, string>;
}

type Pending = { resolve: (value: unknown) => void; reject: (error: unknown) => void; timer: NodeJS.Timeout; method: string };

/** One owned stdio JSON-RPC connection; malformed framing and transport failures are terminal. */
class Connection {
  private readonly pending = new Map<number, Pending>();
  private nextId = 0;
  private buffer: Buffer = Buffer.alloc(0);
  private bodyLength: number | undefined;
  private failure: Error | undefined;
  private closing = false;
  private stopped: Promise<void> | undefined;
  private readonly exited: Promise<void>;
  private stderr = "";

  constructor(private readonly child: ChildProcessWithoutNullStreams, private readonly log: (line: string) => void) {
    const exited = Promise.withResolvers<void>();
    this.exited = exited.promise;
    child.once("exit", (code, signal) => {
      this.fail(new KomodoError(`Komodo exited (${signal ?? code}).`, "exit"));
      exited.resolve();
    });
    child.once("error", (error) => { this.fail(error); exited.resolve(); });
    child.stdin.on("error", (error) => this.fail(error));
    child.stdout.on("error", (error) => this.fail(error));
    child.stdout.on("end", () => this.fail(new KomodoError("Komodo closed its protocol stream.", "transport")));
    child.stdout.on("data", (chunk: Buffer) => this.receive(chunk));
    child.stderr.setEncoding("utf8");
    child.stderr.on("error", (error) => this.fail(error));
    child.stderr.on("data", (chunk: string) => {
      this.stderr += chunk;
      let end: number;
      while ((end = this.stderr.indexOf("\n")) >= 0) {
        this.log(this.stderr.slice(0, end).slice(0, MAX_HEADER));
        this.stderr = this.stderr.slice(end + 1);
      }
      if (this.stderr.length > MAX_HEADER) { this.log(this.stderr.slice(0, MAX_HEADER)); this.stderr = ""; }
    });
  }

  private fail(error: Error): void {
    if (this.failure) return;
    this.failure = error;
    this.buffer = Buffer.alloc(0);
    for (const entry of this.pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
    this.pending.clear();
    if (!this.closing) void this.dispose();
  }

  private send(message: Json): void {
    if (this.failure) throw this.failure;
    const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", ...message }));
    if (body.length > MAX_MESSAGE || this.child.stdin.writableLength + body.length > MAX_MESSAGE * 2) {
      throw new KomodoError("Komodo protocol write exceeds the bounded message queue.", "limit");
    }
    this.child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.child.stdin.write(body);
  }

  notify(method: string, params?: unknown): void {
    this.send({ method, ...(params === undefined ? {} : { params }) });
  }

  request(method: string, params?: unknown, timeout = REQUEST_TIMEOUT, shutdown = false): Promise<unknown> {
    if (this.failure) return Promise.reject(this.failure);
    if (this.closing && !shutdown) return Promise.reject(new KomodoError("Komodo is disposed.", "disposed", method));
    if (this.pending.size >= 64) return Promise.reject(new KomodoError("Too many pending Komodo requests.", "limit", method));
    const id = ++this.nextId;
    const { promise, resolve, reject } = Promise.withResolvers<unknown>();
    const timer = setTimeout(() => {
      this.pending.delete(id);
      reject(new KomodoError(`Komodo ${method} timed out after ${timeout / 1000} seconds.`, "timeout", method));
      try { this.notify("$/cancelRequest", { id }); } catch { /* The transport may already be closed. */ }
    }, timeout);
    this.pending.set(id, { resolve, reject, timer, method });
    try { this.send({ id, method, ...(params === undefined ? {} : { params }) }); }
    catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    return promise;
  }

  private receive(chunk: Buffer): void {
    if (this.failure) return;
    try {
      if (this.buffer.length + chunk.length > MAX_MESSAGE + MAX_HEADER) throw new KomodoError("Komodo exceeded the protocol input limit.", "limit");
      this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
      while (this.buffer.length) {
        if (this.bodyLength === undefined) {
          const end = this.buffer.indexOf("\r\n\r\n");
          if (end < 0) {
            if (this.buffer.length > MAX_HEADER) throw new KomodoError("Komodo sent an oversized LSP header.", "protocol");
            return;
          }
          if (end > MAX_HEADER) throw new KomodoError("Komodo sent an oversized LSP header.", "protocol");
          const lengths = this.buffer.subarray(0, end).toString("ascii").split("\r\n").filter((line) => /^Content-Length:/i.test(line));
          if (lengths.length !== 1 || !/^Content-Length:\s*\d+\s*$/i.test(lengths[0]!)) throw new KomodoError("Komodo sent an invalid Content-Length header.", "protocol");
          const length = Number(lengths[0]!.slice(lengths[0]!.indexOf(":") + 1).trim());
          if (!Number.isSafeInteger(length) || length < 1 || length > MAX_MESSAGE) throw new KomodoError("Komodo sent an invalid LSP message length.", "protocol");
          this.bodyLength = length;
          this.buffer = this.buffer.subarray(end + 4);
        }
        if (this.buffer.length < this.bodyLength) return;
        const value: unknown = JSON.parse(this.buffer.subarray(0, this.bodyLength).toString("utf8"));
        this.buffer = this.buffer.subarray(this.bodyLength);
        this.bodyLength = undefined;
        this.dispatch(value);
        if (this.failure) return;
      }
    } catch (error) { this.fail(error instanceof Error ? error : new KomodoError(String(error), "protocol")); }
  }

  private dispatch(value: unknown): void {
    if (!object(value) || value.jsonrpc !== "2.0") throw new KomodoError("Komodo sent an invalid JSON-RPC message.", "protocol");
    if (typeof value.method === "string") {
      if (typeof value.id === "number" || typeof value.id === "string") {
        // No editor capabilities are advertised, so server-initiated editor requests are unsupported.
        this.send({ id: value.id, error: { code: -32601, message: `Unsupported client method: ${value.method}` } });
      } else if (value.method === "textDocument/publishDiagnostics" && object(value.params) && Array.isArray(value.params.diagnostics)) {
        for (const diagnostic of value.params.diagnostics) {
          if (!object(diagnostic)) continue;
          const code = object(diagnostic.code) ? diagnostic.code.value : diagnostic.code;
          if (code === "komodo.project") throw new KomodoError(`Komodo could not load the project: ${diagnostic.message}`, "project", value.method, diagnostic);
        }
      } else if ((value.method === "window/logMessage" || value.method === "window/showMessage") && object(value.params) && typeof value.params.message === "string") {
        this.log(value.params.message.slice(0, MAX_HEADER));
      }
      return;
    }
    if (typeof value.id !== "number") throw new KomodoError("Komodo response has no numeric request ID.", "protocol");
    const pending = this.pending.get(value.id);
    if (!pending) return; // A cancelled request may still finish on the server.
    if (!("result" in value) && !object(value.error)) throw new KomodoError("Komodo response has neither a result nor an error.", "protocol");
    this.pending.delete(value.id);
    clearTimeout(pending.timer);
    if (object(value.error)) {
      const code = typeof value.error.code === "number" ? value.error.code : "rpc";
      const message = code === -32601
        ? `Komodo requires preview protocol 2. Install a compatible version to use live previews.`
        : String(value.error.message ?? "Komodo request failed.");
      pending.reject(new KomodoError(message, code, pending.method, value.error.data));
    } else pending.resolve(value.result);
  }

  private kill(signal: NodeJS.Signals): void {
    if (!this.child.pid) return;
    try {
      if (process.platform !== "win32") process.kill(-this.child.pid, signal);
      else this.child.kill(signal);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ESRCH") this.log(`Komodo cleanup: ${String(error)}`);
    }
  }

  private async waitForExit(milliseconds: number): Promise<void> {
    const elapsed = Promise.withResolvers<void>();
    const timer = setTimeout(elapsed.resolve, milliseconds);
    try { await Promise.race([this.exited, elapsed.promise]); }
    finally { clearTimeout(timer); }
  }

  dispose(): Promise<void> {
    if (this.stopped) return this.stopped;
    this.closing = true;
    for (const entry of this.pending.values()) { clearTimeout(entry.timer); entry.reject(new KomodoError("Komodo is disposed.", "disposed", entry.method)); }
    this.pending.clear();
    this.stopped = (async () => {
      if (!this.failure) {
        try { await this.request("shutdown", undefined, 5_000, true); this.notify("exit"); }
        catch { /* Continue with process-group cleanup if graceful shutdown fails. */ }
      }
      this.child.stdin.end();
      await this.waitForExit(5_000);
      // The group includes renderer descendants, even if the language server has already exited.
      this.kill("SIGTERM");
      await delay(250);
      this.kill("SIGKILL");
      await this.waitForExit(1_000);
      this.child.stdout.destroy();
      this.child.stderr.destroy();
      this.child.stdin.destroy();
    })();
    return this.stopped;
  }
}

async function savedSource(file: string): Promise<string> {
  const handle = await open(file, "r");
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.size > MAX_SOURCE) throw new KomodoError(`Saved Kotlin source must be a regular file no larger than 8 MiB: ${file}`, "source");
    const bytes = Buffer.alloc(info.size + 1);
    const result = await handle.read(bytes, 0, bytes.length, 0);
    if (result.bytesRead !== info.size) throw new KomodoError(`Source changed while reading: ${file}. Save and refresh the preview.`, "source");
    return bytes.subarray(0, result.bytesRead).toString("utf8");
  } finally { await handle.close(); }
}

export async function createKomodo(options: KomodoOptions): Promise<KomodoClient> {
  const { signal, log } = options;
  signal.throwIfAborted();
  const resolved = await resolveKomodo(options.launcher, path.dirname(path.dirname(options.runtime)), { signal, onLine: (line: string) => log(line) });
  signal.throwIfAborted();
  if (resolved.protocol && (resolved.protocol.preview !== 2 || !resolved.capabilities?.includes("preview"))) {
    throw new KomodoError("The installed Komodo does not advertise preview protocol 2. Install compatible Komodo through Elide or supply an explicit compatible launcher.", "incompatible");
  }
  const directory = await mkdtemp(path.join(tmpdir(), "tern-komodo-"));
  let connection: Connection | undefined;
  let disposed: Promise<void> | undefined;
  const dispose = (): Promise<void> => disposed ??= (async () => {
    signal.removeEventListener("abort", abort);
    try { await connection?.dispose(); } finally { await rm(directory, { recursive: true, force: true }); }
  })();
  const abort = () => { void dispose().catch((error: unknown) => log(`Komodo cleanup: ${String(error)}`)); };
  try {
    const manifest = path.join(directory, "project.properties");
    const project = await writeKomodoProject(options.models, manifest);
    signal.throwIfAborted();
    if (!project) throw new KomodoError("The project has no Kotlin source roots for Komodo.", "project");
    for (const skipped of project.skipped) log(`Komodo: skipped ${skipped}`);
    const args = ["--project", manifest];
    if (resolved.pluginDirectory) {
      const jars = (await readdir(resolved.pluginDirectory)).filter((name) => name.endsWith(".jar") && !name.endsWith("-sources.jar")).sort();
      for (const [needed, id, base] of [
        [project.plugins.compose, "compose", "kotlin-compose-compiler-plugin"],
        [project.plugins.serialization, "kotlinx-serialization", "kotlin-serialization-compiler-plugin"],
      ] as const) {
        if (!needed) continue;
        const jar = jars.filter((name) => new RegExp(`^${base}(-embeddable)?(-\\d[^/]*)?\\.jar$`).test(name)).at(-1);
        if (!jar) throw new KomodoError(`Komodo is missing its ${id} compiler plugin in ${resolved.pluginDirectory}.`, "incompatible");
        args.push("--plugin", `${id}=${path.join(resolved.pluginDirectory, jar)}`);
      }
    }
    const javaHome = path.dirname(path.dirname(await realpath(options.java)));
    signal.throwIfAborted();
    log(`Komodo: starting ${resolved.executable} (JAVA_HOME=${javaHome})`);
    connection = new Connection(spawn(resolved.executable, args, {
      cwd: directory, env: { ...process.env, JAVA_HOME: javaHome }, stdio: ["pipe", "pipe", "pipe"], detached: process.platform !== "win32",
    }), log);
    const client = connection;
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) { abort(); signal.throwIfAborted(); }
    const rootUri = pathToFileURL(path.resolve(options.root)).href;
    const initialized = await client.request("initialize", {
      processId: process.pid, clientInfo: { name: "tern", version: "1" }, rootUri,
      capabilities: {}, workspaceFolders: [{ uri: rootUri, name: path.basename(options.root) }],
    });
    const capabilities = object(initialized) && object(initialized.capabilities) ? initialized.capabilities : undefined;
    const commands = capabilities && object(capabilities.executeCommandProvider) ? capabilities.executeCommandProvider.commands : undefined;
    if (!Array.isArray(commands) || !commands.includes("komodo.reload") || !capabilities?.definitionProvider || !capabilities.hoverProvider || !capabilities.completionProvider) {
      throw new KomodoError("Komodo's initialize response lacks native Kotlin analysis or project reload. Install a compatible Komodo.", "incompatible");
    }
    client.notify("initialized", {});
    await client.request("workspace/executeCommand", { command: "komodo.reload", arguments: [] });
    signal.throwIfAborted();
    let version = 0;
    let queue: Promise<unknown> = Promise.resolve();
    const enqueue = <T>(operation: () => Promise<T>): Promise<T> => {
      const next = queue.catch(() => undefined).then(() => {
        signal.throwIfAborted();
        if (disposed) throw new KomodoError("Komodo is disposed.", "disposed");
        return operation();
      });
      queue = next;
      return next;
    };
    const sync = async (files: readonly string[]): Promise<void> => {
      const documents: { uri: string; version: number; text: string }[] = [];
      const overlays = options.getDocuments();
      let bytes = 0;
      for (const file of new Set(files)) {
        signal.throwIfAborted();
        let text = overlays.get(file);
        if (text === undefined) {
          try { text = await savedSource(file); }
          catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
            const uri = pathToFileURL(path.resolve(file)).href;
            client.notify("textDocument/didClose", { textDocument: { uri } });
            client.notify("workspace/didChangeWatchedFiles", { changes: [{ uri, type: 3 }] });
            continue;
          }
        }
        bytes += Buffer.byteLength(text);
        if (bytes > MAX_MESSAGE / 2) throw new KomodoError("Sources exceed the Komodo synchronization limit of 8 MiB.", "limit");
        documents.push({ uri: pathToFileURL(path.resolve(file)).href, version: ++version, text });
      }
      signal.throwIfAborted();
      await client.request("komodo/preview/sync", { documents });
    };
    return {
      sync: (files) => enqueue(() => sync(files)),
      previews: (file) => enqueue(async () => {
        await sync([file]);
        const result = await client.request("komodo/previews", { textDocument: { uri: pathToFileURL(path.resolve(file)).href } });
        const strings = (value: unknown): value is Record<string, string> => object(value) && Object.values(value).every((item) => typeof item === "string");
        if (!object(result) || !Array.isArray(result.previews) || !Array.isArray(result.errors)
          || !result.previews.every((preview) => object(preview) && typeof preview.methodFQN === "string" && typeof preview.previewId === "string" && typeof preview.name === "string"
            && strings(preview.previewParams) && Array.isArray(preview.methodParams) && preview.methodParams.every(strings))
          || !result.errors.every((error) => object(error) && typeof error.message === "string")) {
          throw new KomodoError("Komodo returned invalid preview declarations.", "protocol", "komodo/previews");
        }
        return { previews: result.previews as CompiledPreview[], errors: result.errors as { message: string }[] };
      }),
      session: (file) => enqueue(async () => {
        const result = await client.request("komodo/preview/open", { textDocument: { uri: pathToFileURL(path.resolve(file)).href } });
        if (!object(result) || result.protocol !== 2 || typeof result.port !== "number" || !Number.isInteger(result.port) || result.port < 1 || result.port > 65535
          || typeof result.token !== "string" || !result.token || /[\r\n]/.test(result.token)
          || (result.pid !== undefined && (typeof result.pid !== "number" || !Number.isSafeInteger(result.pid) || result.pid < 1))) {
          throw new KomodoError("Komodo returned an invalid preview protocol 2 session. Install a compatible Komodo.", "incompatible", "komodo/preview/open");
        }
        return { protocol: 2, port: result.port, token: result.token, ...(typeof result.pid === "number" ? { pid: result.pid } : {}) };
      }),
      dispose,
    };
  } catch (error) {
    await dispose();
    signal.throwIfAborted();
    throw error;
  }
}
