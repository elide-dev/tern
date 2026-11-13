import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { liveLocks } from "../android/sdk";

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
