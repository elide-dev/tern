import { spawn } from "node:child_process";
import { randomInt } from "node:crypto";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import { whichExecutable } from "./elide";
import { errorMessage, run } from "./process";
import { encodeQr } from "./qr";
import type { AndroidSdk, Physical } from "./sdk";

/** The mDNS service a device advertises while it shows a Wi-Fi pairing code or waits for a QR scan. */
export const PAIRING_SERVICE = "_adb-tls-pairing._tcp";

export type MdnsService = { name: string; type: string; address: string };
export type PairingEvent =
  | { event: "ready"; service: string; qr: string[] }
  | { event: "devices"; devices: { name: string; address: string }[] }
  | { event: "pairing"; address: string }
  | { event: "paired"; address: string; guid: string }
  | { event: "connected"; serial: string; name?: string }
  | { event: "failed"; message: string }
  | { event: "discovery"; blocked: boolean; message?: string };

const ALPHANUMERIC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const CONNECT_TIMEOUT = 30_000;
/** How long adb may lag behind Bonjour in seeing a service before its discovery counts as blocked. */
const BLIND_AFTER = 5_000;
const BLOCKED = "macOS is keeping adb from finding devices on this network: Bonjour sees a device waiting to pair that adb does not. "
  + "adb needs the Local Network permission of the app that started it. In System Settings › Privacy & Security › "
  + "Local Network, turn on Tern (and Android Studio, if you use it), then run adb kill-server.";

/** Rows of `adb mdns services` (`NAME<TAB>TYPE<TAB>HOST:PORT`); its header and anything else yield nothing. */
export function parseMdnsServices(text: string): MdnsService[] {
  const services: MdnsService[] = [];
  for (const line of text.split(/\r?\n/)) {
    const parts = line.trim().split("\t");
    if (parts.length !== 3) continue;
    const [name, type, address] = parts as [string, string, string];
    if (!name || !/^\S+:\d{1,5}$/.test(address)) continue;
    services.push({ name, type: type.replace(/\.$/, ""), address });
  }
  return services;
}

/** A `dns-sd -B` row: a service one interface (`iface`) added or removed. */
export function parseBrowse(line: string): { added: boolean; iface: string; type: string; name: string } | undefined {
  const match = /^\d{1,2}:\d{2}:\d{2}\.\d{3}\s+(Add|Rmv)\s+\d+\s+(\d+)\s+\S+\s+(\S+)\s+(.+?)\s*$/.exec(line);
  return match ? { added: match[1] === "Add", iface: match[2]!, type: match[3]!.replace(/\.$/, ""), name: match[4]! } : undefined;
}

/**
 * The adb services of `type` macOS's Bonjour (mDNSResponder) sees, by instance name, with when
 * each was first seen. mDNSResponder browses for every app, so it sees devices even when Local
 * Network privacy keeps an adb server from receiving multicast: the server has the permission of
 * the app that started it, and macOS grants it only to Terminal by default.
 */
function watchBonjour(dnsSd: string, type: string): { seen: Map<string, number>; stop: () => void } {
  const seen = new Map<string, number>();
  const records = new Set<string>();
  const child = spawn(dnsSd, ["-B", type, "local."], { stdio: ["ignore", "pipe", "ignore"] });
  child.once("error", () => {});
  createInterface({ input: child.stdout }).on("line", line => {
    const row = parseBrowse(line);
    if (!row || row.type !== type) return;
    const record = `${row.iface}\t${row.name}`;
    if (row.added) {
      records.add(record);
      if (!seen.has(row.name)) seen.set(row.name, Date.now());
    } else {
      records.delete(record);
      if (![...records].some(other => other.endsWith(`\t${row.name}`))) seen.delete(row.name);
    }
  });
  return { seen, stop: () => child.kill() };
}

/** The address and device GUID `adb pair` reports on success. */
export function parsePaired(text: string): { address: string; guid: string } | undefined {
  const match = /Successfully paired to (\S+) \[guid=([^\]\s]+)\]/.exec(text);
  return match ? { address: match[1]!, guid: match[2]! } : undefined;
}

/** The text of the QR code Android's Wireless debugging scanner reads. */
export function qrPayload(service: string, password: string): string {
  return `WIFI:T:ADB;S:${service};P:${password};;`;
}

function randomText(length: number): string {
  let text = "";
  for (let i = 0; i < length; i++) text += ALPHANUMERIC[randomInt(ALPHANUMERIC.length)];
  return text;
}

async function adb(sdk: AndroidSdk, args: string[], timeout: number): Promise<string> {
  return run(await sdk.tool("adb"), args, { env: sdk.env, timeout });
}

