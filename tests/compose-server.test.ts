import { afterEach, expect, test } from "bun:test";
import type { PreviewImage } from "@elide/compose-render";
import { createPreviewServer, type EndReason, type LiveInput, type PreviewServer } from "../compose/server";

const cleanups: (() => Promise<void> | void)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup(); });

/** A 4×4 PNG header the server accepts; `seed` varies its bytes. */
function png(seed: number): string {
  const bytes = Buffer.alloc(33);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
  bytes.writeUInt32BE(13, 8);
  bytes.write("IHDR", 12, "ascii");
  bytes.writeUInt32BE(4, 16);
  bytes.writeUInt32BE(4, 20);
  bytes.writeUInt32BE(seed, 29);
  return bytes.toString("base64");
}
const card = (id: string, seed: number): PreviewImage => ({ id, name: id, detail: "", data: png(seed), live: true });

function fixture() {
  const controller = new AbortController();
  const received: { id: string; action: string }[] = [];
  const backend: LiveInput = {
    pointer: (id, action) => { received.push({ id, action }); return true; },
    keyboard: () => true,
    blur: () => true,
  };
  const ended: EndReason[] = [];
  const refreshes: (() => void)[] = [];
  const server: PreviewServer = createPreviewServer({
    signal: controller.signal,
    info: () => ({ root: "/workspace", file: "/workspace/A.kt" }),
    open: async () => ({ url: server.begin({ name: "A.kt", path: "A.kt" }), root: "/workspace" }),
    documents: () => {},
    retarget: async () => {},
    refresh: () => { refreshes.shift()?.(); },
    stop: () => {},
    ended: (reason) => { ended.push(reason); },
    input: () => backend,
  });
  cleanups.push(() => server.dispose());
  const origin = `http://127.0.0.1:${server.port}`;
  const open = async (): Promise<string> => {
    const response = await fetch(`${origin}/${server.control}/open`, { method: "POST", body: JSON.stringify({ file: "/workspace/A.kt", documents: [] }) });
    expect(response.status).toBe(200);
    return ((await response.json()) as { url: string }).url;
  };
  /** The page's socket; `next` reads its messages in order and follows their epoch. */
  const page = async (url: string) => {
    const messages: Record<string, any>[] = [];
    const waiters = new Set<() => void>();
    const socket = new WebSocket(`${url.replace(/^http/, "ws")}events`, { headers: { Origin: origin } });
    socket.onmessage = (event) => { messages.push(JSON.parse(String(event.data))); for (const wake of waiters) wake(); };
    cleanups.push(() => socket.close());
    const opened = Promise.withResolvers<void>();
    socket.onopen = () => opened.resolve();
    socket.onerror = opened.reject;
    await opened.promise;
    let read = 0;
    let epoch = 0;
    const next = async (match: (message: Record<string, any>) => boolean = () => true): Promise<Record<string, any>> => {
      for (;;) {
        while (read < messages.length) {
          const message = messages[read++]!;
          if (typeof message.epoch === "number") epoch = message.epoch;
          if (match(message)) return message;
        }
        const { promise, resolve } = Promise.withResolvers<void>();
        waiters.add(resolve);
        const timer = setTimeout(resolve, 3000);
        await promise;
        clearTimeout(timer);
        waiters.delete(resolve);
        if (read >= messages.length) throw new Error("Missing page message");
      }
    };
    const send = (value: Record<string, unknown>) => socket.send(JSON.stringify(value));
    /** A refresh round trip: the server handled every message sent before it. Its input reset releases a held pointer. */
    const settle = async () => {
      const { promise, resolve } = Promise.withResolvers<void>();
      refreshes.push(resolve);
      send({ type: "refresh", epoch });
      await promise;
      await next((message) => message.type === "reset");
    };
    return { next, send, settle, epoch: () => epoch };
  };
  return { server, origin, open, page, received, ended };
}

test("a session's page is served under its token, and its control routes refuse browsers", async () => {
  const { origin, open } = fixture();
  const url = await open();
  const html = await fetch(url);
  expect(html.status).toBe(200);
  expect(await html.text()).toContain("<html");
  expect((await fetch(`${origin}/${"0".repeat(64)}/`)).status).toBe(404);
  const posted = await fetch(`${url}documents`, {
    method: "POST", headers: { Origin: origin },
    body: JSON.stringify({ origin: "host", replace: false, documents: [] }),
  });
  expect(posted.status).toBe(403);
});

test("page requests reach the pane's long-poll; an ended session answers 410 with its reason", async () => {
  const { server, open, page, ended } = fixture();
  const url = await open();
  const view = await page(url);
  await view.next((message) => message.type === "status");
  const poll = fetch(`${url}pane?after=0`);
  view.send({ type: "request", action: "source", epoch: view.epoch() });
  const answered = await poll;
  expect(answered.status).toBe(200);
  expect(await answered.json()).toEqual({ id: 1, action: "source" });
  const waiting = fetch(`${url}pane?after=1`);
  server.end("retargeted");
  const gone = await waiting;
  expect(gone.status).toBe(410);
  expect(await gone.json()).toEqual({ ended: "retargeted" });
  expect((await fetch(`${url}pane?after=1`)).status).toBe(410);
  expect(ended).toEqual(["retargeted"]);
});

test("frames reach the page at once, pushes coalesce to the newest, and unchanged cards are not sent again", async () => {
  const { server, open, page } = fixture();
  const view = await page(await open());
  await view.next((message) => message.type === "status");
  server.show([card("a", 1), card("b", 2)], () => false);
  expect((await view.next()).type).toBe("gallery");
  expect((await view.next()).image).toMatchObject({ id: "a", data: png(1) });
  expect((await view.next()).image).toMatchObject({ id: "b", data: png(2) });
  server.push([card("a", 3)], () => false);
  server.push([card("a", 4)], () => false);
  const pushed = await view.next();
  expect(pushed.type).toBe("image");
  expect(pushed.image).toMatchObject({ id: "a", data: png(4) });
  server.show([card("a", 4), card("b", 2)], () => false);
  expect((await view.next()).type).toBe("gallery");
  server.status("live", "sentinel");
  expect(await view.next()).toMatchObject({ type: "status", message: "sentinel" });
});

test("input reaches the backend only while the shown cards are current and only at the current epoch", async () => {
  const { server, open, page, received } = fixture();
  const view = await page(await open());
  await view.next((message) => message.type === "status");
  server.show([card("a", 1)], () => false);
  await view.next((message) => message.type === "gallery");
  const shown = view.epoch();
  view.send({ type: "pointer", id: "a", action: "down", x: 1, y: 1, epoch: shown });
  view.send({ type: "pointer", id: "a", action: "up", x: 1, y: 1, epoch: shown });
  await view.settle();
  expect(received).toEqual([{ id: "a", action: "down" }, { id: "a", action: "up" }]);

  received.length = 0;
  server.invalidate();
  await view.next((message) => message.type === "invalidate");
  view.send({ type: "pointer", id: "a", action: "down", x: 1, y: 1, epoch: view.epoch() });
  await view.settle();
  expect(received).toEqual([]);

  server.show([card("a", 1)], () => false);
  await view.next((message) => message.type === "gallery");
  view.send({ type: "pointer", id: "a", action: "down", x: 1, y: 1, epoch: shown });
  await view.settle();
  expect(received).toEqual([]);
  view.send({ type: "pointer", id: "a", action: "down", x: 1, y: 1, epoch: view.epoch() });
  await view.settle();
  expect(received).toEqual([{ id: "a", action: "down" }, { id: "a", action: "up" }]);
});
