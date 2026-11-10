import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, constants, existsSync, openSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { access, mkdir, mkdtemp, open, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { format, promisify } from "node:util";
import {
  ElideCli, MANIFEST_NAME, OUTPUT_DIR, buildProjectModels, composePreviewApplications,
  composePreviewBuildTargets, composePreviewInputs, findEnclosingWorkspace, whichExecutable,
} from "@elide/ide-core";
import { ComposeRenderer, type PreviewImage } from "@elide/compose-render";
import { ensureComposeRuntime } from "@elide/compose-runtime";
import helperSources from "@elide/compose-helpers";
import licenses from "@elide/compose-licenses";

const run = promisify(execFile);
const MAX_SOURCE = 8 * 1024 * 1024;
const MAX_PNG = 8 * 1024 * 1024;
const MAX_GALLERY = 32;
const MAX_GALLERY_BYTES = 32 * 1024 * 1024;
const MAX_LOG = 24 * 1024;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const USAGE = "Usage: elide-tern-compose --runtime <elide> --root <project/workspace> --file <saved.kt> --job <unique-directory> --cache <directory> [--java <java-executable>] [--lease <file>]\n       elide-tern-compose --help | --licenses\n";

type Args = { runtime: string; root: string; file: string; job: string; cache: string; java?: string; lease?: string };
type Card = { id: string; name: string; detail: string; file?: string; width?: number; height?: number; error?: string };
type Result = { phase: "ready" | "error" | "cancelled"; message: string; source: string; root: string; images: Card[] };

function parseArgs(argv: string[]): Args {
  const values: Record<string, string> = {};
  const names: Record<string, true> = { runtime: true, root: true, file: true, job: true, cache: true, java: true, lease: true };
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]?.slice(2);
    const value = argv[i + 1];
    if (!argv[i]?.startsWith("--") || !key || !Object.hasOwn(names, key) || key in values || !value || value.startsWith("--")) {
      throw new Error(`Invalid argument ${argv[i] ?? ""}.\n${USAGE}`);
    }
    values[key] = value;
  }
  for (const key of ["runtime", "root", "file", "job", "cache"]) {
    if (!values[key]) throw new Error(`Missing --${key}.\n${USAGE}`);
  }
  return values as Args;
}

