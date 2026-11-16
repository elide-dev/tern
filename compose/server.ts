import { randomBytes } from "node:crypto";
import type { ServerWebSocket } from "bun";
import { isPreviewKeyEvent } from "@elide/compose-backend";
import type { KomodoBackend } from "@elide/compose-komodo";
import type { PreviewImage } from "@elide/compose-render";
import page from "./preview.html" with { type: "text" };
import client from "./client.js" with { type: "text" };

const MAX_PNG = 8 * 1024 * 1024;
const MAX_BYTES = 32 * 1024 * 1024;
const MAX_CARDS = 32;
const PUSH_INTERVAL_MS = 50;
const POLL_MS = 20_000;
const ABANDON_MS = 15_000;
const PAGE_GRACE_MS = 5_000;
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

/** What the page's card shows. */
type Card = { id: string; name: string; detail: string; data?: string; error?: string; width?: number; height?: number };
type Frame = Card & { live: boolean; keyboard: boolean; size: number };
/** Pane actions the native block carries out: open the source, close itself, follow another file. */
export type PaneAction = "source" | "close" | "retarget";
export type EndReason = "closed" | "page-closed" | "abandoned" | "retargeted" | "stopped";
export interface DocumentsPost { origin: "host" | "native"; replace: boolean; documents: { file: string; text: string | null }[]; error?: string }
export type LiveInput = Pick<KomodoBackend, "pointer" | "keyboard" | "blur">;
export interface PreviewServer {
  readonly port: number;
  readonly control: string;
  /** A page is connected to the current session. */
  readonly connected: boolean;
  /** Ends the current session ("retargeted") and starts another; its page URL. */
  begin(file: { name: string; path: string }): string;
  end(reason: EndReason): void;
  file(file: { name: string; path: string }): void;
  pane(action: PaneAction, file?: string): void;
  status(phase: string, message: string): void;
  /** Releases input; no card is interactive until the next `show`. */
  invalidate(): void;
  show(images: readonly PreviewImage[], keyboard: (id: string) => boolean): void;
  push(images: readonly PreviewImage[], keyboard: (id: string) => boolean): void;
  /** Releases input; the cards stay interactive. */
  reset(): void;
  dispose(): Promise<void>;
}
export interface PreviewServerOptions {
  signal: AbortSignal;
  info(): { root: string; file: string };
  open(request: { file: string; documents: { file: string; text: string }[]; keepAlive?: number }): Promise<{ url: string; root: string }>;
  documents(post: DocumentsPost): void | Promise<void>;
  retarget(file: string): Promise<void>;
  refresh(): void;
  stop(): void;
  ended(reason: EndReason): void;
  /** The backend that receives input while the shown cards are current. */
  input(): LiveInput | undefined;
}

const json = (value: unknown, status = 200) => Response.json(value, { status, headers: { "Cache-Control": "no-store" } });
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);

/** A card for the page from a renderer image: bounded text, a PNG within the gallery limits, or why not. */
function frame(value: PreviewImage, index: number, total: number, keyboard: boolean): Frame {
  const card: Frame = { id: value.id, name: value.name.slice(0, 512), detail: value.detail.slice(0, 2048), live: !!value.live && !value.error, keyboard, size: 0 };
  if (value.error) card.error = value.error.slice(0, 8192);
  if (index >= MAX_CARDS) {
    card.error = `Live galleries show at most ${MAX_CARDS} cards. Reduce multipreview or @PreviewParameter expansion.`;
    card.live = false;
    return card;
  }
  if (!value.data) {
    card.error ??= "The live renderer returned no frame.";
    card.live = false;
    return card;
  }
  let problem: string | undefined;
  if (value.data.length > 4 * Math.ceil(MAX_PNG / 3)) problem = "Preview PNG exceeds 8 MiB.";
  else {
    const png = Buffer.from(value.data, "base64");
    if (png.length < 33 || !png.subarray(0, 8).equals(signature) || png.toString("ascii", 12, 16) !== "IHDR") problem = "Invalid preview PNG.";
    else {
      const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
      if (!width || !height || width > 4096 || height > 4096 || png.length > MAX_PNG || total + png.length > MAX_BYTES) problem = "Preview exceeds the gallery image limits.";
      else Object.assign(card, { data: value.data, width, height, size: png.length });
    }
  }
  if (problem) { card.error = problem; card.live = false; }
  return card;
}

