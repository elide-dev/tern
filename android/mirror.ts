import type { Subprocess } from "bun";
import type { Device, DeviceEvents, Frame, Modifiers, ToolbarButton, Wheel } from "./display";
import { errorMessage, run } from "./process";
import { PRODUCT, productName } from "./sdk";

/**
 * Mirrors an attached device over adb alone, with nothing installed on it. With ffmpeg on the
 * host, frames come from `screenrecord --output-format=h264`: the device's hardware encoder
 * reads the screen in real time and ffmpeg decodes it here. Without ffmpeg they come from
 * `--output-format=frames`, which reads every frame back from the GPU and writes it raw through
 * adb; screenrecord takes one frame at a time, so once it falls behind, SurfaceFlinger waits on
 * its buffers and the device's own frame rate drops to the mirror's. Those frames are kept
 * small and scaled up here. Input goes through `input` commands in one long-lived shell. Each
 * command starts a process on the device, so a drag is sent as one swipe when it ends rather
 * than followed live.
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
/** Read-back frames of at most this many pixels, about 1 MB, keep up at ~30 fps over USB 2. */
const RAW_FRAME_PIXELS = 360_000;
/** screenrecord's own size for when the encoder rejects the display's: its longest side. */
const FALLBACK_SIDE = 1280;
/** screenrecord flushes each access unit whole; a pause this long (ms) ends one. */
const UNIT_GAP = 4;
/** An access unit delimiter: makes ffmpeg's parser hand over the unit before it. */
const DELIMITER = new Uint8Array([0, 0, 0, 1, 9, 0xf0]);

type Size = { width: number; height: number };

type Screen = Size & { rotation: number };

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

/** Whether bytes can open a NAL unit: start with a start code, as far as they go. */
const opensUnit = (bytes: Uint8Array) => [[0, 0, 1], [0, 0, 0, 1]].some(code => code.every((byte, i) => i >= bytes.length || bytes[i] === byte));

/** Nearest-neighbour scaling of packed RGB. */
function scaleRgb(data: Buffer, from: Size, to: Size): Buffer {
  const out = Buffer.allocUnsafe(to.width * to.height * 3), rowBytes = to.width * 3;
  const columns = Uint32Array.from({ length: to.width }, (_, x) => Math.floor(x * from.width / to.width) * 3);
  let previous = -1;
  for (let y = 0; y < to.height; y++) {
    const row = y * rowBytes, source = Math.floor(y * from.height / to.height);
    if (source === previous) { out.copyWithin(row, row - rowBytes, row); continue; }
    previous = source;
    const base = source * from.width * 3;
    for (let x = 0, at = row; x < to.width; x++, at += 3) {
      const from = base + columns[x]!;
      out[at] = data[from]!; out[at + 1] = data[from + 1]!; out[at + 2] = data[from + 2]!;
    }
  }
  return out;
}

/** Splits a stream into consecutive records; `size` gives the next record's length in bytes. */
async function readRecords(stream: ReadableStream<Uint8Array>, size: () => number, record: (bytes: Buffer) => void): Promise<void> {
  let parts: Buffer[] = [], have = 0;
  for await (const chunk of stream) {
    parts.push(Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength));
    have += chunk.byteLength;
    for (let next = size(); have >= next; next = size()) {
      const all = parts.length === 1 ? parts[0]! : Buffer.concat(parts, have);
      parts = all.length > next ? [all.subarray(next)] : [];
      have = all.length - next;
      record(all.subarray(0, next));
    }
  }
}

export class MirroredDevice implements Device {
  readonly label: string;
  private events?: DeviceEvents;
  private shell?: Subprocess<"pipe", "pipe", "pipe">;
  private recorder?: Subprocess<"ignore", "pipe", "pipe">;
  private decoder?: Subprocess<"pipe", "pipe", "pipe">;
  /** ffmpeg on the host; dropped when the device's encoder cannot stream at all. */
  private ffmpeg?: string;
  /** Longest side asked of the encoder; lowered once when it rejects a size. */
  private encoderSide = Infinity;
  private box?: Size & { onFrame: (frame: Frame | undefined) => void };
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
    this.ffmpeg = Bun.which("ffmpeg", { PATH: env.PATH ?? process.env.PATH ?? "" }) ?? undefined;
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
    if (!this.ffmpeg) events.status("Install ffmpeg for a smooth mirror; without it, mirroring slows the device.");
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

