import { spawn, type ChildProcess } from "node:child_process";
import { closeSync, openSync } from "node:fs";
import { mkdtemp, open, readFile, readdir, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { adbExecutable, killProcessTree, parseAdbDevices } from "@elide/ide-core";
import { errorMessage, executable, run } from "./process";

export type Avd = { name: string; serial?: string; state: string };
type Running = { name?: string; serial: string; state: string; error?: string };
export type Snapshot = { avds: Avd[]; running: Running[]; warnings: string[] };

export function validateName(name: string): string {
  if (!/^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$/.test(name)) {
    throw new Error("Invalid AVD name. Use 1–128 letters, digits, underscores, dots or hyphens, beginning with a letter, digit or underscore.");
  }
  return name;
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

  async running(): Promise<Running[]> {
    const adb = await this.tool("adb");
    const devices = parseAdbDevices(await run(adb, ["devices"], { env: this.env, timeout: 10_000 })).filter(device => device.emulator);
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

  async snapshot(): Promise<Snapshot> {
    const names = await this.names();
    const running = await this.running();
    const avds: Avd[] = [];
    const unidentified = running.some(device => !device.name);
    for (const name of new Set([...names, ...running.flatMap(device => device.name ? [device.name] : [])])) {
      const matches = running.filter(device => device.name === name);
      if (!matches.length) avds.push({ name, state: unidentified ? "unknown" : "stopped" });
      else for (const device of matches) avds.push({ name, serial: device.serial, state: device.state });
    }
    return { avds, running, warnings: running.filter(device => !device.name).map(device => `Cannot identify AVD for ${device.serial} (${device.state}): ${device.error}`) };
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
    if ((await this.names()).includes(name)) throw new Error(`AVD ${name} already exists; it will not be overwritten.`);
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
    if (name && selected.name !== name) throw new Error(`Cannot confirm ${selected.serial} runs ${name}; its AVD is ${selected.name ?? "unidentified"}. Nothing was stopped.`);
    const adb = await this.tool("adb");
    await run(adb, ["-s", selected.serial, "emu", "kill"], { env: this.env, timeout: 10_000 });
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      const devices = parseAdbDevices(await run(adb, ["devices"], { env: this.env, timeout: 5_000 }));
      if (!devices.some(device => device.serial === selected.serial)) return { serial: selected.serial, name: selected.name };
      await delay(300);
    }
    throw new Error(`Stop was requested for ${selected.serial}, but it is still attached. Wait for it to exit before deleting its AVD.`);
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
    const entries = await readdir(directory).catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return [];
      throw error;
    });
    // multiinstance.lock is a persistent advisory-lock file, not a running-instance marker.
    // The emulator leaves it behind on a clean exit. Transient .lock files/directories are different.
    if (entries.some(entry => entry !== "multiinstance.lock" && entry.endsWith(".lock"))) {
      throw new Error(`AVD ${name} has emulator lock files in ${directory}. Close its emulator first; if it crashed, confirm no emulator is running before removing stale locks.`);
    }
  }

  async delete(name: string): Promise<void> {
    validateName(name);
    const snapshot = await this.snapshot();
    if (!snapshot.avds.some(avd => avd.name === name)) throw new Error(`AVD ${name} does not exist.`);
    if (snapshot.running.some(device => device.name === name)) throw new Error(`AVD ${name} is running. Stop it before deleting it.`);
    if (snapshot.running.some(device => !device.name)) throw new Error(`Cannot safely delete an AVD while an emulator cannot be identified. Stop or reconnect it first.\n${snapshot.warnings.join("\n")}`);
    await this.assertUnlocked(name);
    await run(await this.manager(), ["delete", "avd", "--name", name], { env: this.env });
    if ((await this.names()).includes(name)) throw new Error(`avdmanager completed but ${name} is still registered. Check its output and Android AVD home.`);
  }

  async start(name: string): Promise<{ serial: string; state: string; log?: string }> {
    validateName(name);
    const snapshot = await this.snapshot();
    const existing = snapshot.running.filter(device => device.name === name);
    if (existing.length > 1) throw new Error(`Multiple emulators already run ${name}: ${existing.map(device => device.serial).join(", ")}`);
    if (existing.length === 1) return { serial: existing[0]!.serial, state: existing[0]!.state };
    if (!snapshot.avds.some(avd => avd.name === name)) throw new Error(`AVD ${name} does not exist. Create it first (create --root for the configured AVD, or create --name NAME --image PACKAGE --device PROFILE).`);
    if (snapshot.running.some(device => !device.name)) throw new Error(`Cannot safely start another emulator while a running AVD cannot be identified.\n${snapshot.warnings.join("\n")}`);
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
        if (failure) throw new Error(failure);
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
      if (child.pid !== undefined && child.exitCode === null && child.signalCode === null) killProcessTree(child.pid, "SIGKILL");
      const handle = await open(log, "r");
      let detail: string;
      try {
        const size = (await handle.stat()).size;
        const bytes = Buffer.alloc(Math.min(size, 16_384));
        const result = await handle.read(bytes, 0, bytes.length, Math.max(0, size - bytes.length));
        detail = bytes.toString("utf8", 0, result.bytesRead).trim();
      } finally { await handle.close(); }
      throw new Error(`${errorMessage(error)}\nEmulator log: ${log}${detail ? `\n${detail}` : ""}`);
    }
  }
}
