import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { announceStart, liveLocks } from "../android/sdk";

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
    const marker = await announceStart(directory, "Pixel_8", "313532612630", 1_763_100_000_123);
    expect(await readdir(directory)).toEqual([path.basename(marker!)]);
    expect(JSON.parse(await readFile(marker!, "utf8"))).toEqual({ name: "Pixel_8", pane: 313532612630, time: 1_763_100_000 });
  });

  test("a start outside a Tern pane leaves no marker", async () => {
    const directory = path.join(await mkdtemp(path.join(os.tmpdir(), "announce-")), "started");
    expect(await announceStart(directory, "Pixel_8", undefined)).toBeUndefined();
    expect(await announceStart(directory, "Pixel_8", "0")).toBeUndefined();
    expect(await announceStart(directory, "Pixel_8", "12; rm")).toBeUndefined();
    expect(await readdir(directory).catch(() => [])).toEqual([]);
  });
});
