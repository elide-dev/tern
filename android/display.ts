import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { EmulatorClient, Proto, bytes, decode, nested, number, type Endpoint, type Fields } from "./grpc";

/**
 * Renders one emulator inside the terminal it runs in: frames arrive over the emulator's gRPC
 * screenshot stream and are drawn with the kitty graphics protocol; SGR pixel mouse reports
 * become touches and kitty keyboard reports become key events. The emulator outlives the view.
 */

const ESC = "\x1b";
const FRAME_ID = 1;
const QUERY_ID = 31;
const TOOLBAR = [
  { label: "Back", act: "back" }, { label: "Home", act: "home" }, { label: "Recents", act: "recents" },
  { label: "Power", act: "power" }, { label: "Vol−", act: "volume-down" }, { label: "Vol+", act: "volume-up" },
  { label: "⟲", act: "rotate-left" }, { label: "⟳", act: "rotate-right" }, { label: "Close", act: "close" },
] as const;
type Action = (typeof TOOLBAR)[number]["act"];
const HARDWARE: Partial<Record<Action, string>> = {
  back: "GoBack", home: "GoHome", recents: "AppSwitch", power: "Power", "volume-down": "AudioVolumeDown", "volume-up": "AudioVolumeUp",
};
/** Image rotation (Rotation.SkinRotation) to the physical-model z angle the emulator window uses. */
const ANGLES = [0, 90, 180, -90];

/** W3C key names for kitty functional key codes and legacy CSI finals. */
const KITTY_KEYS: Record<number, string> = {
  9: "Tab", 13: "Enter", 27: "Escape", 127: "Backspace",
  57399: "0", 57400: "1", 57401: "2", 57402: "3", 57403: "4", 57404: "5", 57405: "6", 57406: "7", 57407: "8", 57408: "9",
  57409: ".", 57410: "/", 57411: "*", 57412: "-", 57413: "+", 57414: "Enter", 57415: "=",
};
const TILDE_KEYS: Record<number, string> = {
  2: "Insert", 3: "Delete", 5: "PageUp", 6: "PageDown", 7: "Home", 8: "End",
  11: "F1", 12: "F2", 13: "F3", 14: "F4", 15: "F5", 17: "F6", 18: "F7", 19: "F8", 20: "F9", 21: "F10", 23: "F11", 24: "F12",
};
const LETTER_KEYS: Record<string, string> = {
  A: "ArrowUp", B: "ArrowDown", C: "ArrowRight", D: "ArrowLeft", H: "Home", F: "End", P: "F1", Q: "F2", S: "F4",
};
/** Lock and modifier keys: modifiers travel with the key they modify. */
const IGNORED = new Set([57358, 57359, 57360, 57361, 57362, 57363, 57441, 57442, 57443, 57444, 57445, 57446, 57447, 57448, 57449, 57450, 57451, 57452]);
const PRINTABLE = /^[\x20-\x7e]$/;

type Frame = { data: Buffer; width: number; height: number; rotation: number };
type Geometry = { cols: number; rows: number; cellWidth: number; cellHeight: number };

const keyEvent = (key: string, type: "down" | "up" | "press") =>
  new Proto().int(2, type === "down" ? 0 : type === "up" ? 1 : 2).string(4, key);
const textEvent = (text: string) => new Proto().int(2, 2).string(5, text);

