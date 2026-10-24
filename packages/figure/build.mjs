// Builds the "Anatomy of an investigation" figure for both clients:
//   apps/web/public/anatomy.html                    (landing page, iframe)
//   apps/macos/Sources/Guardian/AnatomyFigure.swift (desktop, WKWebView)
// Run: node packages/figure/build.mjs
// Drawn with the MIT-licensed Anatomy kit (kit/iso-kit.mjs, see kit/LICENSE).
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as k from "./kit/iso-kit.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "../..");

// Truth: these come from services/agent (investigator.py, __main__.py, store.py).
const MAX_TOOL_CALLS = 16; // investigator.MAX_TOOL_CALLS
const SNAPSHOT_SECONDS = 5; // `serve --watch` collects every five seconds
const RETENTION_DAYS = 7; // SQLite history keeps seven days

const WIDTH = 640;
const HEIGHT = 380;

const PLATE = { x: -158, y: -46, w: 344, d: 124, r: 8 };
const PLATE_H = 12;
const FOOT_H = 5;

const PLINTH = { x: -96, y: -27, w: 192, d: 50, r: 1.5 };
const CHEST = { x: -99, y: -30, w: 198, d: 56, r: 2 };
const CAP = { x: -101, y: -32, w: 202, d: 60, r: 3 };
const TOP = 53;
const FRONT = CHEST.y + CHEST.d;

const PITCH = 28;
const centre = (i) => -84 + 28 * i;
const TRAVEL = 30;

const POSTS = [-136, 126];
const BEAM = { x: -138, y: 30, w: 276, d: 8, r: 1 };
const BEAM_Z = [100, 107];
const RAIL_TOP = 108.4;
const CARRIAGE = { x: -10, y: 38, w: 20, d: 5, r: 1.2 };
const SADDLE = { x: -10, y: 29, w: 20, d: 14, r: 1.6 };
const CARRIAGE_Z = 94;
const ROD_Y = 40.5;
const REST = 70;
const READ = 48;
const PARK = 108;

const LEVER = { x: -152, y: 30, w: 16, d: 28, r: 2 };
const BOARD = { x: 132, y: -20, w: 34, d: 6, r: 1 };
const BOARD_TOP = 62;
const BOARD_FACE = BOARD.y + BOARD.d;
const HOLES = Array.from({ length: MAX_TOOL_CALLS }, (_, i) => [138.5 + 7 * (i % 4), 52 - 8.5 * Math.floor(i / 4)]);
const CARD = { x: 139, y: -17.4, w: 20, d: 0.8, r: 0.3 };
const RISE = 18;

const SLOT = { x: -93, y: -6.6, w: 18, d: 1.2, r: 0.5 };
const DROP = { x: -92, y: -6.4, w: 16, d: 0.8, r: 0.3 };
const DROP_H = 7;
const THROAT = { x: -95, y: -10, w: 22, d: 8, r: 1 };
const HOPPER = { x: -99, y: -17, w: 30, d: 22, r: 2 };
const HOPPER_Z = [58, 62, 73];

const P = k.fitProjection(
  [
    ...k.boxCorners(PLATE, -PLATE_H - FOOT_H, 0),
    ...k.boxCorners(BEAM, 0, 113),
    ...k.boxCorners(HOPPER, 0, HOPPER_Z[2]),
    [150, -17, BOARD_TOP + RISE],
  ],
  WIDTH,
  HEIGHT,
  { pad: 40, azimuth: 58 },
);

// Shared with the live script through Function#toString, so these may only use k, C, P and their arguments.
const C = { TOP, FRONT, PITCH, TRAVEL, ROD_Y, CARRIAGE_Z, BOARD_TOP, CARD, RISE, DROP, DROP_H };
const boxSvg = (x, open) => {
  if (open < 0.05) return "";
  const plan = { x: x - 12, y: C.FRONT, w: 24, d: open, r: 0.6 };
  const top = 43;
  const rows = [];
  for (let y = C.FRONT + 2.4; y < C.FRONT + open - 1.6; y += 2.2) rows.push(k.lineOnTop([x - 10.8, y], [x + 10.8, y], top, P));
  const rims = [x - 10.8, x + 10.8].map((rx) => k.lineOnTop([rx, C.FRONT], [rx, C.FRONT + Math.max(0, open - 1.2)], top, P)).join("");
  const inner = k.lineSvg(rims, { tone: "lo" }) + k.lineSvg(rows.join(""), { tone: "faint" });
  return k.solidSvg(k.slabOf(plan, 11, top - 11, P, 2), { tone: "mid", inner });
};
const rodSvg = (x, z) => k.solidSvg(k.cylinder(x, C.ROD_Y, 1.4, z + 9, C.CARRIAGE_Z - z - 9, P, 16), { tone: "mid", crease: "none" });
const findingSvg = (rise) => {
  const h = rise * C.RISE;
  if (h < 0.2) return "";
  const top = C.BOARD_TOP + h;
  const face = C.CARD.y + C.CARD.d;
  const rules = [
    [3, 15],
    [5.4, 11],
    [7.8, 13],
    [10.2, 8],
  ]
    .filter(([down]) => top - down > C.BOARD_TOP + 1)
    .map(([down, length]) => k.segment([C.CARD.x + 2.5, face, top - down], [C.CARD.x + 2.5 + length, face, top - down], P))
    .join("");
  return k.solidSvg(k.slabOf(C.CARD, C.BOARD_TOP, h, P, 2), { tone: "hi", inner: k.lineSvg(rules, { tone: "lo", free: true }) });
};

