/** QR Code symbols for short texts: version 3 (29×29 modules), error correction level L, byte mode. */
const SIZE = 29;
const DATA_CODEWORDS = 55;
const ECC_CODEWORDS = 15;
/** Bytes a symbol holds: the data codewords less the 4-bit mode and 8-bit length. */
export const QR_CAPACITY = 53;

/** Product in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1. */
function multiply(x: number, y: number): number {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

/** Reed–Solomon remainder of `data` for the generator with roots α^0…α^14. */
function errorCorrection(data: number[]): number[] {
  const generator = new Array<number>(ECC_CODEWORDS).fill(0);
  generator[ECC_CODEWORDS - 1] = 1;
  let root = 1;
  for (let i = 0; i < ECC_CODEWORDS; i++) {
    for (let j = 0; j < ECC_CODEWORDS; j++) {
      generator[j] = multiply(generator[j]!, root) ^ (generator[j + 1] ?? 0);
    }
    root = multiply(root, 2);
  }
  const remainder = new Array<number>(ECC_CODEWORDS).fill(0);
  for (const byte of data) {
    const factor = byte ^ remainder.shift()!;
    remainder.push(0);
    for (let i = 0; i < ECC_CODEWORDS; i++) remainder[i]! ^= multiply(generator[i]!, factor);
  }
  return remainder;
}

function codewords(bytes: Uint8Array): number[] {
  if (bytes.length > QR_CAPACITY) throw new Error(`A QR code here holds ${QR_CAPACITY} bytes, not ${bytes.length}.`);
  const bits: number[] = [];
  const push = (value: number, length: number) => {
    for (let i = length - 1; i >= 0; i--) bits.push((value >>> i) & 1);
  };
  push(0b0100, 4);
  push(bytes.length, 8);
  for (const byte of bytes) push(byte, 8);
  push(0, Math.min(4, DATA_CODEWORDS * 8 - bits.length));
  push(0, (8 - (bits.length % 8)) % 8);
  for (let pad = 0xec; bits.length < DATA_CODEWORDS * 8; pad ^= 0xec ^ 0x11) push(pad, 8);
  const data: number[] = [];
  for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((byte, bit) => (byte << 1) | bit, 0));
  return [...data, ...errorCorrection(data)];
}

const MASKS: ((x: number, y: number) => boolean)[] = [
  (x, y) => (x + y) % 2 === 0,
  (_, y) => y % 2 === 0,
  x => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
  (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
  (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

/** The standard's four penalties; rows and columns are both scanned. */
function penalty(modules: boolean[][]): number {
  let result = 0;
  let dark = 0;
  const lines: string[] = [];
  for (let i = 0; i < SIZE; i++) {
    let row = "";
    let column = "";
    for (let j = 0; j < SIZE; j++) {
      row += modules[i]![j] ? "1" : "0";
      column += modules[j]![i] ? "1" : "0";
      if (modules[i]![j]) dark++;
    }
    lines.push(row, column);
  }
  for (const line of lines) {
    for (const run of line.match(/0{5,}|1{5,}/g) ?? []) result += run.length - 2;
    for (const pattern of ["10111010000", "00001011101"]) {
      for (let at = line.indexOf(pattern); at >= 0; at = line.indexOf(pattern, at + 1)) result += 40;
    }
  }
  for (let y = 0; y < SIZE - 1; y++) {
    for (let x = 0; x < SIZE - 1; x++) {
      const color = modules[y]![x];
      if (color === modules[y]![x + 1] && color === modules[y + 1]![x] && color === modules[y + 1]![x + 1]) result += 3;
    }
  }
  return result + Math.floor(Math.abs(dark * 20 - SIZE * SIZE * 10) / (SIZE * SIZE)) * 10;
}

/** The symbol for `text` (at most 53 UTF-8 bytes): 29 rows of 29 characters, `1` a dark module, without a quiet zone. */
export function encodeQr(text: string): string[] {
  const stream = codewords(new TextEncoder().encode(text));
  const modules = Array.from({ length: SIZE }, () => new Array<boolean>(SIZE).fill(false));
  const fixed = Array.from({ length: SIZE }, () => new Array<boolean>(SIZE).fill(false));
  const set = (x: number, y: number, dark: boolean) => {
    modules[y]![x] = dark;
    fixed[y]![x] = true;
  };
  for (let i = 0; i < SIZE; i++) {
    set(6, i, i % 2 === 0);
    set(i, 6, i % 2 === 0);
  }
  // Finder patterns with their separators, then the one alignment pattern.
  for (const [cx, cy] of [[3, 3], [SIZE - 4, 3], [3, SIZE - 4]] as const) {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx;
        const y = cy + dy;
        const ring = Math.max(Math.abs(dx), Math.abs(dy));
        if (x >= 0 && x < SIZE && y >= 0 && y < SIZE) set(x, y, ring !== 2 && ring !== 4);
      }
    }
  }
  for (let dy = -2; dy <= 2; dy++) {
    for (let dx = -2; dx <= 2; dx++) set(22 + dx, 22 + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }
  // Level L and the mask number, BCH(15,5)-protected, in both copies; also the always-dark module.
  const format = (mask: number) => {
    const data = (0b01 << 3) | mask;
    let remainder = data;
    for (let i = 0; i < 10; i++) remainder = (remainder << 1) ^ ((remainder >>> 9) * 0x537);
    const bits = ((data << 10) | remainder) ^ 0x5412;
    const bit = (i: number) => ((bits >>> i) & 1) !== 0;
    for (let i = 0; i <= 5; i++) set(8, i, bit(i));
    set(8, 7, bit(6));
    set(8, 8, bit(7));
    set(7, 8, bit(8));
    for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) set(SIZE - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) set(8, SIZE - 15 + i, bit(i));
    set(8, SIZE - 8, true);
  };
  format(0);
  // Codewords zigzag up and down column pairs from the bottom right, skipping the timing column.
  let index = 0;
  for (let right = SIZE - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let step = 0; step < SIZE; step++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const y = ((right + 1) & 2) === 0 ? SIZE - 1 - step : step;
        if (fixed[y]![x] || index >= stream.length * 8) continue;
        modules[y]![x] = ((stream[index >>> 3]! >>> (7 - (index & 7))) & 1) !== 0;
        index++;
      }
    }
  }
  const apply = (mask: number) => {
    for (let y = 0; y < SIZE; y++) {
      for (let x = 0; x < SIZE; x++) if (!fixed[y]![x] && MASKS[mask]!(x, y)) modules[y]![x] = !modules[y]![x];
    }
  };
  let best = 0;
  let least = Infinity;
  for (let mask = 0; mask < MASKS.length; mask++) {
    apply(mask);
    format(mask);
    const score = penalty(modules);
    if (score < least) [best, least] = [mask, score];
    apply(mask);
  }
  apply(best);
  format(best);
  return modules.map(row => row.map(dark => (dark ? "1" : "0")).join(""));
}
