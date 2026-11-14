import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { button as renderButton, panel, pill } from "./icons";

/**
 * Shows one Android device inside the terminal it runs in: frames are drawn with the kitty graphics
 * protocol, SGR mouse reports become touches and kitty keyboard reports become key events. The
 * bottom row holds the device's buttons. The device outlives the view.
 */

export type Frame = { data: Buffer; width: number; height: number };
export type Modifiers = { ctrl: boolean; alt: boolean; shift: boolean };
export type Wheel = "up" | "down" | "left" | "right";
export type ToolbarButton = "back" | "home" | "recents" | "power" | "volume-down" | "volume-up" | "rotate-left" | "rotate-right";
export type DeviceEvents = { status(text: string): void; stop(reason?: string): void };

/** A device the view draws and drives; points are fractions (0–1) of the latest frame. */
export interface Device {
  readonly title: string;
  readonly label: string;
  open(events: DeviceEvents): Promise<void>;
  /** Replaces the frame stream with one sized to fit `width`×`height`; `undefined` is a dark screen. */
  stream(width: number, height: number, onFrame: (frame: Frame | undefined) => void): void;
  touch(phase: "down" | "move" | "up", u: number, v: number, pinch: boolean): void;
  scroll(u: number, v: number, wheel: Wheel): void;
  key(name: string, modifiers: Modifiers): void;
  paste(text: string): void;
  press(button: ToolbarButton): void;
  /** After a lost connection: the closing line when the device itself went away, else undefined. */
  ended(waiting: () => boolean): Promise<string | undefined>;
  close(): Promise<void>;
}

const ESC = "\x1b";
/** Appended to the view's title when it could not open its device (the window half matches it). */
const FAILED_TITLE = " (failed)";
const FRAME_ID = 1;
const QUERY_ID = 31;
/** Toolbar images: buttons from ICON_ID (by their index in ACTS), then the panel behind them. */
const ICON_ID = 40;
const PANEL_ID = 60;
/** The progress bar's track and its moving segment. */
const TRACK_ID = 70;
const SEGMENT_ID = 71;
/** The toolbar's height in rows: room for Tern-sized buttons with padding around them. */
const BAR_ROWS = 3;
const SCREEN_OFF = "The screen is off. Press Power to wake it.";
type Act = ToolbarButton | "close";
/** The device's navigation buttons sit in the middle, hardware keys left of them, rotation right; Close ends the bar. */
const NAVIGATION: Act[] = ["back", "home", "recents"];
const HARDWARE: Act[] = ["power", "volume-down", "volume-up"];
const ROTATION: Act[] = ["rotate-left", "rotate-right"];
const ACTS: Act[] = [...NAVIGATION, ...HARDWARE, ...ROTATION, "close"];

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
const WHEELS: Wheel[] = ["up", "down", "left", "right"];

type Geometry = { cols: number; rows: number; cellWidth: number; cellHeight: number };
type Rgb = readonly [number, number, number];
type Slot = { act: Act; from: number; to: number };

const mix = (a: Rgb, b: Rgb, amount: number): Rgb => [0, 1, 2].map(i => Math.round(a[i]! + (b[i]! - a[i]!) * amount)) as unknown as Rgb;
/** An image transmission, split into the protocol's 4096-byte chunks. */
const graphics = (control: string, data: Buffer) => {
  const encoded = data.toString("base64");
  const chunks: string[] = [];
  for (let offset = 0; offset < encoded.length; offset += 4096) {
    const more = offset + 4096 < encoded.length ? 1 : 0;
    chunks.push(`${ESC}_G${offset ? "" : `${control},`}m=${more};${encoded.slice(offset, offset + 4096)}${ESC}\\`);
  }
  return chunks.join("");
};

/** Lines of at most `room` columns, broken at spaces where possible. */
const wrap = (text: string, room: number) => text.split("\n").flatMap(paragraph => {
  const lines: string[] = [];
  let line = "";
  for (const word of paragraph.split(" ")) {
    if (line && line.length + 1 + word.length > room) { lines.push(line); line = word; } else line = line ? `${line} ${word}` : word;
  }
  return [...lines, line];
});

