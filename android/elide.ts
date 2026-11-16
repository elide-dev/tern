// Elide project facts the Android helper reads. Derived from `elide-dev/vscode` `packages/core/src`
// (MIT, Elide Technologies, Inc.); see third_party/README.md.
import { realpathSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// ---- elide.ts ----

export interface ElideDistribution {
  /** Distribution root, e.g. `~/.local/share/elide`. */
  readonly home: string;
  /** Path to the CLI binary: `<home>/bin/elide` (`elide.exe` on Windows). */
  readonly bin: string;
}

export interface ResolveElideOptions {
  /** Explicit distribution root; wins over every other source and must be valid. */
  explicitHome?: string;
  env?: NodeJS.ProcessEnv;
  platform?: NodeJS.Platform;
  isFile?: (p: string) => boolean;
  /** Resolve a binary on `PATH`; return its path or `undefined`. */
  which?: (name: string) => string | undefined;
}

const ELIDE_BINARY_NAME = "elide";
export const MANIFEST_NAME = "elide.pkl";

function distributionAt(home: string, platform: NodeJS.Platform = process.platform): ElideDistribution {
  return { home, bin: path.join(home, "bin", platform === "win32" ? `${ELIDE_BINARY_NAME}.exe` : ELIDE_BINARY_NAME) };
}

function defaultIsFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

/** First executable named `name` on `PATH`, or `undefined` when there is none. */
export function whichExecutable(name: string, env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform = process.platform): string | undefined {
  const dirs = (env.PATH ?? "").split(path.delimiter).filter(Boolean);
  const names = platform === "win32" ? [`${name}.exe`, `${name}.cmd`, `${name}.bat`, name] : [name];
  for (const dir of dirs) {
    for (const n of names) {
      const candidate = path.join(dir, n);
      if (defaultIsFile(candidate)) return candidate;
    }
  }
  return undefined;
}

/** Platform install locations, in the order the IntelliJ plugin probes them. */
export function defaultHomeCandidates(env: NodeJS.ProcessEnv, platform: NodeJS.Platform): string[] {
  const home = env.HOME ?? env.USERPROFILE ?? os.homedir();
  if (platform === "win32") {
    const out: string[] = [];
    if (env.LOCALAPPDATA) out.push(path.join(env.LOCALAPPDATA, "elide"));
    if (env.ProgramFiles) out.push(path.join(env.ProgramFiles, "Elide"));
    out.push(path.join(home, ".local", "share", "elide"), path.join(home, ".elide"));
    return out;
  }
  const out: string[] = [];
  if (env.XDG_DATA_HOME) out.push(path.join(env.XDG_DATA_HOME, "elide"));
  out.push(path.join(home, ".local", "share", "elide"), "/opt/elide/current", path.join(home, ".elide"));
  return out;
}

/**
 * Locate an Elide distribution: explicit home → `$ELIDE_HOME` → platform candidates → `elide` on `PATH`
 * (resolved through symlinks to its distribution root).
 */
export function resolveElideDistribution(opts: ResolveElideOptions = {}): ElideDistribution {
  const env = opts.env ?? process.env;
  const platform = opts.platform ?? process.platform;
  const isFile = opts.isFile ?? defaultIsFile;
  const which = opts.which ?? ((name: string) => whichExecutable(name, env, platform));

  const valid = (home: string): ElideDistribution | undefined => {
    const dist = distributionAt(home, platform);
    return isFile(dist.bin) ? dist : undefined;
  };

  if (opts.explicitHome) {
    const dist = valid(opts.explicitHome);
    if (!dist) throw new Error(`Not an Elide distribution: ${opts.explicitHome} (missing bin/elide)`);
    return dist;
  }

  const tried: string[] = [];
  if (env.ELIDE_HOME) {
    tried.push(env.ELIDE_HOME);
    const dist = valid(env.ELIDE_HOME);
    if (dist) return dist;
  }
  for (const candidate of defaultHomeCandidates(env, platform)) {
    tried.push(candidate);
    const dist = valid(candidate);
    if (dist) return dist;
  }
  const onPath = which(ELIDE_BINARY_NAME);
  if (onPath) {
    tried.push(`PATH (${onPath})`);
    let real = onPath;
    try {
      real = realpathSync(onPath);
    } catch {
      // keep the unresolved path
    }
    const dist = valid(path.dirname(path.dirname(real)));
    if (dist) return dist;
  }
  throw new Error(`Elide CLI not found. Looked in: ${tried.join(", ")}`);
}

/** Kill `pid` and, on POSIX, its whole process group (the CLI re-execs and forks a grandchild JVM). */
export function killProcessTree(pid: number, signal: NodeJS.Signals): void {
  try {
    if (process.platform !== "win32") process.kill(-pid, signal);
    else process.kill(pid, signal);
  } catch {
    try {
      process.kill(pid, signal);
    } catch {
      // already gone
    }
  }
}

// ---- version.ts ----

/** A parsed Elide release: `elide --version` prints `<major>.<minor>.<patch>[+<suffix>]`. */
export interface ElideVersion {
  major: number;
  minor: number;
  patch: number;
}

const VERSION_PATTERN = /^(\d+)\.(\d+)\.(\d+)/;

/** Parse the leading `<major>.<minor>.<patch>` of a version display string; `undefined` when it has none. */
export function parseElideVersion(display: string): ElideVersion | undefined {
  const m = VERSION_PATTERN.exec(display.trim());
  if (!m) return undefined;
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]) };
}

