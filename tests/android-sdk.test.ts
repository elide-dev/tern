import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { run } from "../android/process";
import { announceStart, liveLocks, logCause } from "../android/sdk";

describe("liveLocks", () => {
  test("only locks a live process holds block an AVD", async () => {
    const avd = await mkdtemp(path.join(os.tmpdir(), "avd-"));
    const gone = spawnSync("true").pid;
    // A crashed or killed start leaves its locks naming a process that is gone.
    await writeFile(path.join(avd, "hardware-qemu.ini.lock"), `${gone}\0`);
    await mkdir(path.join(avd, "userdata-qemu.img.lock"));
    await writeFile(path.join(avd, "userdata-qemu.img.lock", "pid"), `${gone}`);
    await writeFile(path.join(avd, "multiinstance.lock"), "");
    await writeFile(path.join(avd, "config.ini"), "");
    expect(await liveLocks(avd)).toEqual([]);
    // A running emulator's lock names itself.
    await writeFile(path.join(avd, "hardware-qemu.ini.lock"), `${process.pid}\0`);
    await writeFile(path.join(avd, "userdata-qemu.img.lock", "pid"), `${process.pid}`);
    expect((await liveLocks(avd)).sort()).toEqual(["hardware-qemu.ini.lock", "userdata-qemu.img.lock"]);
  });

  test("a missing AVD directory has no locks", async () => {
    expect(await liveLocks(path.join(os.tmpdir(), "no-such-avd-dir"))).toEqual([]);
  });
});

describe("announceStart", () => {
  test("names the AVD and the asking pane in a complete marker", async () => {
    const directory = path.join(await mkdtemp(path.join(os.tmpdir(), "announce-")), "started");
    const marker = await announceStart(directory, "Pixel_8", "313532612630", "/sdk", 1_763_100_000_123);
    expect(await readdir(directory)).toEqual([path.basename(marker!)]);
    expect(JSON.parse(await readFile(marker!, "utf8"))).toEqual({ name: "Pixel_8", pane: 313532612630, sdk: "/sdk", time: 1_763_100_000 });
  });

  test("a start outside a Tern pane leaves no marker", async () => {
    const directory = path.join(await mkdtemp(path.join(os.tmpdir(), "announce-")), "started");
    expect(await announceStart(directory, "Pixel_8", undefined, "/sdk")).toBeUndefined();
    expect(await announceStart(directory, "Pixel_8", "0", "/sdk")).toBeUndefined();
    expect(await announceStart(directory, "Pixel_8", "12; rm", "/sdk")).toBeUndefined();
    expect(await readdir(directory).catch(() => [])).toEqual([]);
  });
});

describe("logCause", () => {
  test("the error lines at the end of the log, not its first INFO lines", () => {
    const log = [
      "INFO    | Android emulator version 35.1.4",
      "INFO    | Found systemPath /sdk/system-images/android-35/google_apis/arm64-v8a/",
      "WARNING | unexpected system image feature string",
      "ERROR   | x86_64 emulation currently requires hardware acceleration!",
      "INFO    | shutting down",
      "FATAL   | CPU acceleration status: HAXM is not installed on this machine",
      "",
    ].join("\n");
    expect(logCause(log)).toEqual([
      "ERROR   | x86_64 emulation currently requires hardware acceleration!",
      "FATAL   | CPU acceleration status: HAXM is not installed on this machine",
    ]);
  });

  test("without an error line, the last lines", () => {
    expect(logCause("INFO | a\nINFO | b\n\nINFO | c\n")).toEqual(["INFO | b", "INFO | c"]);
    expect(logCause("")).toEqual([]);
  });
});

describe("run", () => {
  // A closed device view cancels its adb queries; one left running holds the pane open.
  test("aborting the signal kills the running child", async () => {
    const cancel = new AbortController();
    const started = Date.now();
    const sleeping = run("/bin/sleep", ["30"], { signal: cancel.signal });
    cancel.abort();
    await expect(sleeping).rejects.toThrow("sleep was cancelled.");
    expect(Date.now() - started).toBeLessThan(10_000);
  });
});
