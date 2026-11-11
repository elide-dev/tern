import type { Subprocess } from "bun";
import type { Device, DeviceEvents, Frame, Modifiers, ToolbarButton, Wheel } from "./display";
import { errorMessage, run } from "./process";
import { PRODUCT, productName } from "./sdk";

/**
 * Mirrors an attached device over adb alone, with nothing installed on it: frames come from
 * `screenrecord --output-format=frames` (raw RGB on change, scaled on the device), input from
 * `input` commands in one long-lived shell. Each command starts a process on the device, so a
 * drag is sent as one swipe when it ends rather than followed live.
 */

const PRINTABLE = /^[\x20-\x7e]$/;
const KEYCODES: Record<string, string> = {
  Enter: "ENTER", Tab: "TAB", Escape: "ESCAPE", Backspace: "DEL", Delete: "FORWARD_DEL", Insert: "INSERT",
  ArrowUp: "DPAD_UP", ArrowDown: "DPAD_DOWN", ArrowLeft: "DPAD_LEFT", ArrowRight: "DPAD_RIGHT",
  Home: "MOVE_HOME", End: "MOVE_END", PageUp: "PAGE_UP", PageDown: "PAGE_DOWN",
  ...Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`F${i + 1}`, `F${i + 1}`])),
};
const BUTTONS: Partial<Record<ToolbarButton, string>> = {
  back: "BACK", home: "HOME", recents: "APP_SWITCH", power: "POWER", "volume-down": "VOLUME_DOWN", "volume-up": "VOLUME_UP",
};
/** Device pixels a press may move and still be a tap. */
const SLOP = 24;

type Screen = { width: number; height: number; rotation: number };

/** Logical (rotated) size and rotation of display 0. */
async function readScreen(adb: string, serial: string, env: NodeJS.ProcessEnv): Promise<Screen> {
  const viewport = await run(adb, ["-s", serial, "shell", "dumpsys display | grep -m1 'displayId=0.*logicalFrame'"], { env, timeout: 5_000 }).catch(() => "");
  const match = /orientation=(\d)[^}]*?logicalFrame=Rect\(\d+, \d+ - (\d+), (\d+)\)/.exec(viewport);
  if (match) return { rotation: Number(match[1]), width: Number(match[2]), height: Number(match[3]) };
  const size = await run(adb, ["-s", serial, "shell", "wm size"], { env, timeout: 5_000 });
  const found = /Override size: (\d+)x(\d+)/.exec(size) ?? /Physical size: (\d+)x(\d+)/.exec(size);
  if (!found) throw new Error(`Cannot read the display size of ${serial}.`);
  return { rotation: 0, width: Number(found[1]), height: Number(found[2]) };
}