/**
 * One loopback server per preview service. The control path (`/<control>/`) opens sessions for the
 * `open` client; each session's page, pane long-poll and document posts live under its own token
 * (`/<token>/`). The unguessable paths are the credentials.
 */
export function createPreviewServer(options: PreviewServerOptions): PreviewServer {
  const control = randomBytes(32).toString("hex");
  let token: string | undefined;
  const retired = new Map<string, EndReason>();
  let fileInfo = { name: "", path: "" };
  let socket: ServerWebSocket<undefined> | undefined;
  let epoch = 0;
  let disposed = false;
  let interactive = false;
  let focused: string | undefined;
  // The pressed card, and the backend that received its down: the up goes there even after the cards change.
  let pressed: { id: string; x: number; y: number; backend: LiveInput } | undefined;
  let wheel: { dx: number; dy: number; timer: NodeJS.Timeout } | undefined;
  let disconnect: NodeJS.Timeout | undefined;
  let lastStatus = { type: "status", phase: "starting", message: "" };
  let images = new Map<string, Frame>();
  const pending = new Set<string>();
  let flushTimer: NodeJS.Timeout | undefined;
  let flushedAt = -Infinity;
  // Pane actions of this session, and the long-polls waiting for one newer than `after`.
  let actions: { id: number; action: PaneAction; file?: string }[] = [];
  let polls = new Set<{ after: number; answer: (response: Response) => void }>();
  let polledAt = 0;

  const send = (value: unknown) => { if (socket) socket.send(JSON.stringify(value)); };
  const release = () => {
    if (wheel) { clearInterval(wheel.timer); wheel = undefined; }
    if (pressed) pressed.backend.pointer(pressed.id, "up", pressed.x, pressed.y);
    if (focused) (pressed?.backend ?? options.input())?.blur(focused);
    pressed = undefined;
    focused = undefined;
  };
  const reset = () => { release(); epoch++; send({ type: "reset", epoch }); };
  const invalidate = () => { release(); epoch++; interactive = false; send({ type: "invalidate", epoch }); };
  const status = (phase: string, message: string) => {
    if (phase === "error" && lastStatus.phase !== "error") reset();
    lastStatus = { type: "status", phase, message: message.slice(0, 8192) };
    send(lastStatus);
  };
  const gallery = () => {
    const values = [...images.values()];
    send({ type: "gallery", epoch, ids: values.map(card => card.id), live: values.filter(card => card.live).map(card => card.id), keyboard: values.filter(card => card.keyboard).map(card => card.id) });
  };
  const flush = () => {
    clearTimeout(flushTimer);
    flushTimer = undefined;
    if (!socket) return;
    flushedAt = performance.now();
    for (const id of pending) {
      if (socket.getBufferedAmount() > MAX_PNG) { flushTimer = setTimeout(flush, 16); return; }
      pending.delete(id);
      const card = images.get(id);
      if (!card) continue;
      const { live: _live, keyboard: _keyboard, size: _size, ...image } = card;
      send({ type: "image", epoch, image });
    }
  };
  const end = (reason: EndReason) => {
    if (!token) return;
    const ended = token;
    token = undefined;
    retired.set(ended, reason);
    for (const key of retired.keys()) if (retired.size > 8) retired.delete(key);
    release();
    clearTimeout(disconnect);
    disconnect = undefined;
    clearTimeout(flushTimer);
    flushTimer = undefined;
    pending.clear();
    interactive = false;
    const closing = socket;
    socket = undefined;
    closing?.close(1000, "Preview ended");
    const waiting = polls;
    polls = new Set();
    for (const poll of waiting) poll.answer(json({ ended: reason }, 410));
    options.ended(reason);
  };
  // Komodo's Android layoutlib host exposes touch, not generic mouse-wheel events.
  // Translate a wheel burst to a paced touch drag in the same running composition.
  const scroll = (backend: LiveInput, id: string, image: Frame, x: number, y: number, dx: number, dy: number) => {
    if (pressed && !wheel) return;
    if (wheel && pressed?.id === id) { wheel.dx += dx; wheel.dy += dy; return; }
    release();
    focused = id;
    pressed = { id, x, y, backend };
    backend.pointer(id, "down", x, y);
    const timer = setInterval(() => {
      if (!wheel || !pressed) return;
      const dx = wheel.dx * 0.5, dy = wheel.dy * 0.5;
      const x = Math.max(0, Math.min(image.width! - 1, pressed.x - dx));
      const y = Math.max(0, Math.min(image.height! - 1, pressed.y - dy));
      wheel.dx -= dx; wheel.dy -= dy;
      const boundary = x === pressed.x && y === pressed.y;
      pressed.x = x; pressed.y = y;
      pressed.backend.pointer(id, "move", x, y);
      if (boundary || Math.abs(wheel.dx) + Math.abs(wheel.dy) < 1) release();
    }, 16);
    wheel = { dx, dy, timer };
  };
  const body = async (request: Request): Promise<Record<string, unknown>> => {
    let value: unknown;
    try { value = await request.json(); } catch { throw new Error("Invalid JSON body."); }
    if (!object(value)) throw new Error("Invalid JSON body.");
    return value;
  };
  const documentsPost = (value: Record<string, unknown>): DocumentsPost => {
    if ((value.origin !== "host" && value.origin !== "native") || typeof value.replace !== "boolean" || !Array.isArray(value.documents)
      || (value.error !== undefined && typeof value.error !== "string")) throw new Error("Invalid editor documents.");
    const documents = value.documents.map(entry => {
      if (!object(entry) || typeof entry.file !== "string" || (entry.text !== null && typeof entry.text !== "string")) throw new Error("Invalid editor document.");
      return { file: entry.file, text: entry.text as string | null };
    });
    return { origin: value.origin, replace: value.replace, documents, ...(value.error === undefined ? {} : { error: value.error as string }) };
  };
  const route = async (request: Request, path: string, origin: string, port: number, upgrade: (request: Request) => boolean): Promise<Response | undefined> => {
    const [key, name = "", ...rest] = path.slice(1).split("/");
    if (rest.length || !key) return json({ error: "Not found" }, 404);
    const pageRoute = key === token && (name === "" || name === "client.js" || name === "events");
    if (!pageRoute && request.headers.has("origin")) return json({ error: "Forbidden" }, 403);
    if (key === control) {
      if (name === "ping" && request.method === "GET") return json({});
      if (name === "open" && request.method === "POST") {
        const value = await body(request);
        if (typeof value.file !== "string" || !Array.isArray(value.documents) || (value.keepAlive !== undefined && typeof value.keepAlive !== "number")) throw new Error("Invalid open request.");
        const documents = value.documents.map(entry => {
          if (!object(entry) || typeof entry.file !== "string" || typeof entry.text !== "string") throw new Error("Invalid editor document.");
          return { file: entry.file, text: entry.text };
        });
        return json(await options.open({ file: value.file, documents, ...(value.keepAlive === undefined ? {} : { keepAlive: value.keepAlive as number }) }));
      }
      return json({ error: "Not found" }, 404);
    }
    const ended = retired.get(key);
    if (ended) return json({ ended }, 410);
    if (key !== token) return json({ error: "Not found" }, 404);
    const method = name === "" || name === "client.js" || name === "events" || name === "info" || name === "pane" ? "GET" : "POST";
    if (request.method !== method) return json({ error: "Method not allowed" }, 405);
    switch (name) {
      case "events":
        if (request.headers.get("origin") !== origin || disposed) return new Response("Forbidden", { status: 403 });
        if (socket) return new Response("Preview already connected", { status: 409 });
        if (upgrade(request)) return undefined;
        return new Response("WebSocket required", { status: 400 });
      case "":
      case "client.js":
        return new Response(name === "" ? page : client, { headers: {
          "Content-Type": name === "client.js" ? "text/javascript; charset=utf-8" : "text/html; charset=utf-8",
          "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
          "Content-Security-Policy": `default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data:; connect-src ${origin} ws://127.0.0.1:${port}; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`,
        } });
      case "info":
        return json(options.info());
      case "pane": {
        const after = Number(new URL(request.url).searchParams.get("after") ?? "0");
        if (!Number.isSafeInteger(after) || after < 0) throw new Error("Invalid pane poll.");
        const action = actions.find(entry => entry.id > after);
        polledAt = Date.now();
        if (action) return json(action);
        const { promise, resolve } = Promise.withResolvers<Response>();
        const poll = { after, answer: (response: Response) => { clearTimeout(timer); request.signal.removeEventListener("abort", abort); resolve(response); } };
        const timer = setTimeout(() => { polls.delete(poll); polledAt = Date.now(); poll.answer(json({})); }, POLL_MS);
        const abort = () => { polls.delete(poll); polledAt = Date.now(); clearTimeout(timer); resolve(json({})); };
        request.signal.addEventListener("abort", abort, { once: true });
        polls.add(poll);
        return promise;
      }
      case "documents":
        await options.documents(documentsPost(await body(request)));
        return json({});
      case "retarget": {
        const value = await body(request);
        if (typeof value.file !== "string") throw new Error("Invalid retarget request.");
        await options.retarget(value.file);
        return json({});
      }
      case "close":
        end("closed");
        return json({});
      case "stop":
        options.stop();
        return json({});
    }
    return json({ error: "Not found" }, 404);
  };

  const server = Bun.serve<undefined>({
    hostname: "127.0.0.1", port: 0,
    idleTimeout: 30,
    maxRequestBodySize: 40 * 1024 * 1024,
    async fetch(request, server) {
      const url = new URL(request.url);
      if (request.headers.get("host") !== `127.0.0.1:${server.port}` || disposed) return json({ error: "Not found" }, 404);
      try {
        return await route(request, url.pathname, `http://127.0.0.1:${server.port}`, server.port!, request => server.upgrade(request, { data: undefined }));
      } catch (error) {
        return json({ error: error instanceof Error ? error.message : String(error) }, 400);
      }
    },
    websocket: {
      maxPayloadLength: 16 * 1024,
      idleTimeout: 30,
      sendPings: true,
      open(ws) {
        if (disposed || socket || !token) { ws.close(1008, "Preview already connected"); return; }
        clearTimeout(disconnect);
        disconnect = undefined;
        socket = ws;
        reset();
        send({ type: "file", ...fileInfo });
        if (interactive && options.input()) gallery();
        else send({ type: "invalidate", epoch });
        send(lastStatus);
        for (const id of images.keys()) pending.add(id);
        flush();
      },
      close(ws) {
        if (socket !== ws) return;
        release();
        socket = undefined;
        // A page reload may reconnect; a closed page ends the session.
        if (!disposed && token) disconnect = setTimeout(() => end("page-closed"), PAGE_GRACE_MS);
      },
      message(ws, payload) {
        if (ws !== socket || disposed || typeof payload !== "string") return;
        let value: Record<string, any>;
        try { value = JSON.parse(payload); } catch { ws.close(1008, "Invalid input"); return; }
        if (!value || typeof value !== "object" || value.epoch !== epoch) return;
        if (value.type === "stop") { reset(); options.stop(); return; }
        if (value.type === "request" && (value.action === "source" || value.action === "close")) { reset(); pane(value.action); return; }
        if (value.type === "refresh") { reset(); options.refresh(); return; }
        const backend = options.input();
        if (!backend || !interactive || typeof value.id !== "string") return;
        const image = images.get(value.id);
        if (!image?.live || !image.data) return;
        if (value.type === "blur") {
          if (focused === value.id || pressed?.id === value.id) release();
        } else if (value.type === "pointer" && ["down", "up", "move", "scroll"].includes(value.action)
          && Number.isFinite(value.x) && Number.isFinite(value.y) && value.x >= 0 && value.y >= 0 && value.x < image.width! && value.y < image.height!) {
          if (value.action === "scroll" && (!Number.isFinite(value.dx) || !Number.isFinite(value.dy) || Math.abs(value.dx) > 100000 || Math.abs(value.dy) > 100000)) return;
          if (value.action === "scroll") { scroll(backend, value.id, image, value.x, value.y, value.dx, value.dy); return; }
          if (wheel && value.action === "move") return;
          if (value.action === "down") { release(); focused = value.id; pressed = { id: value.id, x: value.x, y: value.y, backend }; }
          if ((value.action === "up" || value.action === "move") && pressed?.id !== value.id) return;
          pressed!.x = value.x; pressed!.y = value.y;
          pressed!.backend.pointer(value.id, value.action, value.x, value.y);
          if (value.action === "up") pressed = undefined;
        } else if (value.type === "keyboard" && image.keyboard && isPreviewKeyEvent(value.event)) {
          if (focused !== value.id) { release(); focused = value.id; }
          backend.keyboard(value.id, value.event);
        }
      },
    },
  });

  const pane = (action: PaneAction, file?: string) => {
    if (!token) return;
    const queued = { id: (actions.at(-1)?.id ?? 0) + 1, action, ...(file === undefined ? {} : { file }) };
    actions.push(queued);
    if (actions.length > 16) actions = actions.slice(-16);
    for (const poll of polls) {
      if (queued.id <= poll.after) continue;
      polls.delete(poll);
      polledAt = Date.now();
      poll.answer(json(queued));
    }
  };
  // A session whose pane stopped polling (closed, or Tern quit) and whose page is gone ends.
  const liveness = setInterval(() => {
    if (token && !polls.size && !socket && Date.now() - polledAt > ABANDON_MS) end("abandoned");
  }, 1000);
  const dispose = async () => {
    if (disposed) return;
    end("stopped");
    disposed = true;
    clearInterval(liveness);
    options.signal.removeEventListener("abort", abort);
    // Let the answers already written (the stop request's own) reach their clients.
    await Promise.race([server.stop(), Bun.sleep(1000)]);
    await server.stop(true);
  };
  const abort = () => { void dispose(); };
  options.signal.addEventListener("abort", abort, { once: true });
  if (options.signal.aborted) abort();

  return {
    get port() { return server.port!; },
    control,
    get connected() { return !!socket; },
    begin(file) {
      end("retargeted");
      token = randomBytes(32).toString("hex");
      fileInfo = { ...file };
      actions = [];
      polledAt = Date.now();
      images = new Map();
      pending.clear();
      interactive = false;
      lastStatus = { type: "status", phase: "starting", message: "" };
      return `http://127.0.0.1:${server.port}/${token}/`;
    },
    end,
    file(file) { fileInfo = { ...file }; send({ type: "file", ...fileInfo }); },
    pane,
    status,
    invalidate,
    show(values, keyboard) {
      const previous = images;
      images = new Map();
      let total = 0;
      for (const [index, value] of values.entries()) {
        if (images.has(value.id)) continue;
        const card = frame(value, index, total, keyboard(value.id));
        total += card.size;
        images.set(card.id, card);
        const old = previous.get(card.id);
        if (!old || old.data !== card.data || old.error !== card.error || old.name !== card.name || old.detail !== card.detail) pending.add(card.id);
      }
      for (const id of pending) if (!images.has(id)) pending.delete(id);
      interactive = true;
      if ((focused && !images.get(focused)?.live) || (pressed && !images.get(pressed.id)?.live)) release();
      gallery();
      flush();
    },
    push(values, keyboard) {
      let changed = false;
      for (const value of values) {
        const previous = images.get(value.id);
        if (!previous) continue;
        const index = [...images.keys()].indexOf(value.id);
        let total = 0;
        for (const card of images.values()) total += card.size;
        const card = frame(value, index, total - previous.size, keyboard(value.id));
        images.set(card.id, card);
        pending.add(card.id);
        changed = true;
      }
      if (!changed || flushTimer) return;
      const wait = flushedAt + PUSH_INTERVAL_MS - performance.now();
      if (wait <= 0) flush();
      else flushTimer = setTimeout(flush, wait);
    },
    reset,
    dispose,
  };
}
