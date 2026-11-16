/**
 * Toolbar buttons rasterized to RGBA for the kitty graphics protocol, drawn like Tern's quiet icon
 * buttons: line icons on a 24-unit grid, stroked 2 units wide with round caps and joins, on a
 * rounded background that appears on hover and press.
 */

type Point = [number, number];
/** Polylines; `closed` ones join their last point to the first. */
type Icon = { points: Point[]; closed?: boolean }[];

/** Points along a circle from `from` to `to` degrees (0 = right, 90 = down). */
const arc = (cx: number, cy: number, r: number, from: number, to: number): Point[] => {
  const steps = Math.max(2, Math.ceil(Math.abs(to - from) / 10));
  return Array.from({ length: steps + 1 }, (_, i) => {
    const angle = (from + (to - from) * i / steps) * Math.PI / 180;
    return [cx + r * Math.cos(angle), cy + r * Math.sin(angle)];
  });
};
const roundedSquare = (from: number, to: number, r: number): Point[] => [
  ...arc(to - r, from + r, r, -90, 0), ...arc(to - r, to - r, r, 0, 90),
  ...arc(from + r, to - r, r, 90, 180), ...arc(from + r, from + r, r, 180, 270),
];
const speaker: Point[] = [[11, 4.7], [6.4, 8], [3, 8], [3, 16], [6.4, 16], [11, 19.3]];
const counterclockwise: Icon = [
  { points: [...arc(12, 12, 9, 180, -135), [3, 8]] },
  { points: [[3, 3], [3, 8], [8, 8]] },
];
const mirror = (icon: Icon): Icon => icon.map(line => ({ ...line, points: line.points.map(([x, y]) => [24 - x, y]) }));

const ICONS = {
  back: [{ points: [[17, 5], [6.5, 12], [17, 19]], closed: true }],
  home: [{ points: arc(12, 12, 7.5, 0, 360), closed: true }],
  recents: [{ points: roundedSquare(5, 19, 2), closed: true }],
  power: [{ points: arc(12, 13, 7.5, -55, 235) }, { points: [[12, 3], [12, 11]] }],
  "volume-down": [{ points: speaker, closed: true }, { points: arc(12, 12, 5, -37, 37) }],
  "volume-up": [{ points: speaker, closed: true }, { points: arc(12, 12, 5, -37, 37) }, { points: arc(13, 12, 9, -45, 45) }],
  "rotate-left": counterclockwise,
  "rotate-right": mirror(counterclockwise),
  close: [{ points: [[18, 6], [6, 18]] }, { points: [[6, 6], [18, 18]] }],
} satisfies Record<string, Icon>;
export type IconName = keyof typeof ICONS;

/** Distance from (x, y) to the icon's nearest stroke centerline, in grid units. */
function distance(icon: Icon, x: number, y: number): number {
  let nearest = Infinity;
  for (const { points, closed } of icon) {
    for (let i = 0; i < points.length - (closed ? 0 : 1); i++) {
      const [ax, ay] = points[i]!, [bx, by] = points[(i + 1) % points.length]!;
      const length = (bx - ax) ** 2 + (by - ay) ** 2;
      const t = length ? Math.max(0, Math.min(1, ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / length)) : 0;
      nearest = Math.min(nearest, Math.hypot(x - ax - t * (bx - ax), y - ay - t * (by - ay)));
    }
  }
  return nearest;
}

export type ButtonStyle = {
  width: number; height: number;
  /** The rounded background's side and corner radius, and the icon's size, in pixels. */
  box: number; radius: number; icon: number;
  color: readonly [number, number, number];
  /** Opacity of the background (0 when idle) and of the icon. */
  fill: number; ink: number;
};

