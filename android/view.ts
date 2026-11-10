import { execFile } from "node:child_process";
import { chmod, lstat, readFile, rename, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import type { ServerWebSocket } from "bun";
import { randomBytes } from "node:crypto";
import page from "./view.html" with { type: "text" };
import client from "./client.js" with { type: "text" };

const exec = promisify(execFile);
const MAX_PNG = 8 * 1024 * 1024;
const PNG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const KEYS: Record<string, true> = {
  BACK: true, HOME: true, APP_SWITCH: true, POWER: true, VOLUME_UP: true, VOLUME_DOWN: true,
  ENTER: true, DEL: true, FORWARD_DEL: true, TAB: true, DPAD_UP: true, DPAD_DOWN: true,
  DPAD_LEFT: true, DPAD_RIGHT: true, MOVE_HOME: true, MOVE_END: true, PAGE_UP: true, PAGE_DOWN: true,
};
/** ADB's remote shell still parses arguments; only quoted text and validated numbers reach it. */
function quote(value: string): string { return `'${value.replaceAll("'", `'\\''`)}'`; }

/** One browser connection controls one explicitly selected emulator. It never owns the emulator lifetime. */
export async function runView(options: { adb: string; serial: string; job?: string }): Promise<void> {
  if (!/^emulator-\d+$/.test(options.serial)) throw new Error("Mirror requires an emulator serial.");
  const controller = new AbortController();
  const run = async (args: string[], binary = false) => exec(options.adb, ["-s", options.serial, ...args], {
    encoding: binary ? "buffer" : "utf8", maxBuffer: MAX_PNG, timeout: 15000, signal: controller.signal,
  });
  // Resolve connectivity before publishing a usable URL. Never wait indefinitely for a device.
  const connected = await run(["get-state"]);
  if (String(connected.stdout).trim() !== "device") throw new Error("The emulator is not ready. Wait for boot and retry View.");
  if (options.job) {
    if (!path.isAbsolute(options.job)) throw new Error("--job must be an absolute directory.");
    const info = await lstat(options.job);
    if (!info.isDirectory() || info.isSymbolicLink() || (process.getuid && info.uid !== process.getuid())) throw new Error("Mirror job must be an owned directory, not a symlink.");
    await chmod(options.job, 0o700);
    const lease = await stat(path.join(options.job, "lease"));
    if (Date.now() - lease.mtimeMs > 15000) throw new Error("Mirror lease expired before startup.");
  }
  let socket: ServerWebSocket<undefined> | undefined;
  let width = 0, height = 0;
  let capturing = false, awaitingFrame = false, visible = true, stopped = false;
  let queued = 0, generation = 0;
  let activeUntil = 0;
  let input = Promise.resolve();
  let disconnect: NodeJS.Timeout | undefined;
  const { promise: finished, resolve: done } = Promise.withResolvers<void>();
  const token = randomBytes(32).toString("hex");
  const prefix = `/${token}/`;
  const send = (value: unknown) => socket?.send(JSON.stringify(value));
  const stop = () => {
    if (stopped) return;
    stopped = true;
    generation++;
    controller.abort();
    clearTimeout(disconnect);
    socket?.close(1000, "Mirror closed");
    socket = undefined;
    done();
  };
  const enqueue = (command: string) => {
    if (queued >= 8) { send({ type: "status", error: true, message: "Input busy; wait for the device before trying again." }); return; }
    const current = generation;
    queued++;
    input = input.then(async () => {
      if (stopped || current !== generation || !socket) return;
      await run(["shell", command]);
      // Driven Tern pages can report hidden even while native input is delivered.
      // Refresh the result of that input without continuously polling a hidden page.
      activeUntil = Date.now() + 2000;
      send({ type: "status", error: false, message: "Connected · ADB mirror" });
    }).catch(error => { if (!stopped) send({ type: "status", error: true, message: String(error).slice(0, 2048) }); })
      .finally(() => { queued--; });
  };
  const position = (x: unknown, y: unknown) => Number.isInteger(x) && Number.isInteger(y)
    && (x as number) >= 0 && (y as number) >= 0 && (x as number) < width && (y as number) < height;
  const server = Bun.serve<undefined>({
    hostname: "127.0.0.1", port: 0, maxRequestBodySize: 4096,
    fetch(request, server) {
      const url = new URL(request.url);
      const host = `127.0.0.1:${server.port}`;
      if (request.headers.get("host") !== host || !url.pathname.startsWith(prefix)) return new Response("Not found", { status: 404 });
      if (request.method !== "GET") return new Response("Method not allowed", { status: 405 });
      const route = url.pathname.slice(prefix.length);
      if (route === "events") {
        if (request.headers.get("origin") !== `http://${host}` || stopped) return new Response("Forbidden", { status: 403 });
        if (socket) return new Response("Mirror already connected", { status: 409 });
        if (server.upgrade(request, { data: undefined })) return;
        return new Response("WebSocket required", { status: 400 });
      }
      const headers = {
        "Content-Type": route === "client.js" ? "text/javascript; charset=utf-8" : "text/html; charset=utf-8",
        "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": `default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src blob:; connect-src ws://${host}; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`,
      };
      if (route === "") return new Response(page, { headers });
      if (route === "client.js") return new Response(client, { headers });
      return new Response("Not found", { status: 404 });
    },
    websocket: {
      maxPayloadLength: 4096, idleTimeout: 30, sendPings: true,
      open(ws) {
        if (socket || stopped) { ws.close(1008, "Mirror already connected"); return; }
        clearTimeout(disconnect);
        socket = ws; generation++; awaitingFrame = false; visible = true;
        send({ type: "status", error: false, message: `Connected to ${options.serial} · ADB mirror` });
      },
      close(ws) {
        if (ws !== socket) return;
        socket = undefined; generation++;
        // Page reloads may reconnect; closing a browser must not leak the helper.
        disconnect = setTimeout(stop, 5000);
      },
      message(ws, payload) {
        if (ws !== socket || stopped || typeof payload !== "string") return;
        let value: Record<string, unknown>;
        try { value = JSON.parse(payload); } catch { ws.close(1008, "Invalid input"); return; }
        if (!value || typeof value !== "object") return;
        if (value.type === "ack") { awaitingFrame = false; return; }
        if (value.type === "visibility" && typeof value.visible === "boolean") { visible = value.visible; if (!visible) generation++; return; }
        if (value.type === "close") { stop(); return; }
        if (!width || !height) return;
        if (value.type === "key" && typeof value.key === "string" && Object.hasOwn(KEYS, value.key)) {
          enqueue(`input keyevent KEYCODE_${value.key}`);
        } else if (value.type === "text" && typeof value.text === "string") {
          if (!/^[\x20-\x7e]{1,128}$/.test(value.text)) { send({ type: "status", error: true, message: "ADB text input supports 1–128 printable ASCII characters; use the device keyboard for other text." }); return; }
          // input text treats %s as a space. Sending '%' separately preserves literal %s.
          const pieces = value.text.split(/(%)/).filter(Boolean);
          enqueue(pieces.map(piece => `input text ${quote(piece.replaceAll(" ", "%s"))}`).join(" && "));
        } else if (value.type === "gesture" && value.width === width && value.height === height
          && position(value.x, value.y) && position(value.endX, value.endY)
          && Number.isInteger(value.duration) && (value.duration as number) >= 0 && (value.duration as number) <= 1500) {
          if (value.x === value.endX && value.y === value.endY && (value.duration as number) < 400) enqueue(`input tap ${value.x} ${value.y}`);
          else enqueue(`input swipe ${value.x} ${value.y} ${value.endX} ${value.endY} ${Math.max(100, value.duration as number)}`);
        }
      },
    },
  });
  const capture = async () => {
    if (!socket || (!visible && width > 0 && Date.now() > activeUntil) || capturing || awaitingFrame || socket.getBufferedAmount() > MAX_PNG || stopped) return;
    capturing = true;
    const target = socket;
    try {
      const result = await run(["exec-out", "screencap", "-p"], true);
      const png = result.stdout;
      if (!Buffer.isBuffer(png) || png.length < 33 || !png.subarray(0, 8).equals(PNG) || png.toString("ascii", 12, 16) !== "IHDR") throw new Error("ADB did not return a PNG screenshot.");
      const w = png.readUInt32BE(16), h = png.readUInt32BE(20);
      if (!w || !h || w > 8192 || h > 8192) throw new Error("Emulator screenshot dimensions exceed mirror limits.");
      if (socket === target && !stopped) {
        width = w; height = h; awaitingFrame = true;
        socket.send(png);
      }
    } catch (error) {
      if (!stopped && socket === target) {
        send({ type: "status", error: true, message: `Screenshot failed: ${String(error).slice(0, 2048)}. Reopen View when the device is ready.` });
        stop();
      }
    } finally { capturing = false; }
  };
  const ticker = setInterval(() => { void capture(); }, 400);
  let watching = false;
  const lease = options.job ? setInterval(async () => {
    if (watching || stopped) return;
    watching = true;
    try {
      const cancelled = await readFile(path.join(options.job!, "cancel")).then(() => true, error => { if (error.code === "ENOENT") return false; throw error; });
      if (cancelled || Date.now() - (await stat(path.join(options.job!, "lease"))).mtimeMs > 15000) stop();
    } catch { stop(); }
    finally { watching = false; }
  }, 1000) : undefined;
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  disconnect = setTimeout(stop, 60000);
  try {
    const result = JSON.stringify({ url: `http://127.0.0.1:${server.port}${prefix}`, serial: options.serial });
    if (options.job) {
      const temporary = path.join(options.job, "view.json.tmp");
      await writeFile(temporary, result, { mode: 0o600, flag: "wx" });
      await rename(temporary, path.join(options.job, "view.json"));
    } else console.log(result);
    await finished;
  } finally {
    stop(); clearInterval(ticker); clearInterval(lease);
    process.removeListener("SIGINT", stop); process.removeListener("SIGTERM", stop);
    server.stop(true);
    await input;
  }
}
