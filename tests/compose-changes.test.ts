import { afterEach, expect, test } from "bun:test";
import { mkdtemp, mkdir, writeFile, rename, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { PreviewChanges } from "../compose/changes";

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup(); });
async function fixture() {
  const root = await mkdtemp(path.join(tmpdir(), "tern-preview-watch-"));
  await mkdir(path.join(root, ".dev"), { recursive: true });
  await mkdir(path.join(root, "library"));
  const controller = new AbortController();
  const batches: ReadonlySet<string>[] = [];
  let waiter: (() => void) | undefined;
  const changes = new PreviewChanges(root, controller.signal, file => /\.(kt|xml)$/.test(file), files => { batches.push(files); waiter?.(); }, error => { throw error; });
  cleanups.push(async () => { controller.abort(); changes.dispose(); await rm(root, { recursive: true, force: true }); });
  const next = async (): Promise<ReadonlySet<string>> => {
    const deadline = Date.now() + 3000;
    while (!batches.length) {
      if (Date.now() > deadline) throw new Error("Missing file change");
      const { promise, resolve } = Promise.withResolvers<void>();
      waiter = resolve;
      await Promise.race([promise, delay(100)]);
    }
    return batches.shift()!;
  };
  return { root, batches, next };
}

test("dependent source atomic saves, additions and deletion survive file inode replacement", async () => {
  const { root, next } = await fixture();
  const file = path.join(root, "library", "Card.kt");
  await writeFile(file, "one");
  expect((await next()).has(file)).toBe(true);
  await writeFile(path.join(root, "library", ".save"), "two");
  await rename(path.join(root, "library", ".save"), file);
  expect((await next()).has(file)).toBe(true);
  await rm(file);
  expect((await next()).has(file)).toBe(true);
});

test("a burst of changes arrives as one batch", async () => {
  const { root, next } = await fixture();
  const file = path.join(root, "Screen.kt");
  await writeFile(file, "first");
  await writeFile(file, "latest");
  await writeFile(path.join(root, "strings.xml"), "resource");
  expect([...await next()].sort()).toEqual([file, path.join(root, "strings.xml")].sort());
});

test("generated build outputs and irrelevant files are ignored", async () => {
  const { root, batches } = await fixture();
  await writeFile(path.join(root, ".dev", "Generated.kt"), "generated");
  await writeFile(path.join(root, "README.md"), "irrelevant");
  await delay(300);
  expect(batches).toEqual([]);
});