/** Straight-alpha RGBA of one button, `width`×`height` pixels, with its box and icon centered. */
export function button(name: IconName, style: ButtonStyle): Buffer {
  const { width, height, box, radius, icon: size, color, fill, ink } = style;
  const pixels = Buffer.alloc(width * height * 4);
  const left = (width - box) / 2, top = (height - box) / 2;
  const iconLeft = (width - size) / 2, iconTop = (height - size) / 2, scale = size / 24;
  for (let py = 0; py < height; py++) {
    for (let px = 0; px < width; px++) {
      const x = px + 0.5, y = py + 0.5;
      // Rounded-rectangle coverage from its signed distance.
      const dx = Math.max(left + radius - x, x - (left + box - radius), 0), dy = Math.max(top + radius - y, y - (top + box - radius), 0);
      const background = fill ? Math.max(0, Math.min(1, radius + 0.5 - Math.hypot(dx, dy))) * fill : 0;
      const stroke = Math.max(0, Math.min(1, scale + 0.5 - distance(ICONS[name], (x - iconLeft) / scale, (y - iconTop) / scale) * scale)) * ink;
      const alpha = stroke + background * (1 - stroke);
      const offset = (py * width + px) * 4;
      pixels[offset] = color[0]; pixels[offset + 1] = color[1]; pixels[offset + 2] = color[2];
      pixels[offset + 3] = Math.round(alpha * 255);
    }
  }
  return pixels;
}

export type PanelStyle = {
  radius: number; color: readonly [number, number, number];
  /** Opacity of the fill and of the outline, and the outline's width, in pixels. */
  fill: number; stroke: number; line: number;
  /** Separators: vertical lines `line` wide and `tall` high, centered at these x positions. */
  separators: number[]; tall: number;
};

/** Straight-alpha RGBA of a toolbar panel filling the image: a rounded rectangle with an outline. */
export function panel(width: number, height: number, style: PanelStyle): Buffer {
  const { radius, color, fill, stroke, line, separators, tall } = style;
  const pixels = Buffer.alloc(width * height * 4);
  /** Coverage of the rounded rectangle inset by `inset` pixels. */
  const cover = (x: number, y: number, inset: number) => {
    const r = Math.max(0, radius - inset);
    const dx = Math.max(inset + r - x, x - (width - inset - r), 0), dy = Math.max(inset + r - y, y - (height - inset - r), 0);
    return Math.max(0, Math.min(1, r + 0.5 - Math.hypot(dx, dy)));
  };
  const top = (height - tall) / 2;
  for (let py = 0; py < height; py++) {
    for (let px = 0; px < width; px++) {
      const x = px + 0.5, y = py + 0.5;
      const outer = cover(x, y, 0), inner = cover(x, y, line);
      let separator = 0;
      if (y >= top && y <= top + tall) {
        for (const center of separators) separator = Math.max(separator, Math.max(0, Math.min(1, line / 2 + 0.5 - Math.abs(x - center))));
      }
      const ink = Math.max((outer - inner) * stroke, separator * stroke * 1.6);
      const alpha = ink + inner * fill * (1 - ink);
      const offset = (py * width + px) * 4;
      pixels[offset] = color[0]; pixels[offset + 1] = color[1]; pixels[offset + 2] = color[2];
      pixels[offset + 3] = Math.round(alpha * 255);
    }
  }
  return pixels;
}

/** Straight-alpha RGBA of a horizontal line with round ends, `width` long, centered in `height`. */
export function pill(width: number, height: number, thickness: number, color: readonly [number, number, number], opacity: number): Buffer {
  const pixels = Buffer.alloc(width * height * 4), r = thickness / 2, cy = height / 2;
  for (let py = 0; py < height; py++) {
    for (let px = 0; px < width; px++) {
      const x = px + 0.5, y = py + 0.5;
      const dx = Math.max(r - x, x - (width - r), 0);
      const coverage = Math.max(0, Math.min(1, r + 0.5 - Math.hypot(dx, y - cy)));
      const offset = (py * width + px) * 4;
      pixels[offset] = color[0]; pixels[offset + 1] = color[1]; pixels[offset + 2] = color[2];
      pixels[offset + 3] = Math.round(coverage * opacity * 255);
    }
  }
  return pixels;
}