/** `adb pair`; adb can exit 0 on a refused pairing, so only its success line counts. */
export async function pairDevice(sdk: AndroidSdk, address: string, secret: string): Promise<{ address: string; guid: string }> {
  const text = await adb(sdk, ["pair", address, secret], 30_000);
  const paired = parsePaired(text);
  if (paired) return paired;
  throw new Error(`Pairing with ${address} failed: ${text.trim().replace(/^Failed:\s*/, "") || "adb reported nothing"}`);
}

/**
 * The device paired as `guid` once adb lists it ready. adb connects paired devices it discovers
 * by itself (ADB_MDNS_AUTO_CONNECT); an explicit `adb connect` would attach the phone a second
 * time under HOST:PORT.
 */
export async function awaitConnected(sdk: AndroidSdk, guid: string, signal?: AbortSignal): Promise<Physical | undefined> {
  const deadline = Date.now() + CONNECT_TIMEOUT;
  while (Date.now() < deadline && !signal?.aborted) {
    const device = (await sdk.attached().catch(() => [])).find(device =>
      !device.emulator && device.ready && (device.serial === guid || device.serial.startsWith(`${guid}.`)));
    if (device) return sdk.describe(device);
    await delay(500, undefined, { signal }).catch(() => {});
  }
  return undefined;
}

/** Pairs with a device that shows a pairing code, then waits for it to connect. */
export async function pairWithCode(sdk: AndroidSdk, address: string, code: string): Promise<Record<string, unknown>> {
  const { guid } = await pairDevice(sdk, address, code);
  const device = await awaitConnected(sdk, guid);
  if (device) return { message: `Connected ${device.name ?? device.serial} over Wi-Fi.`, ...device };
  return { message: `Paired with ${address}, but the device has not connected yet. Keep Wireless debugging on, then refresh.` };
}

/**
 * Advertises a QR code for Android's "Pair device with QR code" and reports the devices that
 * show a pairing code, until a device that scanned the code connects or `signal` aborts. On
 * macOS it also reports whether Local Network privacy blinds adb's discovery.
 */
export async function runPairing(sdk: AndroidSdk, emit: (event: PairingEvent) => void, signal: AbortSignal): Promise<void> {
  const check = await adb(sdk, ["mdns", "check"], 10_000).catch(error => errorMessage(error));
  if (!check.includes("mdns daemon version")) {
    throw new Error(`adb cannot discover devices on the network (mDNS is unavailable). Update Android SDK Platform-Tools in ${sdk.root}.`);
  }
  // Alphanumeric, so the WIFI: payload needs no escaping. The password never leaves this process.
  const service = `elide-${randomText(10)}`;
  const password = randomText(12);
  emit({ event: "ready", service, qr: encodeQr(qrPayload(service, password)) });
  const dnsSd = process.platform === "darwin" ? whichExecutable("dns-sd") : undefined;
  // Pairing services only: adb stops listing the connect service of a device once it connected.
  const bonjour = dnsSd ? watchBonjour(dnsSd, PAIRING_SERVICE) : undefined;
  const tried = new Set<string>();
  let last = "[]";
  let blocked = false;
  try {
    while (!signal.aborted) {
      const text = await adb(sdk, ["mdns", "services"], 5_000).catch(() => undefined);
      const discovered = parseMdnsServices(text ?? "");
      if (bonjour && text !== undefined) {
        const known = new Set(discovered.map(entry => entry.name));
        const now = Date.now();
        const missed = [...bonjour.seen].some(([name, since]) => !known.has(name) && now - since >= BLIND_AFTER);
        if (missed !== blocked) {
          blocked = missed;
          emit({ event: "discovery", blocked, ...(blocked ? { message: BLOCKED } : {}) });
        }
      }
      const services = discovered.filter(entry => entry.type === PAIRING_SERVICE);
      // Devices showing a pairing code; `elide-`/`studio-` names are QR sessions of this plugin or Android Studio.
      const devices = services.filter(entry => !/^(elide|studio)-/.test(entry.name)).map(({ name, address }) => ({ name, address }));
      const listed = JSON.stringify(devices);
      if (listed !== last) {
        last = listed;
        emit({ event: "devices", devices });
      }
      // A rescan on the device advertises a new port; a stale record is not retried.
      const ours = services.find(entry => entry.name === service && !tried.has(entry.address));
      if (ours) {
        const { address } = ours;
        tried.add(address);
        emit({ event: "pairing", address });
        try {
          const { guid } = await pairDevice(sdk, address, password);
          emit({ event: "paired", address, guid });
          const device = await awaitConnected(sdk, guid, signal);
          if (device) {
            emit({ event: "connected", serial: device.serial, ...(device.name ? { name: device.name } : {}) });
            return;
          }
          emit({ event: "failed", message: `Paired with ${address}, but the device has not connected yet. Keep Wireless debugging on; it appears in the device list once it connects.` });
        } catch (error) {
          emit({ event: "failed", message: errorMessage(error) });
        }
      }
      await delay(1000, undefined, { signal }).catch(() => {});
    }
  } finally {
    bonjour?.stop();
  }
}