  /**
   * (Re)starts screenrecord at the largest size of the screen's shape that fits the pane, at most
   * native: H.264 when ffmpeg can decode it, else read-back frames of at most RAW_FRAME_PIXELS.
   */
  private record(): void {
    const box = this.box;
    if (!box || this.closing) return;
    this.recorder?.kill();
    this.decoder?.kill();
    const { width, height } = this.screen;
    const fit = Math.min(1, box.width / width, box.height / height);
    // Encoders take sizes in steps of 8, read-back frames any even size.
    const sized = (scale: number, step: number): Size => ({
      width: Math.max(step, Math.floor(width * scale / step) * step), height: Math.max(step, Math.floor(height * scale / step) * step),
    });
    const video = this.ffmpeg ? sized(Math.min(fit, this.encoderSide / Math.max(width, height)), 8) : undefined;
    const sent = video ?? sized(Math.min(fit, Math.sqrt(RAW_FRAME_PIXELS / (width * height))), 2);
    // Without --time-limit, screenrecord stops after 3 minutes; the exit handler starts the next one.
    const recorder = this.recorder = Bun.spawn([this.adb, "-s", this.serial, "shell", "-T",
      `screenrecord --output-format=${video ? "h264" : "frames"} --size ${sent.width}x${sent.height} -`], { env: { ...process.env, ...this.env }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    let shown = false;
    const onFrame = (frame: Frame) => { shown = true; box.onFrame(frame); };
    (video ? this.decode(recorder, video, onFrame) : this.frames(recorder.stdout, sized(fit, 2), onFrame)).catch(error => {
      if (this.recorder === recorder && !this.closing) this.events!.stop(`Screen recording failed: ${errorMessage(error)}`);
    });
    recorder.exited.then(async code => {
      if (this.recorder !== recorder || this.closing) return;
      if (code === 0) { this.record(); return; }
      const detail = (await Bun.readableStreamToText(recorder.stderr)).trim();
      // The encoder may reject the size: retry at screenrecord's own fallback size, then read frames back.
      if (video && !shown) {
        if (Math.max(video.width, video.height) > FALLBACK_SIDE) this.encoderSide = FALLBACK_SIDE;
        else {
          this.ffmpeg = undefined;
          this.events!.status(`${this.title} cannot stream H.264${detail ? ` (${detail})` : ""}; mirroring slows the device.`);
        }
        this.record();
        return;
      }
      this.events!.stop(`Screen recording on ${this.title} ended${detail ? `: ${detail}` : ` (${code}).`}`);
    });
  }

  /** Decodes the recorder's H.264 into RGB frames of `size` with ffmpeg. */
  private async decode(recorder: Subprocess<"ignore", "pipe", "pipe">, size: Size, onFrame: (frame: Frame) => void): Promise<void> {
    const decoder = this.decoder = Bun.spawn([this.ffmpeg!, "-hide_banner", "-loglevel", "error",
      // Each frame leaves as soon as it is complete: no probing, frame threads or buffered output.
      "-probesize", "32", "-analyzeduration", "0", "-flags", "low_delay", "-threads", "1", "-f", "h264", "-i", "pipe:0",
      "-threads", "1", "-s", `${size.width}x${size.height}`, "-pix_fmt", "rgb24", "-f", "rawvideo", "-flush_packets", "1", "pipe:1",
    ], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    let failure = "";
    const drained = this.lines(decoder.stderr, line => { failure = line; });
    await Promise.all([this.feed(recorder, decoder), readRecords(decoder.stdout, () => size.width * size.height * 3, data => onFrame({ data, ...size }))]);
    const code = await decoder.exited;
    await drained;
    if (code && this.decoder === decoder) throw new Error(failure || `ffmpeg exited with ${code}`);
  }

  /**
   * Pipes the recorder's H.264 to the decoder. ffmpeg's parser holds each access unit until the
   * next one begins, and screenrecord sends one only when the screen changes, so the latest
   * change would wait for the next: a pause in the bytes ends the unit with a delimiter. A unit
   * that pauses part-way (a slow link) is split, which the following bytes show by not opening a
   * NAL unit; a new recording then starts again from a key frame.
   */
  private async feed(recorder: Subprocess<"ignore", "pipe", "pipe">, decoder: Subprocess<"pipe", "pipe", "pipe">): Promise<void> {
    // A decoder that died is reported by `decode`; here writing to it only stops.
    const send = (bytes: Uint8Array) => {
      try { decoder.stdin.write(bytes); decoder.stdin.flush(); return true; } catch { return false; }
    };
    let pause: Timer | undefined, delimited = false;
    try {
      for await (const chunk of recorder.stdout) {
        clearTimeout(pause);
        if (delimited && !opensUnit(chunk)) {
          if (this.recorder === recorder && !this.closing) this.record();
          return;
        }
        delimited = false;
        if (!send(chunk)) return;
        pause = setTimeout(() => { delimited = send(DELIMITER); }, UNIT_GAP);
      }
    } finally {
      clearTimeout(pause);
    }
    try { decoder.stdin.end(); } catch {}
  }

  /**
   * Frames: u32 length, then width, height, row stride and bytes per pixel (u32 each), then
   * pixels; scaled up to `shown`.
   */
  private async frames(stream: ReadableStream<Uint8Array>, shown: Size, onFrame: (frame: Frame) => void): Promise<void> {
    let length: number | undefined;
    await readRecords(stream, () => length ?? 4, body => {
      if (length === undefined) { length = body.readUInt32LE(0); return; }
      length = undefined;
      const width = body.readUInt32LE(0), height = body.readUInt32LE(4), stride = body.readUInt32LE(8), depth = body.readUInt32LE(12);
      if (depth !== 3) throw new Error(`unexpected ${depth}-byte pixels`);
      let data = body.subarray(16, 16 + stride * height);
      if (stride !== width * 3) {
        const packed = Buffer.alloc(width * height * 3);
        for (let row = 0; row < height; row++) data.copy(packed, row * width * 3, row * stride, row * stride + width * 3);
        data = packed;
      }
      onFrame(width === shown.width && height === shown.height ? { data, width, height } : { data: scaleRgb(data, { width, height }, shown), ...shown });
    });
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
    this.decoder?.kill();
    // Ending input lets the shell run what is queued, then exit.
    this.shell?.stdin.end();
  }
}
