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
  const job = path.join(root, ".dev", "job");
  await mkdir(job, { recursive: true });
  await mkdir(path.join(root, "library"));
  const controller = new AbortController();
  const changes = new PreviewChanges(root, job, controller.signal, file => /\.(kt|xml)$/.test(file));
  cleanups.push(async () => { controller.abort(); changes.dispose(); await rm(root, { recursive: true, force: true }); });
  return { root, job, controller, changes };
}
async function deadline<T>(promise: Promise<T>): Promise<T> {
  return Promise.race([promise, delay(3000).then(() => { throw new Error("Missing file change"); })]);
}

test("dependent source atomic saves, additions and deletion survive file inode replacement", async () => {
  const { root, changes } = await fixture();
  const file = path.join(root, "library", "Card.kt");
  await writeFile(file, "one");
  expect((await deadline(changes.next())).files.has(file)).toBe(true);
  await writeFile(path.join(root, "library", ".save"), "two");
  await rename(path.join(root, "library", ".save"), file);
  expect((await deadline(changes.next())).files.has(file)).toBe(true);
  await rm(file);
  expect((await deadline(changes.next())).files.has(file)).toBe(true);
});

test("edits during rendering remain queued and bursts coalesce to the latest revision", async () => {
  const { root, changes } = await fixture();
  const file = path.join(root, "Screen.kt");
  await writeFile(file, "first");
  const rendering = await deadline(changes.next());
  await writeFile(file, "second");
  await delay(30);
  await writeFile(file, "latest");
  await writeFile(path.join(root, "strings.xml"), "resource");
  await delay(300); // renderer remains busy after the debounce expires
  const queued = await deadline(changes.next());
  expect(queued.revision).toBeGreaterThan(rendering.revision);
  expect([...queued.files].sort()).toEqual([file, path.join(root, "strings.xml")].sort());
});

test("editor overlay writes wake previews but generated galleries and build outputs do not", async () => {
  const { root, job, changes, controller } = await fixture();
  await writeFile(path.join(job, "native-documents.json"), '{"documents":[]}');
  const update = await deadline(changes.next());
  expect([...update.files]).toEqual([]);
  await writeFile(path.join(job, "gallery.json"), "{}");
  await writeFile(path.join(root, ".dev", "Generated.kt"), "generated");
  await writeFile(path.join(root, "README.md"), "irrelevant");
  await delay(300);
  expect(changes.revision).toBe(update.revision);
  const waiting = changes.next();
  controller.abort(new Error("pane closed"));
  await expect(waiting).rejects.toThrow("pane closed");
});
