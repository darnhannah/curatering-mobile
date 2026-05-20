/**
 * Seating plan JSON normalization only (extracted for staff handoff).
 * Full theme-design + seating CRUD APIs live in eventDesignSeating.ts (excluded from this package).
 */
const VENUE_FLOOR_SHAPES = new Set(["banquet_rect", "theater", "round_hall", "u_shape", "l_shape"]);
const TABLE_SHAPES = new Set(["rect", "round", "chair"]);

function toNum(v: unknown, fallback: number): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function clamp01(n: number): number {
  return Math.max(0, Math.min(1, n));
}

/** Normalize seating_plan JSONB per web/mobile contract. */
export function normalizeSeatingPlan(raw: unknown): Record<string, unknown> {
  const src = raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const version = Math.max(1, Math.floor(toNum(src.version, 1)));
  const tablesIn = Array.isArray(src.tables) ? src.tables : [];
  const seatsIn = Array.isArray(src.seats) ? src.seats : [];
  const tables: Array<Record<string, unknown>> = [];
  for (let i = 0; i < Math.min(tablesIn.length, 40); i++) {
    const t = tablesIn[i];
    if (!t || typeof t !== "object") continue;
    const o = t as Record<string, unknown>;
    const shape = String(o.shape ?? "rect").trim().toLowerCase();
    tables.push({
      id: String(o.id ?? `tbl-${i + 1}`).slice(0, 80),
      shape: TABLE_SHAPES.has(shape) ? shape : "rect",
      xNorm: clamp01(toNum(o.xNorm, 0.4)),
      yNorm: clamp01(toNum(o.yNorm, 0.4)),
      wNorm: clamp01(Math.max(0.04, toNum(o.wNorm, 0.14))),
      hNorm: clamp01(Math.max(0.04, toNum(o.hNorm, 0.1))),
      rotationDeg: toNum(o.rotationDeg, 0),
      label: String(o.label ?? `Table ${i + 1}`).slice(0, 120),
      seatCount: Math.max(0, Math.min(100, Math.floor(toNum(o.seatCount, 6)))),
    });
  }
  const tableIds = new Set(tables.map((t) => String(t.id)));
  const seats: Array<Record<string, unknown>> = [];
  for (let i = 0; i < Math.min(seatsIn.length, 1200); i++) {
    const s = seatsIn[i];
    if (!s || typeof s !== "object") continue;
    const o = s as Record<string, unknown>;
    const tableId = String(o.tableId ?? "").slice(0, 80);
    if (!tableIds.has(tableId)) continue;
    seats.push({
      id: String(o.id ?? `seat-${i + 1}`).slice(0, 80),
      tableId,
      index: Math.max(0, Math.floor(toNum(o.index, i))),
      label: String(o.label ?? "").slice(0, 120),
      perimeterT: clamp01(toNum(o.perimeterT, 0)),
      ...(o.guestId != null && String(o.guestId).trim()
        ? { guestId: String(o.guestId).trim().slice(0, 80) }
        : {}),
    });
  }
  const floorImageUrl =
    src.floorImageUrl != null && String(src.floorImageUrl).trim()
      ? String(src.floorImageUrl).trim().slice(0, 2048)
      : undefined;
  let floorImageBase64: string | undefined;
  if (src.floorImageBase64 != null) {
    const b = String(src.floorImageBase64).trim();
    if (b.length > 0 && b.length <= 1_500_000) floorImageBase64 = b;
  }
  let venueFloorShape: string | undefined;
  if (src.venueFloorShape != null) {
    const v = String(src.venueFloorShape).trim();
    if (VENUE_FLOOR_SHAPES.has(v)) venueFloorShape = v;
  }
  const out: Record<string, unknown> = { version, tables, seats };
  if (floorImageUrl) out.floorImageUrl = floorImageUrl;
  if (floorImageBase64) out.floorImageBase64 = floorImageBase64;
  if (venueFloorShape) out.venueFloorShape = venueFloorShape;
  return out;
}
