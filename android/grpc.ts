import http2 from "node:http2";
import { readdir, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

/** Protobuf wire encoding for the few EmulatorController messages the display uses. */
export class Proto {
  private bytes: number[] = [];
  private varint(value: number): void {
    // Negative int32 values are ten-byte two's complement varints.
    let n = value < 0 ? BigInt.asUintN(64, BigInt(value)) : BigInt(value);
    while (n > 127n) { this.bytes.push(Number(n & 127n) | 128); n >>= 7n; }
    this.bytes.push(Number(n));
  }
  int(field: number, value: number): this {
    if (value) { this.varint(field << 3); this.varint(value); }
    return this;
  }
  bytesField(field: number, value: Uint8Array): this {
    this.varint((field << 3) | 2); this.varint(value.length);
    for (const byte of value) this.bytes.push(byte);
    return this;
  }
  string(field: number, value: string): this {
    return value ? this.bytesField(field, Buffer.from(value, "utf8")) : this;
  }
  message(field: number, value: Proto): this {
    return this.bytesField(field, value.finish());
  }
  floats(field: number, values: number[]): this {
    const packed = Buffer.alloc(values.length * 4);
    values.forEach((value, index) => packed.writeFloatLE(value, index * 4));
    return this.bytesField(field, packed);
  }
  finish(): Buffer { return Buffer.from(this.bytes); }
}

export type Fields = Map<number, (number | Buffer)[]>;

export function decode(message: Buffer): Fields {
  const fields: Fields = new Map();
  let offset = 0;
  const varint = () => {
    let result = 0, scale = 1;
    for (;;) {
      if (offset >= message.length) throw new Error("Truncated protobuf varint.");
      const byte = message[offset++]!;
      result += (byte & 127) * scale;
      if (byte < 128) return result;
      scale *= 128;
    }
  };
  while (offset < message.length) {
    const key = varint();
    const field = Math.floor(key / 8);
    let value: number | Buffer;
    switch (key & 7) {
      case 0: value = varint(); break;
      case 1: value = message.readDoubleLE(offset); offset += 8; break;
      case 2: { const length = varint(); value = message.subarray(offset, offset + length); offset += length; break; }
      case 5: value = message.readFloatLE(offset); offset += 4; break;
      default: throw new Error(`Unsupported protobuf wire type ${key & 7}.`);
    }
    if (offset > message.length) throw new Error("Truncated protobuf field.");
    const values = fields.get(field);
    if (values) values.push(value); else fields.set(field, [value]);
  }
  return fields;
}

export const number = (fields: Fields, field: number) => (fields.get(field)?.at(-1) as number | undefined) ?? 0;
export const nested = (fields: Fields, field: number) => {
  const value = fields.get(field)?.at(-1);
  return Buffer.isBuffer(value) ? decode(value) : new Map() as Fields;
};
export const bytes = (fields: Fields, field: number) => {
  const value = fields.get(field)?.at(-1);
  return Buffer.isBuffer(value) ? value : Buffer.alloc(0);
};

/** An emulator's own advertisement; `port` and `token` are present only with token-authenticated gRPC. */
export type Advertisement = { serial: string; name?: string; directory?: string; pid: number; port?: number; token?: string };
export type Endpoint = Advertisement & { port: number; token: string };

/** The emulator advertises each instance in pid_<PID>.ini; this mirrors its own lookup per platform. */
function discoveryDirectory(): string {
  if (process.platform === "darwin") return path.join(os.homedir(), "Library/Caches/TemporaryItems/avd/running");
  if (process.env.XDG_RUNTIME_DIR) return path.join(process.env.XDG_RUNTIME_DIR, "avd/running");
  return path.join(os.tmpdir(), `android-${os.userInfo().username}`, "avd/running");
}

export async function advertisements(): Promise<Advertisement[]> {
  const directory = discoveryDirectory();
  const files = await readdir(directory).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return [] as string[];
    throw error;
  });
  const found: Advertisement[] = [];
  for (const file of files) {
    const pid = Number(/^pid_(\d+)\.ini$/.exec(file)?.[1]);
    if (!pid) continue;
    try { process.kill(pid, 0); } catch { continue; } // Crashed emulators leave stale advertisements.
    const text = await readFile(path.join(directory, file), "utf8").catch(() => "");
    const values = new Map(text.split(/\r?\n/).flatMap(line => {
      const index = line.indexOf("=");
      return index > 0 ? [[line.slice(0, index).trim(), line.slice(index + 1).trim()] as const] : [];
    }));
    const consolePort = values.get("port.serial");
    if (!consolePort || !/^\d+$/.test(consolePort)) continue;
    const port = Number(values.get("grpc.port"));
    found.push({
      serial: `emulator-${consolePort}`, name: values.get("avd.name"), directory: values.get("avd.dir") || undefined, pid,
      port: Number.isInteger(port) && port >= 1 && port <= 65535 ? port : undefined,
      token: values.get("grpc.token") || undefined,
    });
  }
  return found;
}

