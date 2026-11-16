import { randomBytes } from "node:crypto";
import type { ServerWebSocket } from "bun";
import { isPreviewKeyEvent } from "@elide/compose-backend";
import type { PreviewImage } from "@elide/compose-render";
import type { LivePreview } from "./live";
import page from "./preview.html" with { type: "text" };
import client from "./client.js" with { type: "text" };

const MAX_PNG = 8 * 1024 * 1024;
const MAX_BYTES = 32 * 1024 * 1024;
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
type Frame = { id: string; name: string; detail: string; data?: string; error?: string; width?: number; height?: number; live?: boolean; keyboard: boolean };
export interface LiveServer {
  url: string;
  attach(value: LivePreview): void;
  status(phase: string, message: string): void;
  reset(): void;
  dispose(): void;
  publish(values: readonly PreviewImage[], replace?: boolean): void;
}

/** One loopback page controls one live composition session. The unguessable path is its credential. */
export function createLiveServer(options: { signal: AbortSignal; refresh: () => Promise<void>; stop: () => void }): LiveServer {
  const token = randomBytes(32).toString("hex");
  const prefix = `/${token}/`;
  let backend: LivePreview | undefined;
  let socket: ServerWebSocket<undefined> | undefined;
  let epoch = 0;
  let disposed = false;
  let refreshing = false;
  let focused: string | undefined;
  let pressed: { id: string; x: number; y: number } | undefined;
  let wheel: { dx: number; dy: number; timer: NodeJS.Timeout } | undefined;
  let disconnect: NodeJS.Timeout | undefined;
  let lastStatus = { type: "status", phase: "starting", message: "Starting live Compose previews…" };
  const images = new Map<string, Frame>();
  const sizes = new Map<string, number>();
  const pending = new Set<string>();
  const send = (value: unknown) => { if (socket) socket.send(JSON.stringify(value)); };
  const release = () => {
    if (wheel) { clearInterval(wheel.timer); wheel = undefined; }
    if (pressed) backend?.pointer(pressed.id, "up", pressed.x, pressed.y);
    if (focused) backend?.blur(focused);
    pressed = undefined;
    focused = undefined;
  };
  const reset = () => { release(); epoch++; send({ type: "reset", epoch }); };
  const status = (phase: string, message: string) => {
    if (phase === "error" && lastStatus.phase !== "error") reset();
    lastStatus = { type: "status", phase, message: message.slice(0, 8192) };
    send(lastStatus);
  };
  // Komodo's Android layoutlib host exposes touch, not generic mouse-wheel events.
  // Translate a wheel burst to a paced touch drag in the same running composition.
  const scroll = (id: string, image: Frame, x: number, y: number, dx: number, dy: number) => {
    if (pressed && !wheel) return;
    if (wheel && pressed?.id === id) { wheel.dx += dx; wheel.dy += dy; return; }
    release();
    focused = id;
    pressed = { id, x, y };
    backend!.pointer(id, "down", x, y);
    const timer = setInterval(() => {
      if (!wheel || !pressed) return;
      const dx = wheel.dx * 0.5, dy = wheel.dy * 0.5;
      const x = Math.max(0, Math.min(image.width! - 1, pressed.x - dx));
      const y = Math.max(0, Math.min(image.height! - 1, pressed.y - dy));
      wheel.dx -= dx; wheel.dy -= dy;
      const boundary = x === pressed.x && y === pressed.y;
      pressed.x = x; pressed.y = y;
      backend!.pointer(id, "move", x, y);
      if (boundary || Math.abs(wheel.dx) + Math.abs(wheel.dy) < 1) release();
    }, 16);
    wheel = { dx, dy, timer };
  };
  const server = Bun.serve<undefined>({
    hostname: "127.0.0.1", port: 0,
    maxRequestBodySize: 16 * 1024,
    fetch(request, server) {
      const url = new URL(request.url);
      const origin = `http://127.0.0.1:${server.port}`;
      if (request.headers.get("host") !== `127.0.0.1:${server.port}` || !url.pathname.startsWith(prefix)) return new Response("Not found", { status: 404 });
      if (request.method !== "GET") return new Response("Method not allowed", { status: 405 });
      const route = url.pathname.slice(prefix.length);
      if (route === "events") {
        if (request.headers.get("origin") !== origin || disposed) return new Response("Forbidden", { status: 403 });
        if (socket) return new Response("Preview already connected", { status: 409 });
        if (server.upgrade(request, { data: undefined })) return;
        return new Response("WebSocket required", { status: 400 });
      }
      const headers = {
        "Content-Type": route === "client.js" ? "text/javascript; charset=utf-8" : "text/html; charset=utf-8",
        "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": `default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data:; connect-src ${origin} ws://127.0.0.1:${server.port}; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`,
      };
      if (route === "") return new Response(page, { headers });
      if (route === "client.js") return new Response(client, { headers });
      return new Response("Not found", { status: 404 });
    },
    websocket: {
      maxPayloadLength: 16 * 1024,
      idleTimeout: 30,
      sendPings: true,
      open(ws) {
        if (disposed || socket) { ws.close(1008, "Preview already connected"); return; }
        clearTimeout(disconnect);
        socket = ws;
        reset();
        send({ type: "gallery", epoch, ids: [...images.keys()] });
        send(lastStatus);
        for (const id of images.keys()) pending.add(id);
      },
      close(ws) {
        if (socket !== ws) return;
        release(); socket = undefined;
        // A page reload may reconnect; a closed page must not leave a compiler running.
        if (!disposed) disconnect = setTimeout(options.stop, 5000);
      },
      message(ws, payload) {
        if (ws !== socket || disposed || typeof payload !== "string") return;
        let value: Record<string, any>;
        try { value = JSON.parse(payload); } catch { ws.close(1008, "Invalid input"); return; }
        if (!value || typeof value !== "object" || value.epoch !== epoch) return;
        if (value.type === "stop") { reset(); options.stop(); return; }
        if (value.type === "refresh") {
          if (refreshing || !backend) return;
          refreshing = true; reset();
          void options.refresh().catch(error => status("error", String(error))).finally(() => { refreshing = false; });
          return;
        }
        if (!backend || refreshing || lastStatus.phase !== "live" || typeof value.id !== "string") return;
        const image = images.get(value.id);
        if (!image?.live || image.error) return;
        if (value.type === "blur") {
          if (focused === value.id || pressed?.id === value.id) release();
        } else if (value.type === "pointer" && ["down", "up", "move", "scroll"].includes(value.action)
          && Number.isFinite(value.x) && Number.isFinite(value.y) && value.x >= 0 && value.y >= 0 && value.x < image.width! && value.y < image.height!) {
          if (value.action === "scroll" && (!Number.isFinite(value.dx) || !Number.isFinite(value.dy) || Math.abs(value.dx) > 100000 || Math.abs(value.dy) > 100000)) return;
          if (value.action === "scroll") { scroll(value.id, image, value.x, value.y, value.dx, value.dy); return; }
          if (wheel && value.action === "move") return;
          if (value.action === "down") { release(); focused = value.id; pressed = { id: value.id, x: value.x, y: value.y }; }
          if (value.action === "up" && pressed?.id !== value.id) return;
          if (pressed?.id === value.id) { pressed.x = value.x; pressed.y = value.y; }
          backend.pointer(value.id, value.action, value.x, value.y, value.dx, value.dy);
          if (value.action === "up") pressed = undefined;
        } else if (value.type === "keyboard" && image.keyboard && isPreviewKeyEvent(value.event)) {
          if (focused !== value.id) { release(); focused = value.id; }
          backend.keyboard(value.id, value.event);
        }
      },
    },
  });
  const ticker = setInterval(() => {
    if (!socket) return;
    for (const id of pending) {
      if (socket.getBufferedAmount() > MAX_PNG) break;
      send({ type: "image", epoch, image: images.get(id) });
      pending.delete(id);
    }
  }, 50);
  const dispose = () => {
    if (disposed) return;
    disposed = true; release(); clearInterval(ticker); clearTimeout(disconnect);
    socket?.close(1000, "Preview stopped"); socket = undefined;
    server.stop(true);
    options.signal.removeEventListener("abort", dispose);
  };
  options.signal.addEventListener("abort", dispose, { once: true });
  if (options.signal.aborted) dispose();
  return {
    url: `http://127.0.0.1:${server.port}${prefix}`,
    attach(value: LivePreview) { backend = value; },
    status, reset, dispose,
    publish(values: readonly PreviewImage[], replace = false) {
      if (disposed) return;
      if (replace) { reset(); images.clear(); sizes.clear(); pending.clear(); }
      let total = [...sizes.values()].reduce((sum, size) => sum + size, 0);
      for (const value of values) {
        if (!images.has(value.id) && images.size >= 32) { status("error", "Live galleries support at most 32 cards. Reduce preview expansion."); break; }
        const frame: Frame = { id: value.id, name: value.name.slice(0, 512), detail: value.detail.slice(0, 2048), keyboard: backend?.keyboardSupported(value.id) ?? false, live: value.live && lastStatus.phase === "live", error: value.error?.slice(0, 8192) };
        total -= sizes.get(value.id) ?? 0;
        sizes.delete(value.id);
        if (!frame.error && value.data) {
          if (value.data.length > 4 * Math.ceil(MAX_PNG / 3)) frame.error = "Preview PNG exceeds 8 MiB.";
          else {
            const png = Buffer.from(value.data, "base64");
            if (png.length < 33 || !png.subarray(0, 8).equals(signature) || png.toString("ascii", 12, 16) !== "IHDR") frame.error = "Invalid preview PNG.";
            else {
              const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
              if (!width || !height || width > 4096 || height > 4096 || png.length > MAX_PNG || total + png.length > MAX_BYTES) frame.error = "Preview exceeds the gallery image limits.";
              else { Object.assign(frame, { data: value.data, width, height }); sizes.set(value.id, png.length); total += png.length; }
            }
          }
        } else if (!frame.error) frame.error = "The live renderer returned no frame.";
        images.set(value.id, frame); pending.add(value.id);
      }
      if (replace) send({ type: "gallery", epoch, ids: [...images.keys()] });
    },
  };
}