/** A single-quoted argument for the device shell. */
const quote = (text: string) => `'${text.replaceAll("'", `'\\''`)}'`;

export class MirroredDevice implements Device {
  readonly label: string;
  private events?: DeviceEvents;
  private shell?: Subprocess<"pipe", "pipe", "pipe">;
  private recorder?: Subprocess<"ignore", "pipe", "pipe">;
  private box?: { width: number; height: number; onFrame: (frame: Frame | undefined) => void };
  private poll?: Timer;
  private touching?: { x: number; y: number; at: { x: number; y: number }; since: number };
  private typed = "";
  private typing?: Timer;
  private wheel?: { u: number; v: number; dx: number; dy: number; timer: Timer };
  private closing = false;

  private constructor(
    private readonly adb: string, private readonly serial: string, private readonly env: NodeJS.ProcessEnv,
    readonly title: string, private readonly sdk: number, private screen: Screen,
  ) {
    this.label = title === serial ? serial : `${title} · ${serial}`;
  }

  static async connect(adb: string, serial: string, env: NodeJS.ProcessEnv): Promise<MirroredDevice> {
    const state = await run(adb, ["-s", serial, "get-state"], { env, timeout: 5_000 }).then(text => text.trim(), error => {
      // adb names the problem (not found, unauthorized, offline) on its first line.
      const lines = errorMessage(error).split("\n");
      throw new Error(`Cannot mirror ${serial}: ${(lines[1] ?? lines[0]!).replace(/^error:\s*/, "")}`);
    });
    if (state !== "device") throw new Error(`Cannot mirror ${serial} in ${state} mode; boot it into Android first.`);
    const lines = (await run(adb, ["-s", serial, "shell", `${PRODUCT}; getprop ro.build.version.sdk`], { env, timeout: 5_000 })).split(/\r?\n/);
    return new MirroredDevice(adb, serial, env, productName(lines) ?? serial, Number(lines[2]?.trim()) || 0, await readScreen(adb, serial, env));
  }

  async open(events: DeviceEvents): Promise<void> {
    this.events = events;
    const shell = this.shell = Bun.spawn([this.adb, "-s", this.serial, "shell"], { env: { ...process.env, ...this.env }, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    // `input` prints only failures; show the latest one.
    for (const stream of [shell.stdout, shell.stderr]) this.lines(stream, line => events.status(line));
    shell.exited.then(() => { if (!this.closing) events.stop(`Lost the connection to ${this.title}.`); });
    // Rotation changes the frame's shape; restart the recording when it does.
    this.poll = setInterval(() => this.refreshScreen(), 1000);
  }

  private async lines(stream: ReadableStream<Uint8Array>, line: (text: string) => void): Promise<void> {
    const decoder = new TextDecoder();
    let pending = "";
    for await (const chunk of stream) {
      pending += decoder.decode(chunk, { stream: true });
      const parts = pending.split(/\r?\n/);
      pending = parts.pop()!;
      for (const part of parts) if (part.trim()) line(part.trim());
    }
  }

  private async refreshScreen(): Promise<void> {
    const screen = await readScreen(this.adb, this.serial, this.env).catch(() => undefined);
    if (!screen || this.closing) return;
    const resized = screen.width !== this.screen.width || screen.height !== this.screen.height;
    this.screen = screen;
    if (resized) this.record();
  }

  private command(line: string): void {
    this.flushText();
    this.shell?.stdin.write(`${line}\n`);
    this.shell?.stdin.flush();
  }

  stream(width: number, height: number, onFrame: (frame: Frame | undefined) => void): void {
    this.box = { width, height, onFrame };
    this.record();
  }

  /** (Re)starts screenrecord at the largest size of the screen's shape that fits the pane, at most native. */
  private record(): void {
    const box = this.box;
    if (!box || this.closing) return;
    this.recorder?.kill();
    const scale = Math.min(1, box.width / this.screen.width, box.height / this.screen.height);
    const width = Math.max(2, Math.floor(this.screen.width * scale / 2) * 2), height = Math.max(2, Math.floor(this.screen.height * scale / 2) * 2);
    // Without --time-limit, screenrecord stops after 3 minutes; the exit handler starts the next one.
    const recorder = this.recorder = Bun.spawn([this.adb, "-s", this.serial, "shell", "-T",
      `screenrecord --output-format=frames --size ${width}x${height} -`], { env: { ...process.env, ...this.env }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    this.frames(recorder.stdout, box.onFrame).catch(error => {
      if (this.recorder === recorder && !this.closing) this.events!.stop(`Screen recording failed: ${errorMessage(error)}`);
    });
    recorder.exited.then(async code => {
      if (this.recorder !== recorder || this.closing) return;
      if (code === 0) { this.record(); return; }
      const detail = (await Bun.readableStreamToText(recorder.stderr)).trim();
      this.events!.stop(`Screen recording on ${this.title} ended${detail ? `: ${detail}` : ` (${code}).`}`);
    });
  }

  /** Frames: u32 length, then width, height, row stride and bytes per pixel (u32 each), then pixels. */
  private async frames(stream: ReadableStream<Uint8Array>, onFrame: (frame: Frame) => void): Promise<void> {
    let parts: Buffer[] = [], have = 0, length: number | undefined;
    const take = (size: number) => {
      const all = parts.length === 1 ? parts[0]! : Buffer.concat(parts, have);
      parts = all.length > size ? [all.subarray(size)] : [];
      have = all.length - size;
      return all.subarray(0, size);
    };
    for await (const chunk of stream) {
      parts.push(Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength));
      have += chunk.byteLength;
      while (have >= (length ?? 4)) {
        if (length === undefined) { length = take(4).readUInt32LE(0); continue; }
        const body = take(length);
        length = undefined;
        const width = body.readUInt32LE(0), height = body.readUInt32LE(4), stride = body.readUInt32LE(8), depth = body.readUInt32LE(12);
        if (depth !== 3) throw new Error(`unexpected ${depth}-byte pixels`);
        let data = body.subarray(16, 16 + stride * height);
        if (stride !== width * 3) {
          const packed = Buffer.alloc(width * height * 3);
          for (let row = 0; row < height; row++) data.copy(packed, row * width * 3, row * stride, row * stride + width * 3);
          data = packed;
        }
        onFrame({ data, width, height });
      }
    }
  }

  /** A point of the latest frame (0–1 on both axes) in the device's rotated display coordinates. */
  private point(u: number, v: number) {
    const { width, height } = this.screen;
    return { x: Math.min(width - 1, Math.max(0, Math.round(u * width))), y: Math.min(height - 1, Math.max(0, Math.round(v * height))) };
  }

  touch(phase: "down" | "move" | "up", u: number, v: number, pinch: boolean): void {
    const at = this.point(u, v);
    if (phase === "down") {
      if (pinch) this.events!.status("Pinch needs an emulator; this sends one finger.");
      this.touching = { ...at, at, since: Date.now() };
      return;
    }
    const touching = this.touching;
    if (!touching) return;
    if (phase === "move") { touching.at = at; return; }
    this.touching = undefined;
    const held = Date.now() - touching.since;
    const moved = Math.hypot(at.x - touching.x, at.y - touching.y) > SLOP;
    // A held press is a swipe that stays in place: a long press.
    if (!moved && held < 400) this.command(`input tap ${touching.x} ${touching.y}`);
    else this.command(`input swipe ${touching.x} ${touching.y} ${moved ? at.x : touching.x} ${moved ? at.y : touching.y} ${Math.min(5_000, Math.max(100, held))}`);
  }

  scroll(u: number, v: number, wheel: Wheel): void {
    // Notches arriving together become one command.
    const dy = wheel === "up" ? 1 : wheel === "down" ? -1 : 0, dx = wheel === "right" ? 1 : wheel === "left" ? -1 : 0;
    if (this.wheel) { this.wheel.dx += dx; this.wheel.dy += dy; return; }
    this.wheel = { u, v, dx, dy, timer: setTimeout(() => this.flushWheel(), 120) };
  }

  private flushWheel(): void {
    const wheel = this.wheel;
    this.wheel = undefined;
    if (!wheel || (!wheel.dx && !wheel.dy)) return;
    const at = this.point(wheel.u, wheel.v);
    if (this.sdk >= 33) {
      this.command(`input mouse scroll ${at.x} ${at.y} --axis VSCROLL,${wheel.dy} --axis HSCROLL,${wheel.dx}`);
      return;
    }
    // Older releases have no scroll command: drag the content the other way, slowly enough not to fling.
    const step = Math.min(this.screen.width, this.screen.height) / 8;
    const clampX = (x: number) => Math.round(Math.min(this.screen.width - 1, Math.max(0, x)));
    const clampY = (y: number) => Math.round(Math.min(this.screen.height - 1, Math.max(0, y)));
    this.command(`input swipe ${at.x} ${at.y} ${clampX(at.x - wheel.dx * step)} ${clampY(at.y + wheel.dy * step)} 300`);
  }

  /** Sends coalesced keystrokes; spaces are %s to `input text`. */
  private flushText(): void {
    clearTimeout(this.typing);
    if (!this.typed) return;
    this.shell?.stdin.write(`input text ${quote(this.typed.replaceAll(" ", "%s"))}\n`);
    this.shell?.stdin.flush();
    this.typed = "";
  }

  /** ASCII only: `input text` types through the device's key map. */
  private type(text: string): void {
    for (const char of text) {
      if (!PRINTABLE.test(char)) { this.events!.status("Only ASCII text can be typed into a mirrored device."); continue; }
      // `input text` turns %s into a space, so a literal one goes in two commands.
      if (char === "s" && this.typed.endsWith("%")) this.flushText();
      this.typed += char;
    }
    clearTimeout(this.typing);
    this.typing = setTimeout(() => this.flushText(), 30);
  }

  key(name: string, { ctrl, alt, shift }: Modifiers): void {
    if (name.length === 1 && !ctrl && !alt) { this.type(name); return; }
    const code = name.length > 1 ? KEYCODES[name] : /^[a-z0-9]$/i.test(name) ? name.toUpperCase() : name === " " ? "SPACE" : undefined;
    if (!code) return;
    const modifiers = [ctrl && "CTRL_LEFT", alt && "ALT_LEFT", shift && name.length > 1 && "SHIFT_LEFT"].filter(Boolean);
    if (!modifiers.length) { this.command(`input keyevent KEYCODE_${code}`); return; }
    if (this.sdk < 33) { this.events!.status("Key combinations need Android 13 or later on a mirrored device."); return; }
    this.command(`input keycombination ${modifiers.map(key => `KEYCODE_${key}`).join(" ")} KEYCODE_${code}`);
  }

  paste(text: string): void {
    text.split(/\r?\n/).forEach((line, index) => {
      if (index) { this.flushText(); this.command("input keyevent KEYCODE_ENTER"); }
      this.type(line);
    });
  }

  press(button: ToolbarButton): void {
    const key = BUTTONS[button];
    if (key) { this.command(`input keyevent KEYCODE_${key}`); return; }
    // Locks the orientation: auto-rotate stays off until it is turned on again on the device. Turning
    // it off makes the window manager store the current rotation, so the fallback waits that out.
    const rotation = (this.screen.rotation + (button === "rotate-left" ? 1 : 3)) % 4;
    this.command(`wm user-rotation lock ${rotation} 2>/dev/null || { settings put system accelerometer_rotation 0; sleep 0.5; settings put system user_rotation ${rotation}; }`);
    setTimeout(() => this.refreshScreen(), 400);
  }

  async ended(): Promise<string | undefined> {
    const state = await run(this.adb, ["-s", this.serial, "get-state"], { env: this.env, timeout: 5_000 }).catch(() => "");
    return state.trim() === "device" ? undefined : `${this.title} disconnected.`;
  }

  async close(): Promise<void> {
    this.closing = true;
    clearInterval(this.poll);
    if (this.wheel) { clearTimeout(this.wheel.timer); this.flushWheel(); }
    this.flushText();
    this.recorder?.kill();
    // Ending input lets the shell run what is queued, then exit.
    this.shell?.stdin.end();
  }
}
