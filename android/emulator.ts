import { readFileSync } from "node:fs";
import path from "node:path";
import type { Device, DeviceEvents, Frame, Modifiers, Wheel, ToolbarButton } from "./display";
import { EmulatorClient, Proto, bytes, decode, nested, number, type Endpoint, type Fields } from "./grpc";

/**
 * An emulator started by this helper, over its token-authenticated gRPC endpoint: frames come from
 * the screenshot stream, input goes through the ordered input stream (or unary calls without it).
 */

const HARDWARE: Partial<Record<ToolbarButton, string>> = {
  back: "GoBack", home: "GoHome", recents: "AppSwitch", power: "Power", "volume-down": "AudioVolumeDown", "volume-up": "AudioVolumeUp",
};
/** Image rotation (Rotation.SkinRotation) to the physical-model z angle the emulator window uses. */
const ANGLES = [0, 90, 180, -90];
const PRINTABLE = /^[\x20-\x7e]$/;
const WHEEL: Record<Wheel, [number, number]> = { up: [0, 120], down: [0, -120], left: [120, 0], right: [-120, 0] };

const keyEvent = (key: string, type: "down" | "up" | "press") =>
  new Proto().int(2, type === "down" ? 0 : type === "up" ? 1 : 2).string(4, key);
const textEvent = (text: string) => new Proto().int(2, 2).string(5, text);

export class EmulatorDevice implements Device {
  readonly title: string;
  readonly label: string;
  private client?: EmulatorClient;
  private input?: { send(message: Proto): void; end(): void };
  private events?: DeviceEvents;
  private native = { width: 0, height: 0 };
  /** Rotation of the latest frame; touches stay in the native (portrait) display space. */
  private rotation = 0;
  private touching?: { x: number; y: number; pinch: boolean };
  private cancelStream?: () => void;
  private readonly keyboard: boolean;

  constructor(private readonly endpoint: Endpoint) {
    this.title = endpoint.name ?? endpoint.serial;
    this.label = endpoint.name ? `${endpoint.name} · ${endpoint.serial}` : endpoint.serial;
    // The emulator writes the running device's hardware here; without hw.keyboard the guest has no
    // keyboard device and silently drops every key event, Back, Home and Power included.
    let hardware = "";
    try { if (endpoint.directory) hardware = readFileSync(path.join(endpoint.directory, "hardware-qemu.ini"), "utf8"); } catch {}
    this.keyboard = !/^hw\.keyboard\s*=\s*(false|no)\s*$/m.test(hardware);
  }

  async open(events: DeviceEvents): Promise<void> {
    this.events = events;
    const client = this.client = new EmulatorClient(this.endpoint, error => events.stop(error ? `Lost the emulator connection: ${error.message}` : undefined));
    this.input = client.publish("streamInputEvent", error => {
      // Emulators without the ordered input stream still take unary touch, mouse and key events.
      this.input = undefined;
      if (error) events.status(`Input stream unavailable (${error.message}); using single events.`);
    });
    // DisplayConfigurations.displays; display 0 omits its id field.
    const configurations = await client.unary("getDisplayConfigurations");
    const primary = (configurations.get(1) ?? []).flatMap(value => Buffer.isBuffer(value) ? [decode(value)] : [])
      .find(fields => number(fields, 5) === 0);
    if (primary) this.native = { width: number(primary, 1), height: number(primary, 2) };
    if (!this.native.width || !this.native.height) throw new Error("The emulator reported no display size.");
  }

  stream(width: number, height: number, onFrame: (frame: Frame | undefined) => void): void {
    this.cancelStream?.();
    // RGB888 at the pane's pixel size: the emulator scales, keeping the device aspect ratio.
    this.cancelStream = this.client!.subscribe("streamScreenshot", new Proto().int(1, 2).int(3, width).int(4, height), (image: Fields) => {
      const format = nested(image, 1);
      const frameWidth = number(format, 3), frameHeight = number(format, 4), data = bytes(image, 4);
      if (!frameWidth || !frameHeight) { onFrame(undefined); return; }
      if (data.length !== frameWidth * frameHeight * 3) return;
      this.rotation = number(nested(format, 2), 1);
      onFrame({ data, width: frameWidth, height: frameHeight });
    }, error => this.events!.stop(error ? `Screen stream ended: ${error.message}` : undefined));
  }

  private send(field: 1 | 2 | 3 | 6, event: Proto): void {
    if (field === 1 && !this.keyboard) {
      this.events!.status(`No keyboard input: set hw.keyboard = yes for ${this.title} and restart it.`);
      return;
    }
    if (this.input) { this.input.send(new Proto().message(field, event)); return; }
    const method = field === 1 ? "sendKey" : field === 2 ? "sendTouch" : field === 3 ? "sendMouse" : undefined;
    if (method) this.client!.unary(method, event).catch(error => this.events!.status(`Input failed: ${error.message}`));
  }