export async function runDisplay(endpoint: Endpoint): Promise<void> {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error("display needs an interactive terminal with kitty graphics, such as a Tern pane.");
  const title = endpoint.name ?? endpoint.serial;
  const label = endpoint.name ? `${endpoint.name} · ${endpoint.serial}` : endpoint.serial;
  const out = (text: string) => { process.stdout.write(text); };
  const decoder = new TextDecoder();
  let pending = "";
  let flushTimer: Timer | undefined;
  let geometry: Geometry | undefined;
  let kitty = false, kittyKeyboard = false, pixelMouse = false;
  let answered: (() => void) | undefined;
  let fileTransport = true, framesShown = 0;
  let frame: Frame | undefined, drawn: Frame | undefined, inFlight = false, ackTimer: Timer | undefined;
  let cancelStream: (() => void) | undefined, streamSize = "";
  let touching: { x: number; y: number; pinch: boolean } | undefined;
  let message = `Connecting to ${title}…`;
  let stopping = false;
  const { promise: finished, resolve: finish } = Promise.withResolvers<string | undefined>();
  const directory = mkdtempSync(path.join(os.tmpdir(), "elide-tern-display-"));
  const framePath = path.join(directory, "frame.rgb");
  // The emulator writes the running device's hardware here; without hw.keyboard the guest has no
  // keyboard device and silently drops every key event, Back, Home and Power included.
  let hardware = "";
  try { if (endpoint.directory) hardware = readFileSync(path.join(endpoint.directory, "hardware-qemu.ini"), "utf8"); } catch {}
  const keyboard = !/^hw\.keyboard\s*=\s*(false|no)\s*$/m.test(hardware);

  const client = new EmulatorClient(endpoint, error => stop(error ? `Lost the emulator connection: ${error.message}` : undefined));
  let input: { send(message: Proto): void; end(): void } | undefined = client.publish("streamInputEvent", error => {
    // Emulators without the ordered input stream still take unary touch, mouse and key events.
    input = undefined;
    if (error && !stopping) status(`Input stream unavailable (${error.message}); using single events.`);
  });
  const send = (field: 1 | 2 | 3 | 6, event: Proto) => {
    if (field === 1 && !keyboard) {
      if (!stopping) status(`No keyboard input: set hw.keyboard = yes for ${title} and restart it.`);
      return;
    }
    if (input) { input.send(new Proto().message(field, event)); return; }
    const method = field === 1 ? "sendKey" : field === 2 ? "sendTouch" : field === 3 ? "sendMouse" : undefined;
    if (method) client.unary(method, event).catch(error => status(`Input failed: ${error.message}`));
  };

  function stop(reason?: string): void {
    if (stopping) return;
    stopping = true;
    finish(reason);
  }
  const alive = () => {
    try { process.kill(endpoint.pid, 0); return true; } catch { return false; }
  };

  // ── Terminal output ────────────────────────────────────────────────────────────
  const area = () => {
    const g = geometry!;
    return { width: g.cols * g.cellWidth, height: Math.max(1, g.rows - 1) * g.cellHeight };
  };
  /** The bottom row: hardware buttons, then the notice or the device label. */
  const toolbar = () => {
    const g = geometry!;
    const hits: { act: Action; from: number; to: number }[] = [];
    let line = "", column = 1;
    for (const button of TOOLBAR) {
      const text = ` ${button.label} `;
      if (column + text.length > g.cols + 1) break;
      hits.push({ act: button.act, from: column, to: column + text.length - 1 });
      line += `${ESC}[7m${text}${ESC}[0m `;
      column += text.length + 1;
    }
    const note = ` ${drawn && message ? message : label}`;
    const room = g.cols - column + 1;
    if (room > 4) line += `${ESC}[2m${note.length > room ? note.slice(0, room - 1) + "…" : note}${ESC}[0m`;
    out(`${ESC}7${ESC}[${g.rows};1H${ESC}[2K${line}${ESC}8`);
    buttons = hits;
  };
  let buttons: { act: Action; from: number; to: number }[] = [];
  /** Before the first frame the message is centered in the screen area; afterwards it joins the toolbar. */
  const status = (text: string) => {
    message = text;
    if (!geometry) return;
    if (drawn) { toolbar(); return; }
    const g = geometry;
    const row = Math.max(1, Math.floor((g.rows - 1) / 2));
    const clipped = text.length > g.cols ? text.slice(0, g.cols - 1) + "…" : text;
    out(`${ESC}7${ESC}[${row};1H${ESC}[2K${ESC}[${Math.max(1, Math.floor((g.cols - clipped.length) / 2) + 1)}G${clipped}${ESC}8`);
  };
  const redraw = () => {
    out(`${ESC}_Ga=d,d=A,q=2${ESC}\\${ESC}[2J`);
    drawn = undefined;
    toolbar();
    status(message);
  };

  const pump = () => {
    if (inFlight || !frame || !geometry || stopping) return;
    const next = frame;
    frame = undefined;
    const g = geometry, box = area();
    const left = Math.max(0, Math.floor((box.width - next.width) / 2)), top = Math.max(0, Math.floor((box.height - next.height) / 2));
    const place = `a=T,f=24,s=${next.width},v=${next.height},i=${FRAME_ID},p=1,C=1,X=${left % g.cellWidth},Y=${top % g.cellHeight}`;
    let command: string;
    if (fileTransport) {
      writeFileSync(framePath, next.data);
      command = `${ESC}_G${place},t=f;${Buffer.from(framePath).toString("base64")}${ESC}\\`;
    } else {
      const encoded = next.data.toString("base64");
      const chunks: string[] = [];
      for (let offset = 0; offset < encoded.length; offset += 4096) {
        const more = offset + 4096 < encoded.length ? 1 : 0;
        chunks.push(`${ESC}_G${offset ? "" : `${place},`}m=${more};${encoded.slice(offset, offset + 4096)}${ESC}\\`);
      }
      command = chunks.join("");
    }
    if (!drawn) { message = ""; out(`${ESC}[2J`); }
    out(`${ESC}7${ESC}[${Math.floor(top / g.cellHeight) + 1};${Math.floor(left / g.cellWidth) + 1}H${command}${ESC}8`);
    const first = !drawn;
    drawn = next;
    if (first) toolbar();
    inFlight = true;
    // The terminal acknowledges each transmission; a silent one must not freeze the view.
    ackTimer = setTimeout(() => { inFlight = false; pump(); }, 1000);
  };
  const acknowledged = (ok: boolean, detail: string) => {
    clearTimeout(ackTimer);
    inFlight = false;
    if (ok) framesShown++;
    else if (fileTransport && !framesShown) {
      // A remote terminal cannot read local files; send pixels inline instead.
      fileTransport = false;
      frame ??= drawn;
      drawn = undefined;
    } else status(`Terminal rejected a frame: ${detail}`);
    pump();
  };

  // ── Emulator frames ────────────────────────────────────────────────────────────
  const subscribe = () => {
    if (!geometry || stopping) return;
    const box = area();
    const size = `${box.width}x${box.height}`;
    if (size === streamSize) return;
    streamSize = size;
    cancelStream?.();
    // RGB888 at the pane's pixel size: the emulator scales, keeping the device aspect ratio.
    cancelStream = client.subscribe("streamScreenshot", new Proto().int(1, 2).int(3, box.width).int(4, box.height), (image: Fields) => {
      const format = nested(image, 1);
      const width = number(format, 3), height = number(format, 4), data = bytes(image, 4);
      if (!width || !height) { frame = undefined; if (drawn) redraw(); status(`${title}: display is off. Press Power to wake it.`); return; }
      if (data.length !== width * height * 3) return;
      frame = { data, width, height, rotation: number(nested(format, 2), 1) };
      pump();
    }, error => stop(error ? `Screen stream ended: ${error.message}` : undefined));
  };

  // ── Input ──────────────────────────────────────────────────────────────────────
  /**
   * Maps a pane pixel to the device's native (portrait) coordinates; points outside the screen are
   * undefined unless `clamp`, which keeps a drag that leaves the screen on its edge.
   */
  const devicePoint = (px: number, py: number, clamp = false) => {
    if (!drawn || !geometry || !native.width) return undefined;
    const box = area();
    const left = Math.max(0, Math.floor((box.width - drawn.width) / 2)), top = Math.max(0, Math.floor((box.height - drawn.height) / 2));
    let u = (px - left) / drawn.width, v = (py - top) / drawn.height;
    if (!clamp && (u < 0 || v < 0 || u >= 1 || v >= 1)) return undefined;
    u = Math.min(1, Math.max(0, u)); v = Math.min(1, Math.max(0, v));
    const { width: w, height: h } = native;
    const r = drawn.rotation;
    // Frames are rotated into the skin orientation; touches stay in the native display space.
    const ix = u * (r % 2 ? h : w), iy = v * (r % 2 ? w : h);
    const [x, y] = r === 1 ? [w - iy, ix] : r === 2 ? [w - ix, h - iy] : r === 3 ? [iy, h - ix] : [ix, iy];
    return { x: Math.min(w - 1, Math.max(0, Math.round(x))), y: Math.min(h - 1, Math.max(0, Math.round(y))) };
  };
  let native = { width: 0, height: 0 };
  const touch = (x: number, y: number, pressure: number, pinch: boolean) => {
    const event = new Proto().message(1, new Proto().int(1, x).int(2, y).int(3, 1).int(4, pressure).int(7, 1));
    if (pinch) event.message(1, new Proto().int(1, native.width - 1 - x).int(2, native.height - 1 - y).int(3, 2).int(4, pressure).int(7, 1));
    send(2, event);
  };
  const releaseTouch = () => {
    if (touching) { touch(touching.x, touching.y, 0, touching.pinch); touching = undefined; }
  };
  const toolbarAction = (act: Action) => {
    if (act === "close") { stop(); return; }
    const key = HARDWARE[act];
    if (key) { send(1, keyEvent(key, "press")); return; }
    const angle = ANGLES[drawn?.rotation ?? 0]! + (act === "rotate-left" ? 90 : -90);
    const z = angle > 180 ? angle - 360 : angle <= -180 ? angle + 360 : angle;
    client.unary("setPhysicalModel", new Proto().int(1, 1).message(3, new Proto().floats(1, [0, 0, z])))
      .catch(error => status(`Rotation failed: ${error.message}`));
  };
  const mouse = (code: number, x: number, y: number, release: boolean) => {
    const g = geometry;
    if (!g) return;
    // Cell reports (no 1016) address the cell's center.
    const px = pixelMouse ? x - 1 : (x - 0.5) * g.cellWidth, py = pixelMouse ? y - 1 : (y - 0.5) * g.cellHeight;
    const button = code & 3, motion = (code & 32) !== 0, alt = (code & 8) !== 0;
    if (code & 64) {
      // Android scrolls under its mouse pointer, so move it there first. 120 = one wheel notch.
      const at = devicePoint(px, py);
      if (!at) return;
      send(3, new Proto().int(1, at.x).int(2, at.y));
      const [dx, dy] = button === 0 ? [0, 120] : button === 1 ? [0, -120] : button === 2 ? [120, 0] : [-120, 0];
      send(6, new Proto().int(1, dx!).int(2, dy!));
      return;
    }
    if (release || motion) {
      if (!touching) return;
      const at = devicePoint(px, py, true) ?? touching;
      if (release) { touch(at.x, at.y, 0, touching.pinch); touching = undefined; return; }
      if (at.x === touching.x && at.y === touching.y) return;
      touching = { ...at, pinch: touching.pinch };
      touch(at.x, at.y, 1, touching.pinch);
      return;
    }
    if (button !== 0 || touching) return;
    if (py >= (g.rows - 1) * g.cellHeight) {
      const column = Math.floor(px / g.cellWidth) + 1;
      const hit = buttons.find(item => column >= item.from && column <= item.to);
      if (hit) toolbarAction(hit.act);
      return;
    }
    const at = devicePoint(px, py);
    if (!at) return;
    // Alt+drag adds a second finger mirrored through the screen's center: pinch and rotate.
    touching = { ...at, pinch: alt };
    touch(at.x, at.y, 1, alt);
  };
  /**
   * Every key goes as a whole press with its modifiers. Terminals that report no releases (Tern
   * among them) would otherwise leave a key down, which the device auto-repeats.
   */
  const pressed = (name: string, ctrl = false, alt = false, shift = false) => {
    // Characters arrive already shifted and the emulator adds Shift itself; named keys need it.
    const shifted = shift && name.length > 1;
    if (ctrl) send(1, keyEvent("Control", "down"));
    if (alt) send(1, keyEvent("Alt", "down"));
    if (shifted) send(1, keyEvent("Shift", "down"));
    send(1, name.length === 1 && !PRINTABLE.test(name) ? textEvent(name) : keyEvent(name, "press"));
    if (shifted) send(1, keyEvent("Shift", "up"));
    if (alt) send(1, keyEvent("Alt", "up"));
    if (ctrl) send(1, keyEvent("Control", "up"));
  };
  const paste = (text: string) => {
    // ClipData carries any Unicode text; Ctrl+V pastes it into the focused field.
    client.unary("setClipboard", new Proto().string(1, text)).then(() => {
      send(1, keyEvent("Control", "down")); send(1, keyEvent("v", "press")); send(1, keyEvent("Control", "up"));
    }, error => status(`Paste failed: ${error.message}`));
  };

  const csi = (body: string, final: string) => {
    // Tern rounds the cell size it reports (CSI 16t) but lays images out in its real, fractional
    // cells while 1016 reports real pixels, so its pixel reports drift from the frame; cells agree.
    if (final === "y" && body.startsWith("?1016;")) { pixelMouse = /^\?1016;[1234]\$$/.test(body) && process.env.TERM_PROGRAM !== "tern"; return; }
    if (final === "u" && body.startsWith("?")) { kittyKeyboard = true; return; }
    if (final === "c" && body.startsWith("?")) { answered?.(); return; }
    if (final === "t") {
      const [kind, height, width] = body.split(";").map(Number);
      if (kind === 6 && width && height) {
        geometry = { cols: process.stdout.columns, rows: process.stdout.rows, cellWidth: width, cellHeight: height };
      } else if (kind === 4 && width && height && !geometry) {
        const cols = process.stdout.columns, rows = process.stdout.rows;
        geometry = { cols, rows, cellWidth: Math.floor(width / cols), cellHeight: Math.floor(height / rows) };
      }
      return;
    }
    if ((final === "M" || final === "m") && body.startsWith("<")) {
      const [code, x, y] = body.slice(1).split(";").map(Number);
      if (code !== undefined && x && y) mouse(code, x, y, final === "m");
      return;
    }
    if (final === "I" && !body) return;
    if (final === "O" && !body) { releaseTouch(); return; }
    const [first = "", second = "", third = ""] = body.split(";");
    const code = Number(first.split(":")[0] || 1);
    const modifiers = Number(second.split(":")[0]) || 1;
    const text = third ? String.fromCodePoint(...third.split(":").map(Number)) : undefined;
    const shift = ((modifiers - 1) & 1) !== 0, alt = ((modifiers - 1) & 2) !== 0, ctrl = ((modifiers - 1) & 4) !== 0;
    let name: string | undefined;
    if (final === "u") {
      if (IGNORED.has(code)) return;
      name = KITTY_KEYS[code] ?? (code >= 32 && code < 57344 ? String.fromCodePoint(code) : undefined);
    } else if (final === "~") name = TILDE_KEYS[code];
    else name = LETTER_KEYS[final];
    if (!name) return;
    pressed(ctrl ? name : text ?? name, ctrl, alt, shift);
  };
  const apc = (body: string) => {
    const match = /^G([^;]*);(.*)$/s.exec(body);
    if (!match) return;
    const id = Number(/(?:^|,)i=(\d+)/.exec(match[1]!)?.[1]);
    if (id === QUERY_ID) kitty = match[2] === "OK";
    else if (id === FRAME_ID) acknowledged(match[2] === "OK", match[2]!);
  };
  const legacy = (char: string) => {
    if (char === "\r" || char === "\n") pressed("Enter");
    else if (char === "\t") pressed("Tab");
    else if (char === "\x7f" || char === "\b") pressed("Backspace");
    else if (char === ESC) pressed("Escape");
    else if (char < " ") pressed(String.fromCharCode(char.charCodeAt(0) + 96), true);
    else pressed(char);
  };
  const parse = () => {
    clearTimeout(flushTimer);
    while (pending) {
      if (pending.startsWith(`${ESC}[200~`)) {
        const end = pending.indexOf(`${ESC}[201~`);
        if (end < 0) break;
        paste(pending.slice(6, end));
        pending = pending.slice(end + 6);
        continue;
      }
      if (pending[0] === ESC) {
        if (pending.length === 1) {
          // A lone ESC is the Escape key unless a sequence follows promptly.
          flushTimer = setTimeout(() => { if (pending === ESC) { pending = ""; legacy(ESC); } }, 40);
          break;
        }
        const kind = pending[1];
        if (kind === "[") {
          const match = /^\x1b\[([\x30-\x3f]*[\x20-\x2f]*)([\x40-\x7e])/.exec(pending);
          if (!match) { if (pending.length > 64) pending = pending.slice(2); break; }
          pending = pending.slice(match[0].length);
          csi(match[1]!, match[2]!);
        } else if (kind === "_" || kind === "]") {
          const end = kind === "]" ? pending.search(/\x07|\x1b\\/) : pending.indexOf(`${ESC}\\`);
          if (end < 0) { if (pending.length > 65536) pending = ""; break; }
          if (kind === "_") apc(pending.slice(2, end));
          pending = pending.slice(end + (pending[end] === "\x07" ? 1 : 2));
        } else if (kind === "O") {
          if (pending.length < 3) break;
          const name = LETTER_KEYS[pending[2]!] ?? (pending[2] === "R" ? "F3" : undefined);
          if (name) pressed(name);
          pending = pending.slice(3);
        } else {
          // ESC + character: Alt held in a legacy terminal.
          const char = String.fromCodePoint(pending.codePointAt(1)!);
          pending = pending.slice(1 + char.length);
          pressed(char, false, true);
        }
        continue;
      }
      const char = String.fromCodePoint(pending.codePointAt(0)!);
      pending = pending.slice(char.length);
      legacy(char);
    }
  };
  const onData = (chunk: Buffer) => { pending += decoder.decode(chunk, { stream: true }); parse(); };

  // ── Lifecycle ──────────────────────────────────────────────────────────────────
  const onResize = () => {
    out(`${ESC}[16t`);
    setTimeout(() => {
      if (!geometry || stopping) return;
      geometry = { ...geometry, cols: process.stdout.columns, rows: process.stdout.rows };
      redraw();
      subscribe();
    }, 80);
  };
  let hungUp = false;
  const onSignal = () => { hungUp = true; stop(); };
  process.stdin.setRawMode(true);
  process.stdin.on("data", onData);
  process.stdin.resume();
  // Alternate screen, hidden cursor, window title; then the queries this view depends on.
  out(`${ESC}[?1049h${ESC}[?25l${ESC}]2;${label}\x07`);
  const { promise: queried, resolve: queriesDone } = Promise.withResolvers<void>();
  answered = queriesDone;
  out(`${ESC}_Gi=${QUERY_ID},s=1,v=1,a=q,t=d,f=24;AAAA${ESC}\\${ESC}[?1016$p${ESC}[?u${ESC}[16t${ESC}[14t${ESC}[c`);
  const timeout = setTimeout(queriesDone, 2000);
  let failure: string | undefined;
  try {
    await queried;
    clearTimeout(timeout);
    answered = undefined;
    if (!kitty) throw new Error("This terminal does not support the kitty graphics protocol. Open the device from Tern, or use kitty, Ghostty or WezTerm.");
    if (!geometry) throw new Error("This terminal does not report its pixel size (CSI 14t/16t).");
    // Mouse: button-event tracking, SGR encoding, pixel coordinates, focus; keyboard: kitty flags
    // 1|8|16 (disambiguate, every key, associated text); bracketed paste.
    out(`${ESC}[?1002h${ESC}[?1006h${pixelMouse ? `${ESC}[?1016h` : ""}${ESC}[?1004h${ESC}[?2004h${kittyKeyboard ? `${ESC}[>25u` : ""}`);
    process.on("SIGWINCH", onResize);
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(signal, onSignal);
    redraw();
    // DisplayConfigurations.displays; display 0 omits its id field.
    const configurations = await client.unary("getDisplayConfigurations");
    const primary = (configurations.get(1) ?? []).flatMap(value => Buffer.isBuffer(value) ? [decode(value)] : [])
      .find(fields => number(fields, 5) === 0);
    if (primary) native = { width: number(primary, 1), height: number(primary, 2) };
    if (!native.width || !native.height) throw new Error("The emulator reported no display size.");
    status(`Waiting for ${title}'s screen…`);
    subscribe();
    failure = await finished;
    if (failure && !hungUp) {
      // A stopping emulator drops gRPC before its process exits, which may first save a snapshot.
      status(`${title} disconnected. Waiting for it to exit…`);
      for (const deadline = Date.now() + 15_000; alive() && !hungUp && Date.now() < deadline;) await Bun.sleep(200);
    }
  } catch (error) {
    failure = error instanceof Error ? error.message : String(error);
  } finally {
    stopping = true;
    releaseTouch();
    cancelStream?.();
    input?.end();
    clearTimeout(ackTimer);
    clearTimeout(flushTimer);
    process.removeListener("SIGWINCH", onResize);
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.removeListener(signal, onSignal);
    process.stdin.removeListener("data", onData);
    // Reports the terminal sent before it saw the reset (a Close click's release) must not reach the shell.
    const drain = () => {};
    process.stdin.on("data", drain);
    out(`${ESC}_Ga=d,d=A,q=2${ESC}\\${kittyKeyboard ? `${ESC}[<u` : ""}${ESC}[?2004l${ESC}[?1004l${ESC}[?1016l${ESC}[?1006l${ESC}[?1002l${ESC}[?25h${ESC}[?1049l`);
    // Also lets pending input reach the emulator before the connection closes.
    await Bun.sleep(100);
    process.stdin.removeListener("data", drain);
    process.stdin.setRawMode(false);
    process.stdin.pause();
    client.close();
    rmSync(directory, { recursive: true, force: true });
  }
  if (failure) {
    // The emulator stopping is the normal end of a view, not an error.
    if (alive()) throw new Error(failure);
    console.log(`${title} stopped.`);
  }
}