const at = (point) => k.iso(point, P);
const S = (paths, style) => k.solidSvg(paths, style);
const L = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const face = (x0, x1, y, z0, z1) => k.pathOf([at([x0, y, z0]), at([x1, y, z0]), at([x1, y, z1]), at([x0, y, z1])], true);
const byDepth = (points) => [...points].sort((a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P));

function plate() {
  const out = [`<path class="iso-halo" d="${k.haloOf(PLATE, -PLATE_H - FOOT_H, PLATE_H, P)}"/>`];
  for (const [x, y] of byDepth(k.corners(PLATE, 22))) {
    out.push(S(k.cylinder(x, y, 7, -PLATE_H - FOOT_H, 1.6, P, 28), { tone: "lo" }));
    out.push(S(k.cylinder(x, y, 5.4, -PLATE_H - FOOT_H + 1.6, FOOT_H - 1.6, P, 28), { tone: "mid" }));
  }
  out.push(S(k.slabOf(PLATE, -PLATE_H, PLATE_H, P, 8, 1.6), { tone: "mid" }));
  out.push(L(k.planOutline(k.insetPlan(PLATE, 5), 0, P), { tone: "lo" }));
  const screws = k.corners(PLATE, 10);
  out.push(L(screws.map(([x, y]) => k.ring(x, y, 2.2, 0, P, 16)).join(""), { tone: "lo" }));
  out.push(D(screws.map(([x, y]) => at([x, y, 0])), { size: 0.5 }));
  const strip = { x: -140, y: PLATE.y + PLATE.d - 15, w: 310, d: 7, r: 1 };
  out.push(S(k.slabOf(strip, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
  const ticks = k.topTicks(strip.x + 4, strip.x + strip.w - 4, 4, 7, strip.y + 0.8, 0.6, [2, 3.6], P);
  out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  out.push(D([at([strip.x + 2, strip.y + 3.5, 0.6]), at([strip.x + strip.w - 2, strip.y + 3.5, 0.6])], { size: 0.45 }));
  const label = { x: 134, y: 42, w: 40, d: 14, r: 1.5 };
  out.push(S(k.slabOf(label, 0, 0.8, P, 4), { tone: "lo", crease: "none" }));
  out.push(L(k.planOutline(k.insetPlan(label, 1.6), 0.8, P), { tone: "faint" }));
  out.push(L([[26, 0], [18, 1], [22, 2]].map(([w, row]) => k.lineOnTop([label.x + 5, label.y + 4 + row * 3], [label.x + 5 + w, label.y + 4 + row * 3], 0.8, P)).join(""), { tone: "lo", free: true }));
  out.push(D([at([label.x + label.w - 3.5, label.y + 3.5, 0.8]), at([label.x + label.w - 3.5, label.y + label.d - 3.5, 0.8])], { size: 0.45 }));
  return out.join("");
}

function board() {
  const out = [`<path class="iso-halo" d="${k.haloOf({ x: 130, y: -24, w: 38, d: 16, r: 1.5 }, 0, 0.1, P)}" style="filter:blur(4px)"/>`];
  const foot = { x: 130, y: -24, w: 38, d: 16, r: 1.5 };
  out.push(S(k.slabOf(foot, 0, 5, P, 3, 0.5), { tone: "mid" }));
  out.push(D(k.corners(foot, 3).map(([x, y]) => at([x, y, 5])), { size: 0.45 }));
  out.push(S(k.slabOf(BOARD, 5, BOARD_TOP - 5, P, 3, 0.5), { tone: "mid", inner: L(k.sideSeam(BOARD, 14, P, 3), { tone: "faint" }) }));
  // Sixteen holes: the investigator's tool-call budget.
  out.push(L(HOLES.map(([x, z]) => k.sideRing([x, BOARD_FACE, z], 1.5, "y", P, 16)).join(""), { tone: "lo" }));
  out.push(D(HOLES.map(([x, z]) => at([x, BOARD_FACE, z])), { size: 0.55, tone: "lo" }));
  out.push(L([[16, 10], [11, 7]].map(([w, z]) => k.segment([BOARD.x + 5, BOARD_FACE, z], [BOARD.x + 5 + w, BOARD_FACE, z], P)).join(""), { tone: "lo", free: true }));
  out.push(D([at([BOARD.x + 3, BOARD_FACE, BOARD_TOP - 3]), at([BOARD.x + BOARD.w - 3, BOARD_FACE, BOARD_TOP - 3])], { size: 0.45 }));
  out.push(L(k.planOutline({ x: CARD.x - 0.4, y: CARD.y - 0.2, w: CARD.w + 0.8, d: CARD.d + 0.4, r: 0.4 }, BOARD_TOP, P, 2), { tone: "lo" }));
  return out.join("");
}

function pegs() {
  return HOLES.map(([x, z], i) => {
    const peg = S(k.slabOf({ x: x - 1.1, y: BOARD_FACE, w: 2.2, d: 3.2, r: 1 }, z - 1.1, 2.2, P, 3), { tone: "hi" });
    return `<g data-peg="${i}" style="opacity:0">${peg}</g>`;
  }).join("");
}

function chest() {
  const out = [`<path class="iso-halo" d="${k.haloOf(PLINTH, 0, 0.1, P)}" style="filter:blur(5px)"/>`];
  out.push(S(k.slabOf(PLINTH, 0, 5, P, 3), { tone: "lo" }));
  out.push(S(k.slabOf(CHEST, 5, 45, P, 3, 0.6), { tone: "mid", inner: L(k.sideSeam(CHEST, 9, P, 3), { tone: "faint" }) }));
  out.push(S(k.slabOf(CAP, 50, 3, P, 4, 1), { tone: "mid" }));
  // Drawer openings: dark recesses the fronts sit in.
  for (let i = 0; i < RETENTION_DAYS; i++) {
    const x = centre(i);
    const d = face(x - 13.4, x + 13.4, FRONT, 8.6, 45.4);
    out.push(`<path class="iso-shade" data-shade="0" d="${d}"/>`, L(d, { tone: "lo" }));
  }
  // Filing slot over today's drawer.
  out.push(`<path class="iso-shade" data-shade="0" d="${k.planOutline(SLOT, TOP, P, 2)}"/>`, L(k.planOutline(SLOT, TOP, P, 2), { tone: "lo" }));
  out.push(L(k.planOutline(k.insetPlan(CAP, 4), TOP, P), { tone: "faint" }));
  out.push(D(k.corners(CAP, 2.4).map(([x, y]) => at([x, y, TOP])), { size: 0.45 }));
  return out.join("");
}

function hopper() {
  const out = [];
  for (const x of [HOPPER.x - 2.5, HOPPER.x + HOPPER.w]) {
    out.push(S(k.slabOf({ x, y: -11, w: 2.5, d: 10, r: 0.6 }, TOP, HOPPER_Z[2] - 6 - TOP, P, 2), { tone: "mid" }));
    out.push(D([at([x + 1.25, -9, TOP]), at([x + 1.25, -3, TOP])], { size: 0.4 }));
  }
  out.push(S(k.slabOf(THROAT, HOPPER_Z[0], HOPPER_Z[1] - HOPPER_Z[0], P, 2, 0.4), { tone: "mid" }));
  out.push(S(k.slabOf(HOPPER, HOPPER_Z[1], HOPPER_Z[2] - HOPPER_Z[1], P, 4, 0.8), { tone: "mid", inner: L(k.sideSeam(HOPPER, HOPPER_Z[1] + 4, P, 4), { tone: "faint" }) }));
  // Three feed slots, one per collector: processes, listeners, launch agents.
  for (const y of [-13, -7, -1]) {
    const slot = { x: HOPPER.x + 4, y, w: HOPPER.w - 8, d: 1.6, r: 0.8 };
    out.push(`<path class="iso-shade" data-shade="0" d="${k.planOutline(slot, HOPPER_Z[2], P, 2)}"/>`, L(k.planOutline(slot, HOPPER_Z[2], P, 2), { tone: "lo" }));
  }
  out.push(D(k.corners(HOPPER, 2.2).map(([x, y]) => at([x, y, HOPPER_Z[2]])), { size: 0.45 }));
  // The falling card is clipped to the gap between the throat and the slot.
  const band = [at([-97, THROAT.y + THROAT.d, HOPPER_Z[0]]), at([-71, THROAT.y + THROAT.d, HOPPER_Z[0]]), at([-71, SLOT.y + SLOT.d, TOP]), at([-97, SLOT.y + SLOT.d, TOP])];
  out.push(`<clipPath id="chute"><path d="${k.pathOf(band, true)}"/></clipPath>`);
  out.push(`<g clip-path="url(#chute)"><g data-part="drop" transform="${k.translateAlong(P, [0, 0, HOPPER_Z[0] + 2])}">${S(k.slabOf(DROP, 0, DROP_H, P, 2), { tone: "hi" })}</g></g>`);
  return out.join("");
}

function lever() {
  // A padlocked lever on its own pedestal: remediation is proposal-only, the lever never moves.
  const out = [`<path class="iso-halo" d="${k.haloOf(LEVER, 0, 0.1, P)}" style="filter:blur(4px)"/>`];
  out.push(S(k.slabOf(LEVER, 0, 12, P, 3, 0.5), { tone: "mid", inner: L(k.sideSeam(LEVER, 4, P, 3), { tone: "faint" }) }));
  const z0 = 12;
  const guide = k.insetPlan(LEVER, 2);
  out.push(S(k.slabOf(guide, z0, 2, P, 3, 0.4), { tone: "mid" }));
  const top = z0 + 2;
  const slot = { x: LEVER.x + LEVER.w / 2 - 1.4, y: LEVER.y + 4, w: 2.8, d: 16, r: 1.4 };
  out.push(`<path class="iso-shade" data-shade="0" d="${k.planOutline(slot, top, P, 4)}"/>`, L(k.planOutline(slot, top, P, 4), { tone: "lo" }));
  out.push(D(k.corners(guide, 2).map(([x, y]) => at([x, y, top])), { size: 0.45 }));
  const rod = [slot.x + 1.4, slot.y + 3];
  out.push(S(k.cylinder(rod[0], rod[1], 1.3, top, 20, P, 16), { tone: "mid", crease: "none" }));
  out.push(S(k.cylinder(rod[0], rod[1], 3.4, top + 20, 5, P, 24), { tone: "mid" }));
  out.push(L(k.knurl(rod[0], rod[1], 3.4, top + 20, top + 25, 20, P), { tone: "lo" }));
  out.push(L(k.lineOnTop(rod, [rod[0] + 3, rod[1]], top + 25, P), { tone: "hi" }));
  // Hasp, shackle and padlock on the pedestal's front face.
  const hx = rod[0];
  const face = LEVER.y + LEVER.d;
  out.push(S(k.slabOf({ x: hx - 1, y: face, w: 2, d: 3.4, r: 0.5 }, 9.5, 2, P, 2), { tone: "mid", crease: "none" }));
  const sy = face + 2;
  const shackle = [];
  for (let i = 0; i <= 12; i++) {
    const a = Math.PI * (i / 12);
    shackle.push(at([hx - 1.8 * Math.cos(a), sy, 11.9 + 1.8 * Math.sin(a)]));
  }
  out.push(L(k.pathOf([at([hx - 1.8, sy, 6.5]), ...shackle, at([hx + 1.8, sy, 6.5])]), { tone: "hi" }));
  const lock = { x: hx - 3, y: face + 0.4, w: 6, d: 3.2, r: 1 };
  out.push(S(k.slabOf(lock, 1.5, 5, P, 3, 0.4), { tone: "hi" }));
  out.push(L(k.segment([hx, face + 3.6, 2.6], [hx, face + 3.6, 4.6], P), { tone: "lo" }));
  return out.join("");
}

function drawers() {
  return Array.from({ length: RETENTION_DAYS }, (_, i) => {
    const x = centre(i);
    const front = { x: x - 13, y: FRONT, w: 26, d: 1.6, r: 0.8 };
    const parts = [S(k.slabOf(front, 9, 36, P, 2, 0.4), { tone: "mid" })];
    const f = FRONT + 1.6;
    parts.push(S(k.slabOf({ x: x - 6, y: f, w: 12, d: 2.2, r: 1 }, 24, 2.2, P, 3), { tone: "mid" }));
    const holder = face(x - 6, x + 6, f, 32, 39);
    parts.push(L(holder, { tone: "lo" }));
    parts.push(L([[8.4, 37], [6, 34.6]].map(([w, z]) => k.segment([x - 4.2, f, z], [x - 4.2 + w, f, z], P)).join(""), { tone: "faint", free: true }));
    parts.push(D([[x - 11, 42.6], [x + 11, 42.6], [x - 11, 11.4], [x + 11, 11.4]].map(([px, pz]) => at([px, f, pz])), { size: 0.4 }));
    return `<g data-drawer="${i}"><g data-box></g><g data-face>${parts.join("")}</g></g>`;
  }).join("");
}

function gantry() {
  const out = [];
  for (const x of POSTS) {
    out.push(S(k.slabOf({ x: x - 3, y: BEAM.y - 3, w: 16, d: 14, r: 1.4 }, 0, 2, P, 3, 0.4), { tone: "lo" }));
    out.push(D([at([x - 1, BEAM.y - 1, 2]), at([x + 11, BEAM.y + 9, 2])], { size: 0.45 }));
    out.push(S(k.slabOf({ x, y: BEAM.y, w: 10, d: 8, r: 1 }, 2, BEAM_Z[0] - 2, P, 3, 0.4), { tone: "mid", inner: L(k.sideSeam({ x, y: BEAM.y, w: 10, d: 8, r: 1 }, 86, P, 3), { tone: "faint" }) }));
  }
  out.push(S(k.slabOf(BEAM, BEAM_Z[0], BEAM_Z[1] - BEAM_Z[0], P, 3, 0.5), { tone: "mid" }));
  // Ruler on the beam's front face: a major tick at every drawer.
  const ticks = k.sideTicks(-96, 96, 4, 7, BEAM.y + BEAM.d, BEAM_Z[1], [1.4, 3], P);
  out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  for (const y of [31.6, 35]) {
    out.push(S(k.slabOf({ x: -132, y, w: 264, d: 1.4, r: 0.5 }, BEAM_Z[1], RAIL_TOP - BEAM_Z[1], P, 2), { tone: "mid", crease: "none" }));
  }
  for (const x of [-136, 132]) {
    out.push(S(k.slabOf({ x, y: BEAM.y, w: 4, d: 8, r: 0.8 }, BEAM_Z[1], 4, P, 2, 0.3), { tone: "mid" }));
    out.push(D([at([x + 2, BEAM.y + 4, BEAM_Z[1] + 4])], { size: 0.45 }));
  }
  return out.join("");
}

function head() {
  const out = [];
  out.push(S(k.cylinder(0, ROD_Y, 5, -1.6, 1.6, P, 32), { tone: "hi", crease: "lo", lit: true }));
  out.push(S(k.cylinder(0, ROD_Y, 6.5, 0, 6, P, 40, 0.5), { tone: "hi", crease: "lo", lit: true, inner: L(k.sideArc(0, ROD_Y, 6.5, 2, P, 24), { tone: "faint" }) }));
  out.push(L(k.knurl(0, ROD_Y, 6.5, 3, 6, 40, P, 0.3), { tone: "lo" }));
  out.push(L(k.ring(0, ROD_Y, 4.6, 6, P, 32), { tone: "lo" }));
  out.push(S(k.cylinder(0, ROD_Y, 3, 6, 3, P, 20), { tone: "hi", lit: true }));
  out.push(D([at([0, ROD_Y + 5.6, 6])], { size: 0.6, tone: "hi" }));
  return out.join("");
}

function carriage() {
  const out = [];
  out.push(S(k.slabOf(CARRIAGE, CARRIAGE_Z, RAIL_TOP - CARRIAGE_Z, P, 3, 0.5), { tone: "mid" }));
  const f = CARRIAGE.y + CARRIAGE.d;
  out.push(D([[-7, 97], [7, 97], [-7, 105.4], [7, 105.4]].map(([x, z]) => at([x, f, z])), { size: 0.45 }));
  out.push(L(k.segment([-10, f, 101], [10, f, 101], P), { tone: "faint" }));
  out.push(S(k.slabOf(SADDLE, RAIL_TOP, 4, P, 3, 0.5), { tone: "mid" }));
  out.push(D(k.corners(SADDLE, 2.4).map(([x, y]) => at([x, y, RAIL_TOP + 4])), { size: 0.45 }));
  out.push(S(k.cylinder(-3, 35, 3.2, RAIL_TOP + 4, 4.5, P, 24), { tone: "mid" }));
  out.push(L(k.knurl(-3, 35, 3.2, RAIL_TOP + 4, RAIL_TOP + 8.5, 18, P), { tone: "lo" }));
  out.push(L(k.lineOnTop([-3, 35], [-3 + 2.6, 35], RAIL_TOP + 8.5, P), { tone: "hi" }));
  out.push(D([at([5, 35, RAIL_TOP + 4])], { size: 0.7, tone: "hi" }));
  return out.join("");
}

const STILL = { drawer: 1, pegs: 6 };
const svg = k.figureSvg({
  width: WIDTH,
  height: HEIGHT,
  label:
    "A card-index chest with seven drawers, one per day of local history. A hopper files a card into today's drawer every five seconds. A loupe on a gantry chooses drawers to open and read; each read puts a peg into a sixteen-hole board, the investigator's tool-call budget, and a finding card rises from the board when it is done. A padlocked lever beside the chest never moves: fixes are proposals only.",
  body: [
    plate(),
    board(),
    `<g data-part="pegs">${pegs()}</g>`,
    `<g data-part="finding"></g>`,
    chest(),
    hopper(),
    `<g data-part="drawers">${drawers()}</g>`,
    gantry(),
    `<g data-part="rod">${rodSvg(centre(STILL.drawer), READ)}</g>`,
    `<g data-part="head" transform="${k.translateAlong(P, [centre(STILL.drawer), 0, READ])}">${head()}</g>`,
    `<g data-part="carriage" transform="${k.translateAlong(P, [centre(STILL.drawer), 0, 0])}">${carriage()}</g>`,
    lever(),
  ],
});

const live = `
const P = ${JSON.stringify(P)};
const C = ${JSON.stringify(C)};
const k = { slabOf, cylinder, solidSvg, lineSvg, lineOnTop, segment };
const boxSvg = ${boxSvg};
const rodSvg = ${rodSvg};
const findingSvg = ${findingSvg};
const DAYS = ${RETENTION_DAYS}, CALLS = ${MAX_TOOL_CALLS}, SNAPSHOT = ${SNAPSHOT_SECONDS};
const REST = ${REST}, READ = ${READ}, PARK = ${PARK}, TRAVEL = ${TRAVEL}, DROP_FROM = ${HOPPER_Z[0] + 2}, DROP_TO = ${C.TOP - C.DROP_H - 1};
const centre = ${centre};
// One scripted investigation, using the agent's real read-only tools.
const PLAN = [
  ["search_observations", 0], ["search_observations", 1], ["inspect_entity", 0],
  ["search_observations", 4], ["get_evidence", 0], ["get_evidence", 1],
];
const stage = document.querySelector(".iso-stage");
const svg = stage.querySelector("svg");
const $ = (name) => svg.querySelector('[data-part="' + name + '"]');
const tray = $("drawers"), rod = $("rod"), head = $("head"), carriage = $("carriage"), drop = $("drop"), finding = $("finding");
const drawerEls = [...svg.querySelectorAll("[data-drawer]")];
const pegEls = [...svg.querySelectorAll("[data-peg]")];
const readout = document.querySelector("[data-readout]");
const still = matchMedia("(prefers-reduced-motion: reduce)");
const ease = (x, target, dt, seconds, calm) => (calm ? target : x + (target - x) * (1 - Math.exp(-dt / seconds)));
const dayName = (d) => (d === 0 ? "today" : d === 1 ? "yesterday" : d + " days ago");

const s = {
  x: centre(${STILL.drawer}), tx: centre(${STILL.drawer}), z: READ, tz: READ,
  open: Array.from({ length: DAYS }, (_, i) => (i === ${STILL.drawer} ? TRAVEL : 0)), want: ${STILL.drawer},
  pegs: ${STILL.pegs}, peg: Array.from({ length: CALLS }, (_, i) => (i < ${STILL.pegs} ? 1 : 0)),
  rise: 0, tRise: 0, dropAt: -1, sinceDrop: 0, cards: 0,
  mode: "tour", step: 1, phase: "read", clock: 0,
  live: null, hover: -1,
};
let frame = 0, last = 0, visible = false, idleTimer = 0, touring = !still.matches;
let drawn = {};

function nearest(x) {
  let best = -1, gap = 9;
  for (let i = 0; i < DAYS; i++) if (Math.abs(centre(i) - x) < gap) { gap = Math.abs(centre(i) - x); best = i; }
  return best;
}
function query() {
  if (s.want < 0 || s.open[s.want] < TRAVEL - 1 || s.pegs >= CALLS) return false;
  s.pegs++;
  return true;
}

function tour(dt) {
  s.clock += dt;
  const [, day] = PLAN[s.step] || [];
  if (s.phase === "travel") {
    s.tx = centre(day); s.want = -1; s.tz = REST;
    if (Math.abs(s.x - s.tx) < 0.4) { s.phase = "open"; s.clock = 0; }
  } else if (s.phase === "open") {
    s.want = day; s.tz = READ;
    if (s.open[day] > TRAVEL - 0.6 && Math.abs(s.z - READ) < 0.4) { s.phase = "read"; s.clock = 0; query(); }
  } else if (s.phase === "read") {
    if (s.clock > 0.9) { s.phase = "close"; s.clock = 0; }
  } else if (s.phase === "close") {
    s.want = -1; s.tz = REST;
    if (s.open.every((o) => o < 0.6)) {
      s.step++; s.clock = 0;
      s.phase = s.step < PLAN.length ? "travel" : "finding";
    }
  } else if (s.phase === "finding") {
    s.tRise = 1; s.tx = PARK;
    if (s.clock > 3.4) { s.phase = "reset"; s.clock = 0; }
  } else if (s.phase === "reset") {
    s.tRise = 0; s.pegs = 0; s.tx = PARK;
    if (s.clock > 1.8) { s.phase = "travel"; s.step = 0; s.clock = 0; }
  }
}

// Desktop app bridge: real numbers from the local agent, never simulated.
function liveStep(dt) {
  const L = s.live;
  s.clock += dt;
  if (L.investigating) {
    // The agent reports its steps when it finishes, so the loupe sweeps without counting.
    s.tRise = 0; s.pegs = 0;
    const day = Math.floor(s.clock / 2.6) % DAYS;
    const t = s.clock % 2.6;
    s.tx = centre(day);
    const there = Math.abs(s.x - s.tx) < 0.6;
    s.want = there && t > 0.7 && t < 2.1 ? day : -1;
    s.tz = s.want >= 0 && s.open[day] > TRAVEL - 4 ? READ : REST;
  } else {
    s.want = -1; s.tz = REST; s.tx = PARK;
    s.pegs = Math.min(CALLS, L.steps || 0);
    s.tRise = L.findings > 0 ? 1 : 0;
  }
}

function phaseText() {
  if (s.live) {
    const L = s.live;
    const count = (L.observations || 0).toLocaleString("en-US") + " observations";
    if (!L.connected) return "agent disconnected";
    if (L.investigating) return count + " · investigating";
    if (L.findings > 0) return count + " · last finding " + s.pegs + "/" + CALLS + " queries";
    return count + (L.monitoring ? " · filing" : " · paused");
  }
  const [, day] = PLAN[s.step] || [];
  if (s.mode === "hand") return (s.hover >= 0 ? (s.open[s.hover] > TRAVEL - 1 ? "reading " : "opening ") + dayName(s.hover) : "steering") + " · " + s.pegs + "/" + CALLS + " queries";
  if (s.phase === "finding") return "finding raised · " + s.pegs + "/" + CALLS + " queries";
  if (s.phase === "reset") return "new investigation";
  if (s.phase === "read") return "reading " + dayName(day) + " · " + s.pegs + "/" + CALLS + " queries";
  return "searching " + (day === undefined ? "" : dayName(day)) + " · " + s.pegs + "/" + CALLS + " queries";
}

function draw() {
  carriage.setAttribute("transform", translateAlong(P, [s.x, 0, 0]));
  head.setAttribute("transform", translateAlong(P, [s.x, 0, s.z]));
  const rk = s.x.toFixed(2) + "," + s.z.toFixed(2);
  if (drawn.rod !== rk) { rod.innerHTML = rodSvg(s.x, s.z); drawn.rod = rk; }
  drawerEls.forEach((el, i) => {
    const o = s.open[i];
    const key = o.toFixed(2);
    if (drawn["d" + i] === key) return;
    drawn["d" + i] = key;
    el.firstChild.innerHTML = boxSvg(centre(i), o);
    if (o > 0.01) el.lastChild.setAttribute("transform", translateAlong(P, [0, o, 0]));
    else el.lastChild.removeAttribute("transform");
  });
  pegEls.forEach((el, i) => {
    const v = s.peg[i];
    el.style.opacity = v.toFixed(3);
    el.setAttribute("transform", translateAlong(P, [0, (1 - v) * 4, 0]));
  });
  const fk = s.rise.toFixed(3);
  if (drawn.rise !== fk) { finding.innerHTML = findingSvg(s.rise); drawn.rise = fk; }
  if (s.dropAt >= 0) {
    const t = Math.min(1, s.dropAt);
    drop.setAttribute("transform", translateAlong(P, [0, 0, DROP_FROM + (DROP_TO - DROP_FROM) * t * t]));
  }
  const text = phaseText();
  if (readout.textContent !== text) readout.textContent = text;
}

function tick(now) {
  const dt = last ? Math.min((now - last) / 1000, 1 / 30) : 1 / 60;
  last = now;
  const calm = still.matches;
  if (s.live) liveStep(dt);
  else if (touring) tour(dt);
  // A snapshot files one card every five seconds while collection runs.
  const filing = s.live ? s.live.connected && s.live.monitoring : touring;
  if (filing && !calm) {
    s.sinceDrop += dt;
    if (s.sinceDrop >= SNAPSHOT) { s.sinceDrop = 0; s.dropAt = 0; s.cards++; }
  }
  if (s.dropAt >= 0) { s.dropAt += dt / 0.55; if (s.dropAt > 1) s.dropAt = -1; }
  s.x = ease(s.x, s.tx, dt, 0.32, calm);
  if (Math.abs(s.x - s.tx) < 0.02) s.x = s.tx;
  s.z = ease(s.z, s.tz, dt, 0.22, calm);
  if (Math.abs(s.z - s.tz) < 0.02) s.z = s.tz;
  for (let i = 0; i < DAYS; i++) {
    const target = i === s.want ? TRAVEL : 0;
    // A drawer only opens once the loupe is clear above it, and the loupe lifts before it closes.
    const blocked = target > 0 ? false : s.z < REST - 6 && i === nearest(s.x);
    if (!blocked) s.open[i] = ease(s.open[i], target, dt, 0.26, calm);
    if (Math.abs(s.open[i] - target) < 0.02) s.open[i] = target;
  }
  for (let i = 0; i < CALLS; i++) {
    const target = i < s.pegs ? 1 : 0;
    s.peg[i] = ease(s.peg[i], target, dt, 0.16, calm);
    if (Math.abs(s.peg[i] - target) < 0.002) s.peg[i] = target;
  }
  s.rise = ease(s.rise, s.tRise, dt, 0.45, calm);
  if (Math.abs(s.rise - s.tRise) < 0.002) s.rise = s.tRise;
  draw();
  const settled = !touring && !(s.live && (s.live.investigating || s.live.monitoring)) && s.dropAt < 0 && s.x === s.tx && s.z === s.tz && s.rise === s.tRise
    && s.open.every((o, i) => o === (i === s.want ? TRAVEL : 0)) && s.peg.every((v, i) => v === (i < s.pegs ? 1 : 0));
  frame = visible && !settled ? requestAnimationFrame(tick) : 0;
}
const run = () => { if (!frame && visible) { last = 0; frame = requestAnimationFrame(tick); } };

function takeOver() {
  if (s.live) return;
  touring = false; s.mode = "hand";
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    if (still.matches) return;
    touring = true; s.mode = "tour"; s.phase = "reset"; s.clock = 0; run();
  }, 3600);
}
function steer(x) {
  takeOver();
  if (s.live) return;
  s.tx = Math.min(PARK, Math.max(centre(0) - 6, x));
  s.hover = nearest(s.tx);
  s.want = s.hover;
  s.tz = s.hover >= 0 ? READ : REST;
  s.tRise = 0;
  run();
}
stage.addEventListener("pointermove", (event) => {
  const box = svg.getBoundingClientRect();
  const share = Math.min(1, Math.max(0, ((event.clientX - box.left) / box.width - 0.18) / 0.62));
  steer(centre(0) - 6 + share * (PARK - centre(0) + 6));
});
stage.addEventListener("click", () => { if (!s.live) { takeOver(); query(); run(); } });
stage.addEventListener("keydown", (event) => {
  if (s.live) return;
  const here = Math.max(0, nearest(s.tx));
  let to = null;
  if (event.key === "ArrowRight" || event.key === "ArrowUp") to = Math.min(DAYS - 1, here + 1);
  if (event.key === "ArrowLeft" || event.key === "ArrowDown") to = Math.max(0, here - 1);
  if (event.key === "Home") to = 0;
  if (event.key === "End") to = DAYS - 1;
  if (event.key === " " || event.key === "Enter") { event.preventDefault(); takeOver(); query(); run(); return; }
  if (to === null) return;
  event.preventDefault();
  steer(centre(to));
  stage.setAttribute("aria-valuenow", String(to));
  stage.setAttribute("aria-valuetext", dayName(to) + ", " + s.pegs + " of " + CALLS + " queries used");
});
new IntersectionObserver((entries) => { visible = entries[entries.length - 1].isIntersecting; if (visible) run(); }, { rootMargin: "120px 0px" }).observe(stage);

window.arkangel = {
  update(next) {
    clearTimeout(idleTimer);
    const was = s.live;
    s.live = next;
    touring = false; s.mode = "live";
    const hint = document.querySelector('[data-corner="hint"]');
    if (hint) hint.textContent = "Live from the local agent";
    if (!was || was.investigating !== next.investigating) s.clock = 0;
    run();
  },
};

// Embedding: the web page passes #web (legend, height reports); the app passes nothing. Both follow the system appearance.
const web = location.hash === "#web";
const dark = matchMedia("(prefers-color-scheme: dark)");
const theme = () => { document.body.dataset.theme = dark.matches ? "dark" : "light"; };
theme();
dark.addEventListener("change", theme);
document.body.dataset.host = web ? "web" : "app";
if (web && parent !== window) {
  const figure = document.querySelector(".iso-figure");
  const report = () => parent.postMessage({ anatomyHeight: Math.ceil(figure.getBoundingClientRect().bottom) + 4 }, "*");
  new ResizeObserver(report).observe(figure);
  addEventListener("message", (event) => { if (event.source === parent && event.data === "anatomy:measure") report(); });
}
draw();
if (touring) setTimeout(() => { if (touring) run(); }, 1400);
`;

const body = k.plateHtml({
  fig: "Fig 1",
  title: "Anatomy of an investigation",
  hint: "Hover to steer · click to query",
  readout: `reading yesterday · ${STILL.pegs}/${MAX_TOOL_CALLS} queries`,
  keys: [
    { mark: "lit", label: "The loupe: Claude, choosing what to read" },
    { mark: "raised", label: `${RETENTION_DAYS} drawers, one per day of local history` },
    { mark: "dim", label: `${MAX_TOOL_CALLS}-peg board: the tool-call budget` },
  ],
  caption: `Collectors file a card into today's drawer every ${SNAPSHOT_SECONDS} seconds. The loupe opens drawers read-only, each read uses one of ${MAX_TOOL_CALLS} pegs, and a finding card rises citing what it read. The padlocked lever never moves: fixes stay proposals.`,
  body: `<div class="iso-stage" tabindex="0" role="slider" aria-label="Investigation bench: arrow keys move the loupe between the seven daily drawers, Space reads the open drawer" aria-valuemin="0" aria-valuemax="${RETENTION_DAYS - 1}" aria-valuenow="${STILL.drawer}">${svg}</div>`,
});

// Dark tokens tinted to the landing page palette; app mode drops the page chrome and legend.
const EXTRA = `
html,body[data-theme]{color-scheme:light dark}
body[data-host]{background:transparent}
body[data-host] .iso-page{width:min(760px,100% - 8px);margin:0 auto}
body[data-host] .iso-figure{margin:0}
.iso-stage{outline:none;touch-action:pan-y;cursor:crosshair}
.iso-stage:focus-visible{outline:1px solid var(--anatomy-muted);outline-offset:6px}
.iso[data-theme="dark"]{
  --anatomy-page:#0b0d12;--anatomy-card:#141821;--anatomy-paper:#141821;--anatomy-face:#1a1f2a;--anatomy-top:#1c2230;
  --anatomy-shade-0:#0e1118;--anatomy-shade-1:#11151e;--anatomy-shade-2:#141924;--anatomy-shade-3:#181d29;
  --anatomy-lit-top:#283043;--anatomy-lit-shade:#1e2433;
  --anatomy-hi:#d8dde8;--anatomy-mid:#6c758a;--anatomy-lo:#3f4658;--anatomy-faint:#2a3040;--anatomy-text:#9aa3b5;--anatomy-muted:#6f788c;
}
.iso[data-theme="light"]{--anatomy-page:#f6f7f9;--anatomy-card:#ffffff;--anatomy-paper:#ffffff;--anatomy-text:#4a5263;--anatomy-muted:#7a8294}
body[data-host="web"]{overflow:hidden}
body[data-host="web"] .iso-page{width:100%}
body[data-host="web"] .iso-plate{box-shadow:0 0 0 1px var(--plate-border,#252b38);border-radius:14px}
body[data-host="web"][data-theme="light"] .iso-plate{--plate-border:#e2e5ec}
@media (max-width:560px){.iso-plate{overflow:hidden}.iso-stage .iso-svg{width:118%;max-width:none;margin-left:-9%}}
body[data-host="app"] .iso-legend{display:none}
body[data-host="app"] .iso-plate{border-radius:12px;padding:44px 16px}
body[data-host="app"] .iso-svg{max-height:calc(100vh - 100px);width:auto;max-width:100%}
`;
const page = k.pageHtml({ title: "Anatomy of an investigation", theme: "dark", body, script: readFileSync(join(HERE, "kit/iso-kit.mjs"), "utf8").replace(/^export /gm, "") + live }).replace("</style>", `${EXTRA}</style>`);

writeFileSync(join(ROOT, "apps/web/public/anatomy.html"), page);
let hashes = "#";
while (page.includes(`"""${hashes}`) || page.includes(`\\${hashes}`)) hashes += "#";
writeFileSync(
  join(ROOT, "apps/macos/Sources/Guardian/AnatomyFigure.swift"),
  `// Generated by packages/figure/build.mjs. Do not edit.\nenum AnatomyFigure {\n    static let html = ${hashes}"""\n${page}\n"""${hashes}\n}\n`,
);
console.log(`wrote anatomy.html (${(page.length / 1024).toFixed(0)} KB) and AnatomyFigure.swift`);