/** Connects the device while the view shows progress; `progress` names the current step. */
export type Connect = (progress: (step: string) => void, signal: AbortSignal) => Promise<Device>;

export async function runDisplay(title: string, connect: Connect): Promise<void> {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error("display needs an interactive terminal with kitty graphics, such as a Tern pane.");
  const out = (text: string) => { process.stdout.write(text); };
  const decoder = new TextDecoder();
  let device: Device | undefined;
  let pending = "";
  let flushTimer: Timer | undefined;
  let geometry: Geometry | undefined;
  let kitty = false, kittyKeyboard = false, pixelMouse = false;
  let foreground: Rgb | undefined, background: Rgb | undefined;
  let answered: (() => void) | undefined;
  let fileTransport = true, framesShown = 0;
  let frame: Frame | undefined, drawn: Frame | undefined, inFlight = false, ackTimer: Timer | undefined;
  let streamSize = "";
  let touching: { u: number; v: number; pinch: boolean } | undefined;
  /** The step in progress, shown with an animated bar until the first frame; and the latest notice. */
  let step: string | undefined = `Connecting to ${title}…`, message = "";
  const started = Date.now();
  // `closing`: the user closed the view; a wait for a dropped emulator to exit ends at once.
  let stopping = false, restored = false, closing = false;
  const { promise: finished, resolve: finish } = Promise.withResolvers<string | undefined>();
  const directory = mkdtempSync(path.join(os.tmpdir(), "elide-tern-display-"));
  const framePath = path.join(directory, "frame.rgb");

  function stop(reason?: string): void {
    if (stopping) return;
    stopping = true;
    finish(reason);
  }

  // ── Terminal output ────────────────────────────────────────────────────────────
  const area = () => {
    const g = geometry!;
    return { width: g.cols * g.cellWidth, height: Math.max(1, g.rows - BAR_ROWS) * g.cellHeight };
  };
  const ink = (): Rgb => foreground ?? [224, 224, 224];
  const color = (rgb: Rgb | undefined, layer: 38 | 48) => rgb ? `${ESC}[${layer};2;${rgb.join(";")}m` : "";
  const clip = (text: string, room: number) => text.length > room ? text.slice(0, Math.max(0, room - 1)) + "…" : text;

  // ── Toolbar ────────────────────────────────────────────────────────────────────
  let slots: Slot[] = [];
  let note = { from: 1, to: 0 };
  let hovered: Slot | undefined, pressed: Slot | undefined;
  const images = new Map<string, Buffer>();
  /** Pixels per Tern pixel: Tern's cells are about 17 pixels tall at 1×. */
  const scale = () => geometry!.cellHeight / 17;
  const box = () => Math.min(BAR_ROWS * geometry!.cellHeight - 2, Math.round(28 * scale()));
  /** The bar's columns, its separators' first columns, and the columns left free for the note. */
  let dock = { from: 1, to: 0 }, separators: number[] = [];
  const separatorWidth = () => Math.max(1, Math.ceil(16 * scale() / geometry!.cellWidth));
  /**
   * The bar is as wide as its buttons plus a column each side. Navigation is centered in the
   * pane, hardware keys left of it, rotation and then Close right, groups set apart by separators.
   * When narrow, rotation and then the hardware buttons drop out. The note takes the space left
   * of the bar.
   */
  const layout = () => {
    const g = geometry!;
    const width = Math.ceil((box() + 4 * scale()) / g.cellWidth), gap = separatorWidth();
    const center = Math.floor((g.cols - NAVIGATION.length * width) / 2) + 1;
    const row = (acts: Act[], from: number) => acts.map((act, index) => ({ act, from: from + index * width, to: from + (index + 1) * width - 1 }));
    for (const level of [2, 1, 0]) {
      const groups: Act[][] = [...level ? [HARDWARE] : [], NAVIGATION, ...level === 2 ? [ROTATION] : [], ["close"]];
      const before = level ? HARDWARE.length * width + gap : 0;
      let column = center - before;
      const placed: Slot[] = [], gaps: number[] = [];
      groups.forEach((group, index) => {
        if (index) { gaps.push(column); column += gap; }
        placed.push(...row(group, column));
        column += group.length * width;
      });
      dock = { from: center - before - 1, to: column };
      if (dock.from < 1 || dock.to > g.cols) continue;
      slots = placed;
      separators = gaps;
      note = { from: 2, to: dock.from - 2 };
      return;
    }
    slots = [];
    separators = [];
    dock = { from: 1, to: 0 };
    note = { from: 2, to: g.cols - 1 };
  };
  /** One image spanning the bar's rows at `column`, cached by `key`; `z` -1 puts it under the buttons. */
  const place = (id: number, column: number, key: string, render: (width: number, height: number) => Buffer, columns: number, z = 0) => {
    const g = geometry!, width = columns * g.cellWidth, height = BAR_ROWS * g.cellHeight;
    const cacheKey = `${key}:${width}x${height}:${ink().join(",")}`;
    let pixels = images.get(cacheKey);
    if (!pixels) images.set(cacheKey, pixels = render(width, height));
    return `${ESC}[${g.rows - BAR_ROWS + 1};${column}H${graphics(`a=T,f=32,s=${width},v=${height},i=${id},p=1,C=1,z=${z},q=2`, pixels)}`;
  };
  const drawSlot = (slot: Slot) => {
    const s = scale();
    const state = pressed === slot && hovered === slot ? "pressed" : hovered === slot ? "hover" : "idle";
    const image = place(ICON_ID + ACTS.indexOf(slot.act), slot.from, `${slot.act}:${state}`, (width, height) => renderButton(slot.act, {
      width, height, box: box(), radius: Math.round(6 * s), icon: Math.round(16 * s), color: ink(),
      fill: state === "pressed" ? 0.16 : state === "hover" ? 0.09 : 0, ink: state === "idle" ? 0.72 : 0.95,
    }), slot.to - slot.from + 1);
    out(`${ESC}7${image}${ESC}8`);
  };
  /** After the first frame: the latest notice, on the bar's middle row left of it. */
  const drawNote = () => {
    if (!geometry || restored || !drawn) return;
    const room = note.to - note.from + 1;
    if (room < 4) return;
    const text = clip(message.split("\n")[0]!, room).padEnd(room);
    out(`${ESC}7${ESC}[${geometry.rows - Math.floor(BAR_ROWS / 2)};${note.from}H${ESC}[2m${text}${ESC}[0m${ESC}8`);
  };
  const toolbar = () => {
    if (!geometry || restored) return;
    layout();
    const g = geometry, s = scale();
    let text = "";
    for (let row = g.rows - BAR_ROWS + 1; row <= g.rows; row++) text += `${ESC}[${row};1H${ESC}[2K`;
    if (dock.to > dock.from) {
      // One translucent panel behind the buttons: fill, outline and separators.
      const columns = dock.to - dock.from + 1;
      const centers = separators.map(column => (column - dock.from + separatorWidth() / 2) * g.cellWidth);
      text += place(PANEL_ID, dock.from, `panel:${separators.join(",")}`, (width, height) => panel(width, height, {
        radius: Math.round(10 * s), color: ink(), fill: 0.05, stroke: 0.14, line: Math.max(1, Math.round(s)),
        separators: centers, tall: Math.round(18 * s),
      }), columns, -1);
    }
    out(`${ESC}7${text}${ESC}8`);
    for (const slot of slots) drawSlot(slot);
    drawNote();
  };
  const hover = (slot: Slot | undefined) => {
    if (slot === hovered) return;
    const previous = hovered;
    hovered = slot;
    if (previous) drawSlot(previous);
    if (slot) drawSlot(slot);
  };

  // ── Progress ───────────────────────────────────────────────────────────────────
  /**
   * Before the first frame: the device's name, an indeterminate bar with the step, then any
   * notice. The bar is two images sent once: a track and a segment that a 60 fps timer moves by
   * re-placing it at a pixel offset, so it glides instead of stepping a cell at a time.
   */
  let animation: Timer | undefined, seconds = -1;
  /** The bar's images as sent (geometry and colors), its first column and its pixel sizes. */
  let bar: { key: string; column: number; width: number; segment: number } | undefined;
  const NOTICE_LINES = 5;
  const middle = () => Math.max(3, Math.floor((geometry!.rows - BAR_ROWS - NOTICE_LINES) / 2));
  /** Places the segment where it is now: an eased sweep back and forth, 1.1 s each way. */
  const moveSegment = () => {
    if (!geometry || !bar || restored || drawn) return;
    const g = geometry, phase = ((Date.now() - started) / 1100) % 2;
    const sweep = (1 - Math.cos(Math.PI * (phase < 1 ? phase : 2 - phase))) / 2;
    const x = Math.round(sweep * (bar.width - bar.segment));
    const column = bar.column + Math.floor(x / g.cellWidth), offset = x % g.cellWidth;
    out(`${ESC}7${ESC}[${middle()};${column}H${ESC}_Ga=p,i=${SEGMENT_ID},p=1,X=${offset},C=1,z=1,q=2${ESC}\\${ESC}8`);
  };
  const progress = () => {
    if (!geometry || restored || drawn) return;
    const g = geometry, row = middle();
    /** A cleared row with `text` centered on it; the cursor must already be on the row. */
    const centered = (text: string, style = "") =>
      `${ESC}[2K` + (text ? `${ESC}[${Math.max(1, Math.floor((g.cols - text.length) / 2) + 1)}G${style}${clip(text, g.cols - 2)}${ESC}[0m` : "");
    seconds = Math.floor((Date.now() - started) / 1000);
    // Below the bar and step come notices; with nothing in progress they take the bar's place.
    const notices = message ? wrap(message, Math.max(16, Math.min(72, g.cols - 4))).slice(0, NOTICE_LINES).map((notice, index) => centered(notice, index ? ESC + "[2m" : "")) : [];
    const below = step ? [`${ESC}[2K`, centered(""), centered(seconds >= 3 ? `${step} ${seconds}s` : step, ESC + "[2m"), ...notices] : notices;
    let text = `${ESC}[${row - 2};1H${centered(title, ESC + "[1m")}${ESC}[${row - 1};1H${ESC}[2K`;
    for (let index = 0; index < 3 + NOTICE_LINES; index++) text += `${ESC}[${row + index};1H${below[index] ?? `${ESC}[2K`}`;
    if (step) {
      const columns = Math.max(8, Math.min(32, g.cols - 8)), column = Math.floor((g.cols - columns) / 2) + 1;
      const width = columns * g.cellWidth, segment = Math.round(width / 4), height = g.cellHeight;
      const thickness = Math.max(2, Math.round(3 * scale()));
      const key = `${width}x${height}:${ink().join(",")}`;
      if (bar?.key !== key) {
        text += graphics(`a=t,f=32,s=${width},v=${height},i=${TRACK_ID},q=2`, pill(width, height, thickness, ink(), 0.14));
        text += graphics(`a=t,f=32,s=${segment},v=${height},i=${SEGMENT_ID},q=2`, pill(segment, height, thickness, ink(), 0.9));
      }
      bar = { key, column, width, segment };
      text += `${ESC}[${row};${column}H${ESC}_Ga=p,i=${TRACK_ID},p=1,C=1,z=0,q=2${ESC}\\`;
    } else {
      text += `${ESC}_Ga=d,d=i,i=${TRACK_ID},q=2${ESC}\\${ESC}_Ga=d,d=i,i=${SEGMENT_ID},q=2${ESC}\\`;
    }
    out(`${ESC}7${text}${ESC}8`);
    if (step) moveSegment();
  };
  const stopAnimation = () => {
    clearInterval(animation);
    animation = undefined;
  };
  const clearProgress = () => {
    stopAnimation();
    if (!geometry) return;
    let rows = `${ESC}_Ga=d,d=I,i=${TRACK_ID},q=2${ESC}\\${ESC}_Ga=d,d=I,i=${SEGMENT_ID},q=2${ESC}\\`;
    bar = undefined;
    for (let row = middle() - 2; row <= middle() + 3 + NOTICE_LINES; row++) rows += `${ESC}[${row};1H${ESC}[2K`;
    out(`${ESC}7${rows}${ESC}8`);
  };
  const setStep = (text: string | undefined) => {
    step = text;
    // The segment moves every frame; the text (elapsed seconds) only when a second has passed.
    if (step && !animation) animation = setInterval(() => {
      if (Math.floor((Date.now() - started) / 1000) !== seconds) progress();
      else moveSegment();
    }, 16);
    if (!step) stopAnimation();
    progress();
  };
  const status = (text: string) => {
    message = text;
    if (drawn) drawNote();
    else progress();
  };
  const redraw = () => {
    out(`${ESC}_Ga=d,d=A,q=2${ESC}\\${ESC}[2J`);
    drawn = bar = undefined;
    toolbar();
    progress();
  };

  // ── Frames ─────────────────────────────────────────────────────────────────────
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
    } else command = graphics(place, next.data);
    const first = !drawn;
    if (first) {
      clearProgress();
      step = undefined;
      if (message === SCREEN_OFF) message = "";
    }
    out(`${ESC}7${ESC}[${Math.floor(top / g.cellHeight) + 1};${Math.floor(left / g.cellWidth) + 1}H${command}${ESC}8`);
    drawn = next;
    if (first) drawNote();
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
  // Streams frames at the current box size; false when that size already streams.
  const subscribe = () => {
    if (!geometry || stopping || !device) return false;
    const box = area();
    const size = `${box.width}x${box.height}`;
    if (size === streamSize) return false;
    streamSize = size;
    device.stream(box.width, box.height, next => {
      if (stopping) return;
      if (!next) {
        frame = undefined;
        if (drawn) redraw();
        setStep(undefined);
        status(SCREEN_OFF);
        return;
      }
      frame = next;
      pump();
    });
    return true;
  };

  // ── Input ──────────────────────────────────────────────────────────────────────
  /** A pane pixel as a fraction of the drawn frame; outside it undefined unless `clamp` (a drag that left it). */
  const framePoint = (px: number, py: number, clamp = false) => {
    if (!drawn || !geometry) return undefined;
    const box = area();
    const left = Math.max(0, Math.floor((box.width - drawn.width) / 2)), top = Math.max(0, Math.floor((box.height - drawn.height) / 2));
    const u = (px - left) / drawn.width, v = (py - top) / drawn.height;
    if (!clamp && (u < 0 || v < 0 || u >= 1 || v >= 1)) return undefined;
    return { u: Math.min(1, Math.max(0, u)), v: Math.min(1, Math.max(0, v)) };
  };
  const releaseTouch = () => {
    if (touching) { device?.touch("up", touching.u, touching.v, touching.pinch); touching = undefined; }
  };
  const act = (button: Act) => {
    if (button === "close") { closing = true; stop(); }
    else device?.press(button);
  };
  const mouse = (code: number, x: number, y: number, release: boolean) => {
    const g = geometry;
    if (!g) return;
    // Cell reports (no 1016) address the cell's center.
    const px = pixelMouse ? x - 1 : (x - 0.5) * g.cellWidth, py = pixelMouse ? y - 1 : (y - 0.5) * g.cellHeight;
    const button = code & 3, motion = (code & 32) !== 0, alt = (code & 8) !== 0;
    const column = Math.floor(px / g.cellWidth) + 1;
    const slot = !touching && py >= (g.rows - BAR_ROWS) * g.cellHeight ? slots.find(item => column >= item.from && column <= item.to) : undefined;
    if (code & 64) {
      const at = framePoint(px, py);
      if (at) device?.scroll(at.u, at.v, WHEELS[button]!);
      return;
    }
    // Toolbar buttons act on release over the button they were pressed on.
    if (pressed) {
      if (!release && !motion) return;
      const target = pressed;
      if (release) pressed = undefined;
      if (release && slot === hovered) drawSlot(target);
      hover(slot);
      if (release && slot === target) act(target.act);
      return;
    }
    if (motion && button === 3) { hover(slot); return; }
    if (release || motion) {
      if (!touching) return;
      const at = framePoint(px, py, true) ?? touching;
      touching = { ...at, pinch: touching.pinch };
      device?.touch(release ? "up" : "move", at.u, at.v, touching.pinch);
      if (release) touching = undefined;
      return;
    }
    if (button !== 0 || touching) return;
    if (slot) { pressed = slot; if (hovered === slot) drawSlot(slot); else hover(slot); return; }
    const at = framePoint(px, py);
    if (!at || !device) return;
    // Alt+drag is a two-finger pinch or rotate where the device supports it.
    touching = { ...at, pinch: alt };
    device.touch("down", at.u, at.v, alt);
  };
  const press = (name: string, ctrl = false, alt = false, shift = false) => device?.key(name, { ctrl, alt, shift });

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
    if (final === "O" && !body) {
      releaseTouch();
      pressed = undefined;
      hover(undefined);
      return;
    }
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
    press(ctrl ? name : text ?? name, ctrl, alt, shift);
  };
  const apc = (body: string) => {
    const match = /^G([^;]*);(.*)$/s.exec(body);
    if (!match) return;
    const id = Number(/(?:^|,)i=(\d+)/.exec(match[1]!)?.[1]);
    if (id === QUERY_ID) kitty = match[2] === "OK";
    else if (id === FRAME_ID) acknowledged(match[2] === "OK", match[2]!);
  };
  /** Foreground (10) and background (11) color reports; the toolbar draws in them. */
  const osc = (body: string) => {
    const match = /^1([01]);rgb:([0-9a-f]{1,4})\/([0-9a-f]{1,4})\/([0-9a-f]{1,4})$/i.exec(body);
    if (!match) return;
    const color = match.slice(2).map(hex => Math.round(parseInt(hex, 16) / (16 ** hex.length - 1) * 255)) as unknown as Rgb;
    if (match[1] === "0") foreground = color;
    else background = color;
  };
  const legacy = (char: string) => {
    if (char === "\r" || char === "\n") press("Enter");
    else if (char === "\t") press("Tab");
    else if (char === "\x7f" || char === "\b") press("Backspace");
    else if (char === ESC) press("Escape");
    else if (char < " ") press(String.fromCharCode(char.charCodeAt(0) + 96), true);
    else press(char);
  };
  const parse = () => {
    clearTimeout(flushTimer);
    while (pending) {
      if (pending.startsWith(`${ESC}[200~`)) {
        const end = pending.indexOf(`${ESC}[201~`);
        if (end < 0) break;
        device?.paste(pending.slice(6, end));
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
          else osc(pending.slice(2, end));
          pending = pending.slice(end + (pending[end] === "\x07" ? 1 : 2));
        } else if (kind === "O") {
          if (pending.length < 3) break;
          const name = LETTER_KEYS[pending[2]!] ?? (pending[2] === "R" ? "F3" : undefined);
          if (name) press(name);
          pending = pending.slice(3);
        } else {
          // ESC + character: Alt held in a legacy terminal.
          const char = String.fromCodePoint(pending.codePointAt(1)!);
          pending = pending.slice(1 + char.length);
          press(char, false, true);
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
  let resizing: Timer | undefined;
  const onResize = () => {
    out(`${ESC}[16t`);
    // Dragging a divider sends a burst of resizes: redraw once, after the last.
    clearTimeout(resizing);
    resizing = setTimeout(() => {
      resizing = undefined;
      if (!geometry || stopping) return;
      geometry = { ...geometry, cols: process.stdout.columns, rows: process.stdout.rows };
      hovered = pressed = undefined;
      const last = drawn;
      redraw();
      // The same box size streams on and sends nothing until the screen changes: draw the last
      // frame again rather than leave the pane blank.
      if (!subscribe() && last) {
        frame ??= last;
        pump();
      }
    }, 80);
  };
  let hungUp = false;
  const onSignal = () => { hungUp = true; stop(); };
  process.stdin.setRawMode(true);
  process.stdin.on("data", onData);
  process.stdin.resume();
  // Alternate screen, hidden cursor, window title; then the queries this view depends on.
  out(`${ESC}[?1049h${ESC}[?25l${ESC}]2;${title}\x07`);
  const { promise: queried, resolve: queriesDone } = Promise.withResolvers<void>();
  answered = queriesDone;
  out(`${ESC}_Gi=${QUERY_ID},s=1,v=1,a=q,t=d,f=24;AAAA${ESC}\\${ESC}[?1016$p${ESC}[?u${ESC}[16t${ESC}[14t${ESC}]10;?${ESC}\\${ESC}]11;?${ESC}\\${ESC}[c`);
  const timeout = setTimeout(queriesDone, 2000);
  let failure: string | undefined, gone: string | undefined;
  try {
    await queried;
    clearTimeout(timeout);
    answered = undefined;
    if (!kitty) throw new Error("This terminal does not support the kitty graphics protocol. Open the device from Tern, or use kitty, Ghostty or WezTerm.");
    if (!geometry) throw new Error("This terminal does not report its pixel size (CSI 14t/16t).");
    // Mouse: any-event tracking (hover), SGR encoding, pixel coordinates, focus; keyboard: kitty
    // flags 1|8|16 (disambiguate, every key, associated text); bracketed paste.
    out(`${ESC}[?1003h${ESC}[?1006h${pixelMouse ? `${ESC}[?1016h` : ""}${ESC}[?1004h${ESC}[?2004h${kittyKeyboard ? `${ESC}[>25u` : ""}`);
    process.on("SIGWINCH", onResize);
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(signal, onSignal);
    redraw();
    setStep(step);
    // Closing the view while connecting cancels it; a started emulator is stopped again.
    const abort = new AbortController();
    const connecting = connect(text => { if (!stopping) setStep(text); }, abort.signal);
    const connected = await Promise.race([connecting, finished.then(() => undefined)]).catch((error: unknown) => {
      // A failed connection stays on screen until the view is closed. Its title says it failed,
      // so Show and Start open a fresh view in its place instead of focusing this one.
      setStep(undefined);
      out(`${ESC}]2;${title}${FAILED_TITLE}\x07`);
      status(`Could not open ${title}.\n${error instanceof Error ? error.message : String(error)}`);
      return null;
    });
    if (connected === undefined) {
      abort.abort();
      device = await connecting.catch(() => undefined);
    } else if (connected === null) {
      await finished;
    } else {
      device = connected;
      out(`${ESC}]2;${device.label}\x07`);
      await device.open({ status: text => { if (!stopping) status(text); }, stop });
      setStep("Waiting for the screen…");
      subscribe();
      failure = await finished;
      if (failure && !hungUp) {
        status(failure);
        gone = await device.ended(() => !hungUp && !closing);
      }
    }
  } catch (error) {
    failure = error instanceof Error ? error.message : String(error);
    gone = await device?.ended(() => false).catch(() => undefined);
  } finally {
    stopping = true;
    releaseTouch();
    clearTimeout(ackTimer);
    clearTimeout(flushTimer);
    clearInterval(animation);
    process.removeListener("SIGWINCH", onResize);
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.removeListener(signal, onSignal);
    process.stdin.removeListener("data", onData);
    // Reports the terminal sent before it saw the reset (a Close click's release) must not reach the shell.
    const drain = () => {};
    process.stdin.on("data", drain);
    restored = true;
    out(`${ESC}_Ga=d,d=A,q=2${ESC}\\${kittyKeyboard ? `${ESC}[<u` : ""}${ESC}[?2004l${ESC}[?1004l${ESC}[?1016l${ESC}[?1006l${ESC}[?1003l${ESC}[?25h${ESC}[?1049l`);
    await Promise.all([device?.close(), Bun.sleep(100)]);
    process.stdin.removeListener("data", drain);
    process.stdin.setRawMode(false);
    process.stdin.pause();
    rmSync(directory, { recursive: true, force: true });
  }
  if (failure && !closing) {
    // The device stopping or leaving is the normal end of a view, not an error.
    if (!gone) throw new Error(failure);
    console.log(gone);
  }
}
