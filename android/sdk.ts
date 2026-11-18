import { spawn, type ChildProcess } from "node:child_process";
import { closeSync, openSync } from "node:fs";
import { mkdir, mkdtemp, open, readFile, readdir, rename, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { adbExecutable, killProcessTree, parseAdbDevices, type AndroidDevice } from "./elide";
import { errorMessage, executable, run } from "./process";

export type Avd = { name: string; serial?: string; state: string };
/** An attached non-emulator device; `name` is read from the device once it accepts commands. */
export type Physical = { serial: string; state: string; name?: string };
type Running = { name?: string; serial: string; state: string; error?: string };
export type Snapshot = { avds: Avd[]; devices: Physical[]; running: Running[]; warnings: string[] };

export function validateName(name: string): string {
  if (!/^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$/.test(name)) {
    throw new Error("Invalid device name. Use 1–128 letters, digits, underscores, dots or hyphens, beginning with a letter, digit or underscore.");
  }
  return name;
}

/** Shell command whose first two output lines `productName` reads. */
export const PRODUCT = "getprop ro.product.manufacturer; getprop ro.product.model";

/** "Manufacturer Model", without repeating a manufacturer the model already starts with. */
export function productName([manufacturer = "", model = ""]: string[]): string | undefined {
  manufacturer = manufacturer.trim(); model = model.trim();
  if (!model) return undefined;
  return !manufacturer || model.toLowerCase().startsWith(manufacturer.toLowerCase()) ? model : `${manufacturer} ${model}`;
}

export class AndroidSdk {
  readonly env: NodeJS.ProcessEnv;
  constructor(readonly root: string) {
    this.env = { ANDROID_HOME: root, ANDROID_SDK_ROOT: root };
  }

  async tool(tool: "emulator" | "adb"): Promise<string> {
    const file = tool === "adb" ? adbExecutable(this.root) : path.join(this.root, "emulator", process.platform === "win32" ? "emulator.exe" : "emulator");
    return executable(file, `${tool}; install Android SDK ${tool === "adb" ? "platform-tools" : "emulator"} in ${this.root}`);
  }

  async manager(): Promise<string> {
    const directory = path.join(this.root, "cmdline-tools");
    const versions = await readdir(directory).catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return [];
      throw error;
    });
    versions.sort((a, b) => a === "latest" ? -1 : b === "latest" ? 1 : b.localeCompare(a, undefined, { numeric: true }));
    const suffix = process.platform === "win32" ? "avdmanager.bat" : "avdmanager";
    for (const file of [...versions.map(version => path.join(directory, version, "bin", suffix)), path.join(this.root, "tools", "bin", suffix)]) {
      if (!(await stat(file).catch(() => undefined))?.isFile()) continue;
      if (process.platform === "win32") throw new Error("The Android helper currently requires a native avdmanager launcher (macOS/Linux); Windows .bat launchers cannot be executed without a shell.");
      return executable(file, "avdmanager (Android SDK command-line tools; requires a JDK/JAVA_HOME)");
    }
    throw new Error(`avdmanager not found under ${this.root}. Install Android SDK Command-line Tools in Android Studio and set JAVA_HOME to a JDK.`);
  }

  async names(): Promise<string[]> {
    const text = await run(await this.tool("emulator"), ["-list-avds"], { env: this.env });
    return [...new Set(text.split(/\r?\n/).map(line => line.trim()).filter(line => /^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$/.test(line)))];
  }

  async attached(): Promise<AndroidDevice[]> {
    return parseAdbDevices(await run(await this.tool("adb"), ["devices"], { env: this.env, timeout: 10_000 }));
  }

  async running(attached?: AndroidDevice[]): Promise<Running[]> {
    const adb = await this.tool("adb");
    const devices = (attached ?? await this.attached()).filter(device => device.emulator);
    const running: Running[] = [];
    for (const device of devices) {
      try {
        const text = await run(adb, ["-s", device.serial, "emu", "avd", "name"], { env: this.env, timeout: 5_000 });
        const lines = text.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
        const name = lines.find(line => line !== "OK" && /^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$/.test(line));
        if (!name || !lines.includes("OK")) throw new Error("The emulator console did not identify its AVD.");
        running.push({ name, serial: device.serial, state: device.ready ? "running" : device.state });
      } catch (error) {
        running.push({ serial: device.serial, state: device.state, error: errorMessage(error) });
      }
    }
    return running;
  }

  /** Waits until a device finished booting; given a `name`, first until an emulator running that AVD attaches. */
  async waitBooted(target: { name?: string; serial?: string }): Promise<{ serial: string; name?: string }> {
    const { name } = target;
    let serial = target.serial;
    if (serial) {
      if (!(await this.attached()).some(device => device.serial === serial)) throw new Error(`No attached device ${serial}.`);
    } else {
      const deadline = Date.now() + 90_000;
      for (;;) {
        const matches = (await this.running()).filter(device => device.name === name);
        if (matches.length > 1) throw new Error(`Multiple emulators run ${name}: ${matches.map(device => device.serial).join(", ")}`);
        if (matches.length === 1) { serial = matches[0]!.serial; break; }
        if (Date.now() >= deadline) throw new Error(`${name} did not start within 90 seconds.`);
        await delay(500);
      }
    }
    const adb = await this.tool("adb");
    const deadline = Date.now() + 180_000;
    for (;;) {
      const booted = await run(adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"], { env: this.env, timeout: 5_000 }).catch(() => "");
      if (booted.trim() === "1") return { serial, ...(name ? { name } : {}) };
      if (Date.now() >= deadline) throw new Error(`${name ?? serial} did not finish booting within 3 minutes.`);
      await delay(500);
    }
  }

  private async physical(attached: AndroidDevice[]): Promise<Physical[]> {
    return Promise.all(attached.filter(device => !device.emulator).map(device => this.describe(device)));
  }

  /** An attached device with its product name, read once the device accepts commands. */
  async describe({ serial, state, ready }: AndroidDevice): Promise<Physical> {
    if (!ready) return { serial, state };
    const adb = await this.tool("adb");
    const name = productName((await run(adb, ["-s", serial, "shell", PRODUCT], { env: this.env, timeout: 5_000 }).catch(() => "")).split(/\r?\n/));
    return { serial, state, ...(name ? { name } : {}) };
  }

  async snapshot(): Promise<Snapshot> {
    const names = await this.names();
    const attached = await this.attached();
    const running = await this.running(attached);
    const avds: Avd[] = [];
    const unidentified = running.some(device => !device.name);
    for (const name of new Set([...names, ...running.flatMap(device => device.name ? [device.name] : [])])) {
      const matches = running.filter(device => device.name === name);
      if (!matches.length) avds.push({ name, state: unidentified ? "unknown" : "stopped" });
      else for (const device of matches) avds.push({ name, serial: device.serial, state: device.state });
    }
    return {
      avds, devices: await this.physical(attached), running,
      warnings: running.filter(device => !device.name).map(device => `Cannot identify the virtual device on ${device.serial} (${device.state}): ${device.error}`),
    };
  }

  async images(): Promise<{ id: string }[]> {
    const base = path.join(this.root, "system-images");
    const directories = async (directory: string): Promise<string[]> => {
      try { return (await readdir(directory, { withFileTypes: true })).filter(entry => entry.isDirectory()).map(entry => entry.name); }
      catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return []; throw error; }
    };
    const images: { id: string }[] = [];
    for (const api of await directories(base)) {
      for (const variant of await directories(path.join(base, api))) {
        for (const abi of await directories(path.join(base, api, variant))) {
          const image = path.join(base, api, variant, abi);
          if ((await stat(path.join(image, "system.img")).catch(() => undefined))?.isFile()
            && (await stat(path.join(image, "source.properties")).catch(() => undefined))?.isFile()) {
            images.push({ id: `system-images;${api};${variant};${abi}` });
          }
        }
      }
    }
    return images.sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true }));
  }

  async profiles(): Promise<{ id: string; name: string }[]> {
    const text = await run(await this.manager(), ["list", "device"], { env: this.env });
    const profiles: { id: string; name: string }[] = [];
    for (const line of text.split(/\r?\n/)) {
      const id = /^\s*id:\s*\d+\s+or\s+"([^"]+)"/.exec(line)?.[1];
      if (id) profiles.push({ id, name: id });
      const name = /^\s*Name:\s*(.+)/.exec(line)?.[1];
      if (name && profiles.length) profiles[profiles.length - 1]!.name = name.trim();
    }
    if (!profiles.length) throw new Error("avdmanager returned no hardware profiles. Check Android SDK Command-line Tools and JAVA_HOME.");
    return profiles;
  }

  async create(name: string, image: string, device: string): Promise<void> {
    validateName(name);
    if (!/^system-images;[^;\/\\]+;[^;\/\\]+;[^;\/\\]+$/.test(image)) throw new Error("--image must be an installed system-images;android-API;VARIANT;ABI package ID.");
    if ((await this.names()).includes(name)) throw new Error(`A virtual device named ${name} already exists; it will not be overwritten.`);
    if (!(await this.images()).some(candidate => candidate.id === image)) throw new Error(`System image ${image} is not installed in ${this.root}. Install it in Android Studio first; no SDK packages or licenses are accepted automatically.`);
    if (!(await this.profiles()).some(profile => profile.id === device)) throw new Error(`Unknown hardware profile ${device}. Run profiles to list available IDs.`);
    await run(await this.manager(), ["create", "avd", "--name", name, "--package", image, "--device", device], { env: this.env, input: "no\n", timeout: 120_000 });
    if (!(await this.names()).includes(name)) throw new Error(`avdmanager did not register ${name}. Check ANDROID_AVD_HOME and the command-line tools installation.`);
    // avdmanager copies the profile's keyboard (none on phones). Without a keyboard device the emulator
    // drops every key event, Back and Home included; Android Studio enables it by default too.
    const config = path.join(await this.directory(name), "config.ini");
    const text = await readFile(config, "utf8");
    const setting = /^hw\.keyboard\s*=.*$/m;
    await writeFile(config, setting.test(text) ? text.replace(setting, "hw.keyboard = yes") : `${text}${text.endsWith("\n") ? "" : "\n"}hw.keyboard = yes\n`);
  }

  async stop(name?: string, serial?: string): Promise<{ serial: string; name?: string }> {
    if (name) validateName(name);
    if (serial && !/^emulator-\d+$/.test(serial)) throw new Error("--serial must identify an emulator (emulator-PORT), not a physical device.");
    const running = await this.running();
    const matches = running.filter(device => serial ? device.serial === serial : device.name === name);
    if (!matches.length) throw new Error(`No running emulator matches ${serial ?? name}. Nothing was stopped.`);
    if (matches.length !== 1) throw new Error(`Multiple emulators run ${name}. Select one explicitly with --serial: ${matches.map(device => device.serial).join(", ")}`);
    const selected = matches[0]!;
    if (name && selected.name !== name) throw new Error(`Cannot confirm ${selected.serial} runs ${name}; it runs ${selected.name ?? "an unidentified device"}. Nothing was stopped.`);
    const adb = await this.tool("adb");
    await run(adb, ["-s", selected.serial, "emu", "kill"], { env: this.env, timeout: 10_000 });
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      const devices = parseAdbDevices(await run(adb, ["devices"], { env: this.env, timeout: 5_000 }));
      if (!devices.some(device => device.serial === selected.serial)) return { serial: selected.serial, name: selected.name };
      await delay(300);
    }
    throw new Error(`Stop was requested for ${selected.serial}, but it is still attached. Wait for it to exit before deleting it.`);
  }

  /**
   * The live process holding AVD `name`: a running emulator keeps its pid in the AVD's
   * `hardware-qemu.ini.lock` from its first second, well before adb lists it. Elide's `--emulator`
   * adopts that emulator rather than booting a second copy. A lock whose process is gone was
   * left by a crash and holds nothing.
   */
  private async holder(name: string): Promise<number | undefined> {
    return lockHolder(path.join(await this.directory(name), "hardware-qemu.ini.lock"));
  }

  /** The AVD's content directory, as registered in its NAME.ini. */
  private async directory(name: string): Promise<string> {
    const userHome = process.env.ANDROID_USER_HOME ?? path.join(os.homedir(), ".android");
    const avdHome = process.env.ANDROID_AVD_HOME ?? path.join(process.env.ANDROID_EMULATOR_HOME ?? userHome, "avd");
    const ini = await readFile(path.join(avdHome, `${name}.ini`), "utf8").catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return "";
      throw error;
    });
    return /^path=(.+)$/m.exec(ini)?.[1]?.trim() ?? path.join(avdHome, `${name}.avd`);
  }

  private async assertUnlocked(name: string): Promise<void> {
    const directory = await this.directory(name);
    const held = await liveLocks(directory);
    if (held.length > 0) {
      throw new Error(`${name} is locked by a running emulator (${held.join(", ")} in ${directory}). Close its emulator first.`);
    }
  }

  async delete(name: string): Promise<void> {
    validateName(name);
    const snapshot = await this.snapshot();
    if (!snapshot.avds.some(avd => avd.name === name)) throw new Error(`Virtual device ${name} does not exist.`);
    if (snapshot.running.some(device => device.name === name)) throw new Error(`${name} is running. Stop it before deleting it.`);
    if (snapshot.running.some(device => !device.name)) throw new Error(`Cannot safely delete a virtual device while an emulator cannot be identified. Stop or reconnect it first.\n${snapshot.warnings.join("\n")}`);
    await this.assertUnlocked(name);
    await run(await this.manager(), ["delete", "avd", "--name", name], { env: this.env });
    if ((await this.names()).includes(name)) throw new Error(`avdmanager completed but ${name} is still registered. Check its output and Android AVD home.`);
  }

  /**
   * Starts `name` unless it runs; `signal` cancels a start in progress, stopping its emulator.
   * With `held`, returns as soon as the emulator holds the AVD, without a serial: the emulator
   * registers with adb seconds later, and Elide's `--emulator` adopts it in between. An AVD held
   * by an emulator adb does not list yet, one starting or one stopping, is waited for: until adb
   * lists it, or until it lets go and a new emulator can start.
   */
  async start(name: string, signal?: AbortSignal, held = false): Promise<{ serial?: string; state: string; log?: string }> {
    validateName(name);
    const snapshot = await this.snapshot();
    const existing = snapshot.running.filter(device => device.name === name);
    if (existing.length > 1) throw new Error(`Multiple emulators already run ${name}: ${existing.map(device => device.serial).join(", ")}`);
    if (existing.length === 1) return { serial: existing[0]!.serial, state: existing[0]!.state };
    if (!snapshot.avds.some(avd => avd.name === name)) throw new Error(`Virtual device ${name} does not exist. Create it first (create --root for the configured AVD, or create --name NAME --image PACKAGE --device PROFILE).`);
    for (const deadline = Date.now() + 60_000; await this.holder(name);) {
      if (signal?.aborted) throw new Error("Start cancelled.");
      const listed = (await this.running()).filter(device => device.name === name);
      if (listed.length === 1) return { serial: listed[0]!.serial, state: listed[0]!.state };
      if (Date.now() >= deadline) throw new Error(`${name} is held by an emulator adb does not list. Stop it, then start ${name} again.`);
      await delay(300);
    }
    if (snapshot.running.some(device => !device.name)) throw new Error(`Cannot safely start another emulator while a running one cannot be identified.\n${snapshot.warnings.join("\n")}`);
    if (signal?.aborted) throw new Error("Start cancelled.");
    await this.assertUnlocked(name);
    const emulator = await this.tool("emulator");
    const directory = await mkdtemp(path.join(os.tmpdir(), "elide-tern-android-"));
    const log = path.join(directory, `${name}.log`);
    const fd = openSync(log, "wx", 0o600);
    let child: ChildProcess;
    try {
      child = spawn(emulator, ["-avd", name, "-no-window", "-grpc-use-token", ...(process.platform === "darwin" ? ["-gpu", "host"] : [])], {
        env: { ...process.env, ...this.env }, detached: true, stdio: ["ignore", fd, fd],
      });
    } finally { closeSync(fd); }
    let failure: string | undefined;
    child.once("error", error => { failure = errorMessage(error); });
    child.once("exit", (code, signal) => { failure = `Emulator exited (${signal ?? code}).`; });
    const started = Date.now();
    try {
      while (Date.now() - started < 60_000) {
        if (signal?.aborted) throw new Error("Start cancelled.");
        if (failure) throw new Error(failure);
        if (held && await this.holder(name)) {
          child.unref();
          return { state: "starting", log };
        }
        const matching = (await this.running()).filter(device => device.name === name);
        if (failure) throw new Error(failure);
        if (matching.length > 1) throw new Error(`Multiple emulators started for ${name}; choose a serial explicitly.`);
        if (matching.length === 1 && Date.now() - started >= 2_000) {
          const selected = matching[0]!;
          const booted = await run(await this.tool("adb"), ["-s", selected.serial, "shell", "getprop", "sys.boot_completed"], { env: this.env, timeout: 5_000 }).catch(() => "");
          if (failure) throw new Error(failure);
          child.unref();
          return { serial: selected.serial, state: booted.trim() === "1" ? "running" : "starting", log };
        }
        await delay(300);
      }
      throw new Error("Emulator did not register with adb within 60 seconds.");
    } catch (error) {
      if (child.pid !== undefined && child.exitCode === null && child.signalCode === null) await stopProcess(child);
      const handle = await open(log, "r");
      let tail = "";
      try {
        const size = (await handle.stat()).size;
        const bytes = Buffer.alloc(Math.min(size, 16_384));
        const result = await handle.read(bytes, 0, bytes.length, Math.max(0, size - bytes.length));
        tail = bytes.toString("utf8", 0, result.bytesRead);
        // Read from the middle of the file, the first line is cut.
        if (size > bytes.length) tail = tail.slice(tail.indexOf("\n") + 1);
      } finally { await handle.close(); }
      // The lines that say why go first: the pane shows only a few, and a toast one.
      const cause = logCause(tail);
      throw new Error([errorMessage(error), ...cause, `Emulator log: ${log}`].join("\n"));
    }
  }
}