function under(root: string, file: string): boolean {
  const relative = path.relative(root, file);
  return relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function digest(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

async function sourceBytes(file: string): Promise<Buffer> {
  const handle = await open(file, "r");
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

async function saveGallery(images: PreviewImage[], job: string, signal: AbortSignal): Promise<Card[]> {
  if (!images.length) throw new Error("No compiled @Preview configurations were found in this saved Kotlin file. Add a Compose @Preview (or multipreview annotation), save, and rebuild.");
  if (images.length > MAX_GALLERY) throw new Error(`This file expands to ${images.length} preview cards; the snapshot gallery supports at most ${MAX_GALLERY}. Reduce multipreview or @PreviewParameter expansion.`);
  const cards: Card[] = [];
  let total = 0;
  for (const [index, image] of images.entries()) {
    signal.throwIfAborted();
    const card: Card = { id: image.id.slice(0, 1024), name: image.name.slice(0, 512), detail: image.detail.slice(0, 2048) };
    if (image.error) card.error = image.error.slice(0, 8192);
    else if (!image.data) card.error = "The renderer returned no PNG for this preview.";
    else if (image.data.length > 4 * Math.ceil(MAX_PNG / 3)) card.error = "This PNG exceeds the 8 MiB snapshot limit.";
    else {
      const png = Buffer.from(image.data, "base64");
      if (png.length > MAX_PNG) card.error = "This PNG exceeds the 8 MiB snapshot limit.";
      else if (png.length < 33 || !png.subarray(0, 8).equals(PNG_SIGNATURE) || png.toString("ascii", 12, 16) !== "IHDR") {
        card.error = "The renderer returned an invalid PNG.";
      } else {
        const width = png.readUInt32BE(16);
        const height = png.readUInt32BE(20);
        if (!width || !height || width > 4096 || height > 4096) card.error = "This image exceeds Tern's snapshot dimension limit (4096 pixels per side).";
        else if (total + png.length > MAX_GALLERY_BYTES) card.error = "The gallery exceeds the 32 MiB snapshot limit.";
        else {
          const filename = `preview-${index + 1}.png`;
          const destination = path.join(job, filename);
          await writeFile(destination, png, { flag: "wx", mode: 0o600 });
          if (!under(job, await realpath(destination))) throw new Error("A preview PNG escaped its job directory.");
          total += png.length;
          Object.assign(card, { file: filename, width, height });
        }
      }
    }
    cards.push(card);
  }
  return cards;
}

async function main(argv: string[]): Promise<Result> {
  let source = "";
  let root = "";
  let job = "";
  let log = "";
  let selected = "";
  let phase = "resolving";
  let cancelled = false;
  let renderer: ComposeRenderer | undefined;
  let timer: NodeJS.Timeout | undefined;
  let release: (() => void) | undefined;
  const controller = new AbortController();
  const { signal } = controller;
  const stop = (reason: string): void => {
    cancelled = true;
    controller.abort(new Error(reason));
  };
  const terminate = (): void => stop("Compose snapshot cancelled by termination signal.");
  process.on("SIGINT", terminate);
  process.on("SIGTERM", terminate);
  let lastStatus = 0;
  const status = (nextPhase: string, text: string, force = true): void => {
    phase = nextPhase;
    if (!job || (!force && Date.now() - lastStatus < 250)) return;
    lastStatus = Date.now();
    try {
      const temporary = path.join(job, "status.json.tmp");
      writeFileSync(temporary, JSON.stringify({ phase, message: text.slice(0, 2048) }), { mode: 0o600 });
      renameSync(temporary, path.join(job, "status.json"));
    } catch (error) {
      controller.abort(new Error(`Cannot publish snapshot status: ${message(error)}`));
    }
  };
  const line = (text: string): void => {
    const bounded = text.slice(-MAX_LOG);
    log = `${log}${bounded}\n`.slice(-MAX_LOG);
    process.stderr.write(`${bounded}\n`);
    status(phase, `${selected ? `${selected}: ` : ""}${bounded.slice(-1800)}`, false);
  };
  try {
    const args = parseArgs(argv);
    source = path.resolve(args.file);
    root = path.resolve(args.root);
    if (!path.isAbsolute(args.file) || path.extname(args.file) !== ".kt") throw new Error("Open a saved .kt file using its absolute path; unsaved buffers and .kts scripts are not supported.");
    const suppliedRoot = await realpath(root);
    if (!(await stat(suppliedRoot)).isDirectory()) throw new Error("The project root is not a directory.");
    source = await realpath(source);
    if (!under(suppliedRoot, source)) throw new Error("The saved Kotlin file is outside the selected project/workspace root.");
    root = suppliedRoot;
    for (let workspace = findEnclosingWorkspace(root); workspace; workspace = findEnclosingWorkspace(root)) {
      root = await realpath(workspace.root);
    }
    if (!(await stat(path.join(root, MANIFEST_NAME))).isFile()) throw new Error(`No ${MANIFEST_NAME} found at ${root}. Open an Elide project or workspace.`);
    if (!under(root, source)) throw new Error("The source resolves outside its Elide workspace.");
    await mkdir(path.resolve(args.job), { recursive: true });
    job = await realpath(args.job);
    if (!(await stat(job)).isDirectory()) throw new Error("The snapshot job path is not a directory.");
    const cache = path.resolve(args.cache);
    await mkdir(cache, { recursive: true });
    const monitor = (): void => {
      if (signal.aborted) return;
      if (existsSync(path.join(job, "cancel"))) { stop("Compose snapshot cancelled."); return; }
      if (args.lease) {
        try {
          if (Date.now() - statSync(args.lease).mtimeMs > 15_000) stop("Compose snapshot cancelled: the preview pane's lease expired.");
        } catch { stop("Compose snapshot cancelled: the preview pane's lease is missing."); }
      }
    };
    monitor();
    timer = setInterval(monitor, 500);
    signal.throwIfAborted();
    status("resolving", "Reading saved Kotlin source and Elide workspace…");
    const before = await sourceBytes(source);
    const sourceDigest = digest(before);
    const packageDeclaration = packageName(before.toString("utf8"));
    const ensureCurrent = async (): Promise<void> => {
      signal.throwIfAborted();
      if (await realpath(args.file) !== source || digest(await sourceBytes(source)) !== sourceDigest) {
        throw new Error("The saved source changed during the snapshot. Rebuild to preview the current saved file.");
      }
    };
    const runtime = await executable(args.runtime, "Elide");
    const javaOverride = args.java ? await executable(args.java, "Java") : undefined;
    const lockDirectory = path.join(root, OUTPUT_DIR);
    await mkdir(lockDirectory, { recursive: true });
    if (!under(root, await realpath(lockDirectory))) throw new Error("The workspace build directory resolves outside the workspace.");
    const lockFile = path.join(lockDirectory, "elide-tern-compose.lock");
    let lock: number;
    try { lock = openSync(lockFile, "wx", 0o600); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      let owner: { pid?: unknown };
      try { owner = JSON.parse(readFileSync(lockFile, "utf8")); }
      catch { throw new Error(`Another helper is acquiring the workspace lock. Retry Rebuild; if this persists, inspect ${lockFile}.`); }
      if (!Number.isSafeInteger(owner.pid) || (owner.pid as number) <= 0) throw new Error(`The snapshot lock has no valid owner: ${lockFile}`);
      let alive = true;
      try { process.kill(owner.pid as number, 0); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ESRCH") alive = false;
        else if ((error as NodeJS.ErrnoException).code !== "EPERM") throw error;
      }
      if (alive) throw new Error(`Another Compose snapshot owns this workspace (PID ${owner.pid}). Wait for it to finish or cancel it, then rebuild.`);
      // A forcibly killed helper may leave a detached Elide build alive. Never infer
      // exclusive access merely from its owner's death, or reclaim another run's lock.
      throw new Error(`A forcibly terminated snapshot left a workspace lock. Confirm that its Elide/JVM build processes have stopped, then remove ${lockFile} and rebuild.`);
    }
    release = () => { rmSync(lockFile, { force: true }); };
    try { writeFileSync(lock, JSON.stringify({ pid: process.pid, job, source })); }
    finally { closeSync(lock); }
    signal.throwIfAborted();
    const cli = new ElideCli({ bin: runtime, home: path.dirname(path.dirname(runtime)) }, root);
    const onCommand = () => ({ line, end() {} });
    const models = await buildProjectModels(cli, await cli.manifest({ signal, onCommand }), {
      signal, onCommand,
      onProgress: (text) => status("resolving", text),
      jdk: {
        ...(javaOverride ? { override: path.dirname(path.dirname(javaOverride)) } : {}),
        javaVersionOutput: async (home) => {
          try {
            const result = await run(path.join(home, "bin", process.platform === "win32" ? "java.exe" : "java"), ["-version"], { signal, timeout: 15_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024 });
            return `${result.stdout}${result.stderr}`;
          } catch (error) { signal.throwIfAborted(); return undefined; }
        },
      },
    });
    signal.throwIfAborted();
    const application = composePreviewApplications(source, models)[0];
    if (!application) throw new Error("No Android APK consumes this saved file's production source set. Open a Kotlin source owned by an Android application or one of its workspace libraries; test-only and unowned sources cannot be previewed.");
    const { model, target } = application;
    selected = `${model.name}:${target.name}`;
    line(`Selected Android application ${selected} (${model.root}); building JVM and resources only, not an APK.`);
    const java = javaOverride ?? (model.jdk ? await executable(path.join(model.jdk.home, "bin", process.platform === "win32" ? "java.exe" : "java"), "Model JDK Java") : undefined);
    if (!java) throw new Error(`No JDK was resolved for ${model.name}. Configure the project's Java home or compose_java with a JDK 17+ java executable.`);
    status("building", `Building ${selected} JVM classes and Android resources…`);
    await cli.build(composePreviewBuildTargets(model, target, models), { signal, onCommand });
    await ensureCurrent();
    const inputs = await composePreviewInputs(model, target, models);
    signal.throwIfAborted();
    status("runtime", `Preparing Compose runtime for ${selected}…`);
    const composeRuntime = await ensureComposeRuntime(cache, signal, (text) => { line(text); status("runtime", text, false); });
    const helpers = await extractHelpers(cache, signal);
    status("rendering", `Rendering saved previews using ${selected}…`);
    renderer = await ComposeRenderer.create(composeRuntime, java, helpers, cache, job, signal, { weight: 1, quietMs: 2_147_483_647 });
    // This one-shot snapshot never grows a persistent pool or performs warm-up work.
    renderer.abandonWarmups();
    const images = await renderer.render(inputs, source, packageDeclaration);
    renderer.dispose();
    renderer = undefined;
    await ensureCurrent();
    const cards = await saveGallery(images, job, signal);
    await ensureCurrent();
    const errors = cards.filter((card) => card.error).length;
    const summary = `${cards.length} saved preview${cards.length === 1 ? "" : "s"} · ${selected}${errors ? ` · ${errors} failed card${errors === 1 ? "" : "s"}` : ""}`;
    status("ready", summary);
    signal.throwIfAborted();
    return { phase: "ready", message: summary, source, root, images: cards };
  } catch (error) {
    const failure = cancelled ? message(signal.reason ?? error) : message(error);
    const summary = `${selected ? `${selected}: ` : ""}${failure.slice(0, 8192)}${!cancelled && log ? `\n\nRecent build/runtime output:\n${log}` : ""}`;
    process.stderr.write(`${summary}\n`);
    status(cancelled ? "cancelled" : "error", summary);
    return { phase: cancelled ? "cancelled" : "error", message: summary, source, root, images: [] };
  } finally {
    clearInterval(timer);
    renderer?.dispose();
    release?.();
    if (job) {
      const temporary = path.join(job, "done.tmp");
      writeFileSync(temporary, "", { mode: 0o600 });
      renameSync(temporary, path.join(job, "done"));
    }
    process.removeListener("SIGINT", terminate);
    process.removeListener("SIGTERM", terminate);
  }
}

// Dependencies may log diagnostics; stdout is reserved for the final machine-readable result.
for (const method of ["log", "info", "debug"] as const) console[method] = (...args: unknown[]) => { process.stderr.write(`${format(...args)}\n`); };
const argv = process.argv.slice(2);
if (argv.length === 1 && argv[0] === "--help") process.stdout.write(USAGE);
else if (argv.length === 1 && argv[0] === "--licenses") process.stdout.write(`${licenses}\n`);
else {
  main(argv).catch((error): Result => ({ phase: "error", message: message(error).slice(0, MAX_LOG), source: "", root: "", images: [] }))
    .then((result) => { process.stdout.write(`${JSON.stringify(result)}\n`); process.exitCode = result.phase === "error" ? 1 : 0; });
}