/** Selects exactly one running emulator by serial and/or AVD name; both must agree when given. */
export async function emulatorEndpoint(serial?: string, name?: string): Promise<Endpoint> {
  const matches = (await advertisements()).filter(item => (!serial || item.serial === serial) && (!name || item.name === name));
  const wanted = serial ?? name;
  if (!matches.length) throw new Error(`No running emulator matches ${wanted}${serial && name ? ` (${name})` : ""}. Start the AVD first.`);
  if (matches.length > 1) throw new Error(`Multiple emulators run ${name}. Select one with --serial: ${matches.map(item => item.serial).join(", ")}`);
  const selected = matches[0]!;
  if (!selected.port) throw new Error(`${selected.serial} does not advertise a gRPC endpoint. Update the Android Emulator, then restart the device from Tern.`);
  if (!selected.token) throw new Error(`${selected.serial} was started without token gRPC access (for example by Android Studio). Stop it, then start it from Tern to embed it.`);
  return { ...selected, port: selected.port, token: selected.token };
}

const SERVICE = "/android.emulation.control.EmulatorController/";

function frame(message: Buffer): Buffer {
  const header = Buffer.alloc(5);
  header.writeUInt32BE(message.length, 1);
  return Buffer.concat([header, message]);
}

function status(headers: http2.IncomingHttpHeaders): Error | undefined {
  const code = Number(headers["grpc-status"] ?? 0);
  if (!code) return undefined;
  const message = decodeURIComponent(String(headers["grpc-message"] ?? ""));
  return Object.assign(new Error(`Emulator gRPC error ${code}${message ? `: ${message}` : ""}`), { code });
}

/** gRPC over plaintext loopback HTTP/2, authenticated with the emulator console token. */
export class EmulatorClient {
  private readonly session: http2.ClientHttp2Session;
  private closed = false;
  constructor(private readonly endpoint: Endpoint, onClose: (error?: Error) => void) {
    this.session = http2.connect(`http://127.0.0.1:${endpoint.port}`);
    this.session.on("error", error => { if (!this.closed) onClose(error); });
    this.session.on("close", () => { if (!this.closed) onClose(); });
  }

  close(): void {
    this.closed = true;
    this.session.close();
  }

  private request(method: string): http2.ClientHttp2Stream {
    return this.session.request({
      ":method": "POST", ":path": SERVICE + method, "content-type": "application/grpc", te: "trailers",
      authorization: `Bearer ${this.endpoint.token}`,
    });
  }

  /** Decodes length-prefixed messages; trailers (or a trailers-only response) carry the status. */
  private read(stream: http2.ClientHttp2Stream, onMessage: (message: Buffer) => void, done: (error?: Error) => void): void {
    let pending = Buffer.alloc(0);
    let finished = false;
    const finish = (error?: Error) => { if (!finished) { finished = true; done(error); } };
    stream.on("response", headers => {
      if (headers[":status"] !== 200) finish(new Error(`Emulator gRPC HTTP ${headers[":status"]}`));
      else { const error = status(headers); if (error) finish(error); }
    });
    stream.on("trailers", headers => finish(status(headers)));
    stream.on("data", (chunk: Buffer) => {
      pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
      while (pending.length >= 5) {
        const length = pending.readUInt32BE(1);
        if (pending.length < 5 + length) break;
        if (pending[0]) { finish(new Error("Compressed gRPC messages are not supported.")); stream.close(); return; }
        const message = pending.subarray(5, 5 + length);
        pending = pending.subarray(5 + length);
        if (!finished) onMessage(message);
      }
    });
    stream.on("error", error => finish(error));
    stream.on("close", () => finish(finished ? undefined : new Error("Emulator gRPC stream closed.")));
  }

  unary(method: string, message: Proto = new Proto()): Promise<Fields> {
    const { promise, resolve, reject } = Promise.withResolvers<Fields>();
    const stream = this.request(method);
    let reply: Buffer | undefined;
    this.read(stream, message => { reply = message; }, error => error ? reject(error) : resolve(decode(reply ?? Buffer.alloc(0))));
    stream.end(frame(message.finish()));
    return promise;
  }

  /** Server stream; the returned function cancels it. */
  subscribe(method: string, message: Proto, onMessage: (fields: Fields) => void, done: (error?: Error) => void): () => void {
    const stream = this.request(method);
    let cancelled = false;
    this.read(stream, message => onMessage(decode(message)), error => { if (!cancelled) done(error); });
    stream.end(frame(message.finish()));
    return () => { cancelled = true; stream.close(http2.constants.NGHTTP2_CANCEL); };
  }

  /** Client stream kept open for ordered input delivery. */
  publish(method: string, done: (error?: Error) => void): { send(message: Proto): void; end(): void } {
    const stream = this.request(method);
    this.read(stream, () => {}, done);
    return {
      send: message => { if (!stream.closed && !stream.destroyed) stream.write(frame(message.finish())); },
      end: () => { if (!stream.closed) stream.end(); },
    };
  }
}
