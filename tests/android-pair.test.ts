import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { parseBrowse, parseMdnsServices, parsePaired, qrPayload } from "../android/pair";
import { encodeQr } from "../android/qr";

describe("parseMdnsServices", () => {
  test("keeps only NAME, TYPE and HOST:PORT rows", () => {
    const text = "List of discovered mdns services\n"
      + "adb-34181194-yXq2ib\t_adb-tls-connect._tcp\t192.168.1.23:43999\n"
      + "elide-Ab12Cd34Ef\t_adb-tls-pairing._tcp.\t192.168.1.23:37115\n"
      + "not a service\n"
      + "\tx\t1.2.3.4:5\n"
      + "name\t_adb-tls-pairing._tcp\tno-port\n";
    expect(parseMdnsServices(text)).toEqual([
      { name: "adb-34181194-yXq2ib", type: "_adb-tls-connect._tcp", address: "192.168.1.23:43999" },
      { name: "elide-Ab12Cd34Ef", type: "_adb-tls-pairing._tcp", address: "192.168.1.23:37115" },
    ]);
  });
});

describe("parseBrowse", () => {
  test("reads dns-sd's Add and Rmv rows, and nothing else", () => {
    expect(parseBrowse("17:17:33.351  Add        2  14 local.               _adb-tls-pairing._tcp. elide-ZJDCmfiH0Z"))
      .toEqual({ added: true, iface: "14", type: "_adb-tls-pairing._tcp", name: "elide-ZJDCmfiH0Z" });
    expect(parseBrowse("17:18:01.002  Rmv        0  14 local.               _adb-tls-connect._tcp. Pixel 8 (2)"))
      .toEqual({ added: false, iface: "14", type: "_adb-tls-connect._tcp", name: "Pixel 8 (2)" });
    for (const line of ["Browsing for _adb-tls-pairing._tcp.local.", "DATE: ---Wed 18 Nov 2026---",
      "17:17:33.351  ...STARTING...", "Timestamp     A/R    Flags  if Domain               Service Type         Instance Name"]) {
      expect(parseBrowse(line)).toBeUndefined();
    }
  });
});

describe("parsePaired", () => {
  test("reads the address and GUID of a successful pairing", () => {
    expect(parsePaired("Successfully paired to 192.168.1.23:37115 [guid=adb-34181194-yXq2ib]\n"))
      .toEqual({ address: "192.168.1.23:37115", guid: "adb-34181194-yXq2ib" });
  });

  test("a refused pairing is no success, although adb exits 0", () => {
    expect(parsePaired("Failed: Wrong password or connection was dropped.\n")).toBeUndefined();
  });
});

describe("QR code", () => {
  test("encodes the Wireless debugging payload into a symbol that decodes", () => {
    const payload = qrPayload("elide-Ab12Cd34Ef", "Zx9Yw8Vu7Ts6");
    expect(payload).toBe("WIFI:T:ADB;S:elide-Ab12Cd34Ef;P:Zx9Yw8Vu7Ts6;;");
    const rows = encodeQr(payload);
    expect(rows).toHaveLength(29);
    for (const row of rows) expect(row).toMatch(/^[01]{29}$/);
    // macOS CoreImage decoded this matrix to the payload.
    expect(createHash("sha256").update(rows.join("\n")).digest("hex"))
      .toBe("6eec4ec718561f11ed92ce1d2e45b68433a2bf35657343e5497410a910509618");
  });

  test("refuses a text longer than the symbol holds", () => {
    expect(() => encodeQr("x".repeat(54))).toThrow();
  });
});