  /** A point of the latest frame (0–1 on both axes) in native display coordinates. */
  private point(u: number, v: number) {
    const { width: w, height: h } = this.native;
    const r = this.rotation;
    const ix = u * (r % 2 ? h : w), iy = v * (r % 2 ? w : h);
    const [x, y] = r === 1 ? [w - iy, ix] : r === 2 ? [w - ix, h - iy] : r === 3 ? [iy, h - ix] : [ix, iy];
    return { x: Math.min(w - 1, Math.max(0, Math.round(x))), y: Math.min(h - 1, Math.max(0, Math.round(y))) };
  }

  private contact(x: number, y: number, pressure: number, pinch: boolean): void {
    const event = new Proto().message(1, new Proto().int(1, x).int(2, y).int(3, 1).int(4, pressure).int(7, 1));
    // Alt+drag adds a second finger mirrored through the screen's center: pinch and rotate.
    if (pinch) event.message(1, new Proto().int(1, this.native.width - 1 - x).int(2, this.native.height - 1 - y).int(3, 2).int(4, pressure).int(7, 1));
    this.send(2, event);
  }

  touch(phase: "down" | "move" | "up", u: number, v: number, pinch: boolean): void {
    const at = this.point(u, v);
    if (phase === "down") { this.touching = { ...at, pinch }; this.contact(at.x, at.y, 1, pinch); return; }
    const touching = this.touching;
    if (!touching) return;
    if (phase === "up") { this.contact(at.x, at.y, 0, touching.pinch); this.touching = undefined; return; }
    if (at.x === touching.x && at.y === touching.y) return;
    this.touching = { ...at, pinch: touching.pinch };
    this.contact(at.x, at.y, 1, touching.pinch);
  }

  scroll(u: number, v: number, wheel: Wheel): void {
    // Android scrolls under its mouse pointer, so move it there first. 120 = one wheel notch.
    const at = this.point(u, v);
    this.send(3, new Proto().int(1, at.x).int(2, at.y));
    const [dx, dy] = WHEEL[wheel];
    this.send(6, new Proto().int(1, dx).int(2, dy));
  }

  /**
   * Every key goes as a whole press with its modifiers. Terminals that report no releases (Tern
   * among them) would otherwise leave a key down, which the device auto-repeats.
   */
  key(name: string, { ctrl, alt, shift }: Modifiers): void {
    // Characters arrive already shifted and the emulator adds Shift itself; named keys need it.
    const shifted = shift && name.length > 1;
    if (ctrl) this.send(1, keyEvent("Control", "down"));
    if (alt) this.send(1, keyEvent("Alt", "down"));
    if (shifted) this.send(1, keyEvent("Shift", "down"));
    this.send(1, name.length === 1 && !PRINTABLE.test(name) ? textEvent(name) : keyEvent(name, "press"));
    if (shifted) this.send(1, keyEvent("Shift", "up"));
    if (alt) this.send(1, keyEvent("Alt", "up"));
    if (ctrl) this.send(1, keyEvent("Control", "up"));
  }

  paste(text: string): void {
    // ClipData carries any Unicode text; Ctrl+V pastes it into the focused field.
    this.client!.unary("setClipboard", new Proto().string(1, text)).then(() => {
      this.send(1, keyEvent("Control", "down")); this.send(1, keyEvent("v", "press")); this.send(1, keyEvent("Control", "up"));
    }, error => this.events!.status(`Paste failed: ${error.message}`));
  }

  press(button: ToolbarButton): void {
    const key = HARDWARE[button];
    if (key) { this.send(1, keyEvent(key, "press")); return; }
    const angle = ANGLES[this.rotation]! + (button === "rotate-left" ? 90 : -90);
    const z = angle > 180 ? angle - 360 : angle <= -180 ? angle + 360 : angle;
    this.client!.unary("setPhysicalModel", new Proto().int(1, 1).message(3, new Proto().floats(1, [0, 0, z])))
      .catch(error => this.events!.status(`Rotation failed: ${error.message}`));
  }

  private alive(): boolean {
    try { process.kill(this.endpoint.pid, 0); return true; } catch { return false; }
  }

  async ended(waiting: () => boolean): Promise<string | undefined> {
    // A stopping emulator drops gRPC before its process exits, which may first save a snapshot.
    for (const deadline = Date.now() + 15_000; waiting() && this.alive() && Date.now() < deadline;) await Bun.sleep(200);
    return this.alive() ? undefined : `${this.title} stopped.`;
  }

  async close(): Promise<void> {
    if (this.touching) { this.contact(this.touching.x, this.touching.y, 0, this.touching.pinch); this.touching = undefined; }
    this.cancelStream?.();
    this.input?.end();
    // Lets pending input reach the emulator before the connection closes.
    await Bun.sleep(100);
    this.client?.close();
  }
}