/** Compare two versions component-wise: negative when `a` is older, positive when newer, `0` when equal. */
export function compareElideVersions(a: ElideVersion, b: ElideVersion): number {
  return a.major - b.major || a.minor - b.minor || a.patch - b.patch;
}

// ---- buildTasks.ts ----

/** One flag a build task declares, as `elide build --inspect` lists it. */
export interface BuildTaskOption {
  /** Flag name the CLI takes back, without the value or negation the listing decorates it with: `--debugger`. */
  option: string;
  description: string;
}

/** A target of `elide build <name>`, with the options it accepts. */
export interface BuildTaskInfo {
  /** Target name exactly as listed, which is what `elide build` accepts back: qualified (`core:jar`) in a workspace. */
  name: string;
  description: string;
  options: BuildTaskOption[];
  /** Workspace project the listing groups the task under; absent for a project outside a workspace. */
  project?: string;
}

/** `8 tasks available:` for a standalone project, `43 tasks across 5 projects:` for a workspace. */
const HEADER = /^\d+ tasks? (?:available|across \d+ projects?):$/;
/** A workspace group header: an unindented project name, which Elide forbids whitespace and colons in. */
const GROUP = /^[^\s:]+$/;
/** `  compile-kotlin-main   Compile main Kotlin source files to bytecode` */
const TASK = /^ {2}(\S+)(?: {2,}(.*))?$/;
/** `    --debugger[=<value>]   Attach JDWP debugger, optionally specify host:port` */
const OPTION = /^ {4}(-\S.*?)(?: {2,}(.*))?$/;
/** Everything after the name in an option's flag column: its value form, its negation, its default. */
const OPTION_DECORATION = /[\s=[].*$/;
/** Separator between the project a workspace task belongs to and the task's own name. */
const SCOPE_SEPARATOR = ":";

/**
 * Parse the task table `elide build --inspect` prints (there is no JSON form). The table starts after its header
 * and ends at the first unindented line that is not a workspace group header (`Global options:`).
 */
export function parseBuildInspect(text: string): BuildTaskInfo[] {
  const lines = text.split("\n").map((line) => line.replace(/\s+$/, ""));
  let index = lines.findIndex((line) => HEADER.test(line));
  if (index < 0) return [];

  const tasks: BuildTaskInfo[] = [];
  let project: string | undefined;
  for (index++; index < lines.length; index++) {
    const line = lines[index] ?? "";
    if (line.length === 0) continue;
    if (!line.startsWith(" ")) {
      if (!GROUP.test(line)) break;
      project = line;
      continue;
    }

    const option = OPTION.exec(line);
    const last = tasks[tasks.length - 1];
    if (option && last) {
      last.options.push({ option: (option[1] ?? "").replace(OPTION_DECORATION, ""), description: option[2]?.trim() ?? "" });
      continue;
    }
    const task = TASK.exec(line);
    if (task) tasks.push({ name: task[1] ?? "", description: task[2]?.trim() ?? "", options: [], ...(project ? { project } : {}) });
  }
  return tasks;
}

/** The tasks of the project Elide knows as `project`; a listing that groups nothing is all of it. */
export function buildTasksOf(tasks: readonly BuildTaskInfo[], project: string): BuildTaskInfo[] {
  return tasks.filter((task) => task.project === undefined || task.project === project);
}

/** A task's own name, without the project scope a workspace listing qualifies it with (`core:jar` → `jar`). */
export function unqualifiedTaskName(task: BuildTaskInfo): string {
  const scope = `${task.project}${SCOPE_SEPARATOR}`;
  return task.project !== undefined && task.name.startsWith(scope) ? task.name.slice(scope.length) : task.name;
}

// ---- android.ts ----

/** Create the project's virtual device, without booting it. */
export const ANDROID_AVD_TASK = "android-avd";

/** AVD the build creates and boots for a project that declares neither an AVD name nor a project name. */
export const DEFAULT_AVD_NAME = "elide-android";

/** Serial prefix `adb` gives every emulator; a physical device carries its own. */
const EMULATOR_SERIAL_PREFIX = "emulator-";

/** Whether `serial` names an emulator, which holds even after it disappeared from `adb devices`. */
export function isEmulatorSerial(serial: string): boolean {
  return serial.startsWith(EMULATOR_SERIAL_PREFIX);
}

/** The only `adb devices` state that can take an install. */
const DEVICE_STATE_READY = "device";

function normalizePath(p: string): string {
  const forward = p.trim().replace(/\\/g, "/");
  return forward.length > 1 ? forward.replace(/\/+$/, "") : forward;
}

/** Where to look for an installed Android SDK, in the order the build looks. */
export interface AndroidSdkLookup {
  /** `android.sdk` of the manifest, read against {@link projectRoot}. */
  declared?: string;
  projectRoot?: string;
  env?: Readonly<Record<string, string | undefined>>;
  homeDir?: string;
  platform?: NodeJS.Platform;
  isDirectory?: (p: string) => boolean;
}

function isDirectorySync(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/** Where Android Studio and `sdkmanager` install an SDK when nothing says otherwise. */
function conventionalSdkRoots(home: string, platform: NodeJS.Platform, env: Readonly<Record<string, string | undefined>>): string[] {
  if (platform === "darwin") return [path.join(home, "Library", "Android", "sdk")];
  if (platform === "win32") {
    const local = env.LOCALAPPDATA;
    return [
      ...(local ? [path.join(local, "Android", "Sdk")] : []),
      path.join(home, "AppData", "Local", "Android", "Sdk"),
    ];
  }
  return [path.join(home, "Android", "Sdk")];
}

/**
 * The SDK root an Elide build of this project would use: the manifest's `android.sdk`, else `ANDROID_HOME`, else
 * `ANDROID_SDK_ROOT`, else where the SDK installs itself on this host. A declared path that is not a directory
 * resolves to nothing rather than falling through.
 */
export function androidSdkRoot(lookup: AndroidSdkLookup = {}): string | undefined {
  const isDirectory = lookup.isDirectory ?? isDirectorySync;
  const env = lookup.env ?? process.env;
  if (lookup.declared && lookup.declared.length > 0) {
    const declared = path.resolve(lookup.projectRoot ?? process.cwd(), lookup.declared);
    return isDirectory(declared) ? normalizePath(declared) : undefined;
  }
  for (const variable of ["ANDROID_HOME", "ANDROID_SDK_ROOT"]) {
    const value = env[variable];
    if (value && value.length > 0 && isDirectory(value)) return normalizePath(path.resolve(value));
  }
  const home = lookup.homeDir ?? os.homedir();
  if (!home) return undefined;
  const found = conventionalSdkRoots(home, lookup.platform ?? process.platform, env).find(isDirectory);
  return found ? normalizePath(found) : undefined;
}

/** `adb` of an installed SDK; the SDK puts nothing on `PATH`, so it is always addressed by absolute path. */
export function adbExecutable(sdkRoot: string, platform: NodeJS.Platform = process.platform): string {
  return path.join(sdkRoot, "platform-tools", platform === "win32" ? "adb.exe" : "adb");
}

/** One device or emulator `adb devices` reported. */
export interface AndroidDevice {
  /** Serial number, which is what `--device` and `adb -s` take. */
  serial: string;
  /** `device`, `offline`, `unauthorized`, `bootloader`, … */
  state: string;
  /** Whether this is an emulator. */
  emulator: boolean;
  /** Whether the device can take an install: only the `device` state can. */
  ready: boolean;
}

/** Devices `adb devices` listed, in order; lines that are not `<serial>\t<state>` carry no device. */
export function parseAdbDevices(text: string): AndroidDevice[] {
  const devices: AndroidDevice[] = [];
  for (const line of text.split("\n")) {
    const parts = line.trim().split("\t");
    if (parts.length !== 2) continue;
    const serial = parts[0]?.trim() ?? "";
    const state = parts[1]?.trim() ?? "";
    if (serial.length === 0 || state.length === 0) continue;
    devices.push({ serial, state, emulator: isEmulatorSerial(serial), ready: state === DEVICE_STATE_READY });
  }
  return devices;
}

// ---- manifest.ts (reduced) ----

const DEFAULT_DEVICE_PROFILE = "pixel_6";

/** The parts of `elide project export` the helper reads. */
export type Manifest = {
  name?: string;
  workspaceMembers: string[];
  android?: { sdk?: string; device: { avd?: string; systemImage?: string; deviceProfile: string } };
};

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Decode the JSON the CLI exports for a project. */
export function decodeManifest(text: string): Manifest {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new Error("Elide returned an invalid project manifest.");
  }
  if (!isObject(raw)) throw new Error("Elide returned an invalid project manifest.");
  const members = isObject(raw.workspace) && Array.isArray(raw.workspace.members)
    ? raw.workspace.members.filter((m): m is string => typeof m === "string")
    : [];
  const manifest: Manifest = { workspaceMembers: members };
  if (typeof raw.name === "string") manifest.name = raw.name;
  if (isObject(raw.android)) {
    const v = raw.android;
    const device = isObject(v.device) ? v.device : {};
    manifest.android = {
      ...(typeof v.sdk === "string" ? { sdk: v.sdk } : {}),
      device: {
        ...(typeof device.avd === "string" ? { avd: device.avd } : {}),
        ...(typeof device.systemImage === "string" ? { systemImage: device.systemImage } : {}),
        deviceProfile: typeof device.deviceProfile === "string" ? device.deviceProfile : DEFAULT_DEVICE_PROFILE,
      },
    };
  }
  return manifest;
}

// ---- workspace.ts ----

/** The name Elide knows the project rooted at `root` by: the one its manifest declares, else the directory's own. */
export function projectName(manifest: Manifest, root: string): string {
  return manifest.name ?? path.basename(root);
}