/**
 * Why an emulator start failed, from the end of its log (`tail`): the last two FATAL, ERROR or
 * PANIC lines, else its last two lines. The log starts with pages of INFO lines; the reason
 * (a KVM, GPU or image error) comes last.
 */
export function logCause(tail: string): string[] {
  const lines = tail.split("\n").map(line => line.trimEnd()).filter(line => line.trim() !== "");
  const fatal = lines.filter(line => /\b(FATAL|ERROR|PANIC)\b/.test(line));
  return (fatal.length ? fatal : lines).slice(-2);
}

/**
 * The live pid a lock at `lock` names, else `undefined`: the emulator writes its pid,
 * NUL-terminated, into a lock file, or into a `pid` file inside a lock directory. A lock whose
 * process is gone was left by a crash or a killed start and holds nothing.
 */
export async function lockHolder(lock: string): Promise<number | undefined> {
  const info = await stat(lock).catch(() => undefined);
  if (!info) return undefined;
  const text = await readFile(info.isDirectory() ? path.join(lock, "pid") : lock, "utf8").catch(() => "");
  const pid = Number.parseInt(text.replace(/\0/g, "").trim(), 10);
  if (!Number.isInteger(pid) || pid <= 0) return undefined;
  try { process.kill(pid, 0); return pid; } catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM" ? pid : undefined; }
}

/**
 * Leaves a marker in `directory` saying AVD `name` was started from SDK `sdk` for Tern pane
 * `pane` (the `TERN_PANE` of the command that asked): the window showing that pane opens the
 * device pane beside it (`plugin/lib/android.luau`), however the command was typed, wrapped or
 * re-run, and lists devices through the same SDK. No pane, no marker. Returns the marker's path.
 * `time` is in Unix seconds.
 */
export async function announceStart(directory: string, name: string, pane: string | undefined, sdk: string, now = Date.now()): Promise<string | undefined> {
  if (!pane || !/^[1-9]\d{0,15}$/.test(pane)) return undefined;
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const marker = path.join(directory, `${now}-${process.pid}-${validateName(name)}.json`);
  // Written aside and renamed, so a reader never sees half a marker.
  await writeFile(`${marker}.tmp`, JSON.stringify({ name, pane: Number(pane), sdk, time: Math.floor(now / 1000) }), { mode: 0o600 });
  await rename(`${marker}.tmp`, marker);
  return marker;
}

/**
 * The emulator locks in AVD `directory` a live process holds. `multiinstance.lock` is a
 * persistent advisory-lock file the emulator leaves on a clean exit, not a running-instance
 * marker; stale locks of dead processes do not block a start or a delete.
 */
export async function liveLocks(directory: string): Promise<string[]> {
  const entries = await readdir(directory).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return [];
    throw error;
  });
  const held: string[] = [];
  for (const entry of entries) {
    if (entry === "multiinstance.lock" || !entry.endsWith(".lock")) continue;
    if (await lockHolder(path.join(directory, entry))) held.push(entry);
  }
  return held;
}

/** Stops `child`'s process group: SIGTERM, so the emulator releases its locks, then SIGKILL. */
async function stopProcess(child: ChildProcess, grace = 5_000): Promise<void> {
  const pid = child.pid!;
  killProcessTree(pid, "SIGTERM");
  const deadline = Date.now() + grace;
  while (child.exitCode === null && child.signalCode === null && Date.now() < deadline) await delay(100);
  if (child.exitCode === null && child.signalCode === null) killProcessTree(pid, "SIGKILL");
}
