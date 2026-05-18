/**
 * Event theme design (RunPod) + seating plan APIs for mobile and public clients.
 */
import type { Express, Request, Response } from "express";
import type pg from "pg";
import { CATERING_ORDER_TOUCH_SET } from "./sqlCompat.js";

const VENUE_FLOOR_SHAPES = new Set(["banquet_rect", "theater", "round_hall", "u_shape", "l_shape"]);
const TABLE_SHAPES = new Set(["rect", "round", "chair"]);
const SEATING_EDIT_STATUSES = new Set(["for_ongoing"]);
const THEME_EDIT_STATUSES = new Set([
  "online_inquiries",
  "new_event",
  "for_down_payment",
  "for_ongoing",
  "for_full_payment",
]);

type Deps = {
  getPool: () => pg.Pool;
  verifyPosStaff: (
    email: string,
    password: string,
    roles?: readonly string[],
  ) => Promise<{ ok: boolean; role: string | null }>;
};

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

async function resolveEventOrderRow(
  pool: pg.Pool,
  orderId: string,
  orderKind?: string,
): Promise<{ table: "event_orders" | "catering_orders"; row: Record<string, unknown> } | null> {
  const id = orderId.trim();
  if (!id) return null;
  if (orderKind === "event") {
    const { rows } = await pool.query(`SELECT * FROM event_orders WHERE id::text = $1 LIMIT 1`, [id]);
    if (rows[0]) return { table: "event_orders", row: rows[0] as Record<string, unknown> };
    return null;
  }
  if (orderKind === "catering") {
    const { rows } = await pool.query(`SELECT * FROM catering_orders WHERE id::text = $1 LIMIT 1`, [id]);
    if (rows[0]) return { table: "catering_orders", row: rows[0] as Record<string, unknown> };
    return null;
  }
  const ev = await pool.query(`SELECT * FROM event_orders WHERE id::text = $1 LIMIT 1`, [id]);
  if (ev.rows[0]) return { table: "event_orders", row: ev.rows[0] as Record<string, unknown> };
  const cat = await pool.query(`SELECT * FROM catering_orders WHERE id::text = $1 LIMIT 1`, [id]);
  if (cat.rows[0]) return { table: "catering_orders", row: cat.rows[0] as Record<string, unknown> };
  return null;
}

function canEditSeating(status: string): boolean {
  return SEATING_EDIT_STATUSES.has(String(status ?? "").trim().toLowerCase());
}

function isCateringPlusEvent(row: Record<string, unknown>, table: string): boolean {
  const ot = String(row.order_type ?? "").trim().toLowerCase();
  if (ot === "catering_event" || ot === "event") return true;
  if (table === "event_orders") return true;
  const title = String(row.event_title ?? "").trim();
  return title.length > 0;
}

async function ensureAiGenerationsTable(pool: pg.Pool): Promise<void> {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS ai_generations (
      id BIGSERIAL PRIMARY KEY,
      user_email TEXT NOT NULL DEFAULT '',
      image_url TEXT NOT NULL DEFAULT '',
      prompt TEXT NOT NULL DEFAULT '',
      design_meta JSONB NOT NULL DEFAULT '{}'::jsonb,
      job_id TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )`);
  await pool.query(`CREATE INDEX IF NOT EXISTS idx_ai_generations_user_email ON ai_generations (LOWER(user_email))`);
}

async function recordAiGeneration(
  pool: pg.Pool,
  opts: { userEmail: string; imageUrl: string; prompt: string; jobId?: string; designMeta?: Record<string, unknown> },
): Promise<void> {
  try {
    await ensureAiGenerationsTable(pool);
    await pool.query(
      `INSERT INTO ai_generations (user_email, image_url, prompt, design_meta, job_id)
       VALUES ($1, $2, $3, $4::jsonb, $5)`,
      [
        opts.userEmail.trim().toLowerCase(),
        opts.imageUrl,
        opts.prompt.slice(0, 8000),
        JSON.stringify(opts.designMeta ?? {}),
        opts.jobId ?? null,
      ],
    );
  } catch (e) {
    console.warn("[ai_generations] record skipped:", e instanceof Error ? e.message : e);
  }
}

function runpodConfig(): { apiKey: string; endpointId: string } | null {
  const apiKey = process.env.RUNPOD_API_KEY?.trim() ?? "";
  const endpointId = process.env.RUNPOD_ENDPOINT_ID?.trim() ?? "";
  if (!apiKey || !endpointId) return null;
  return { apiKey, endpointId };
}

function imageUrlFromRunpodOutput(output: unknown): string | null {
  if (!output || typeof output !== "object") return null;
  const o = output as Record<string, unknown>;
  const direct = o.image_url ?? o.imageUrl;
  if (typeof direct === "string" && direct.trim()) return direct.trim();
  const diag = o.diagnostics;
  if (diag && typeof diag === "object") {
    const pub = (diag as Record<string, unknown>).public_url ?? (diag as Record<string, unknown>).publicUrl;
    if (typeof pub === "string" && pub.trim()) return pub.trim();
  }
  const img = o.image;
  if (typeof img === "string" && img.startsWith("http")) return img.trim();
  return null;
}

async function runpodRun(input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const cfg = runpodConfig();
  if (!cfg) throw new Error("RunPod is not configured on the server (RUNPOD_API_KEY / RUNPOD_ENDPOINT_ID)");
  const res = await fetch(`https://api.runpod.ai/v2/${cfg.endpointId}/run`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${cfg.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ input }),
  });
  const data = (await res.json()) as Record<string, unknown>;
  if (!res.ok) {
    throw new Error(String(data.error ?? data.message ?? `RunPod HTTP ${res.status}`));
  }
  return data;
}

async function runpodStatus(jobId: string): Promise<Record<string, unknown>> {
  const cfg = runpodConfig();
  if (!cfg) throw new Error("RunPod is not configured on the server");
  const res = await fetch(`https://api.runpod.ai/v2/${cfg.endpointId}/status/${encodeURIComponent(jobId)}`, {
    headers: { Authorization: `Bearer ${cfg.apiKey}` },
  });
  const data = (await res.json()) as Record<string, unknown>;
  if (!res.ok) {
    throw new Error(String(data.error ?? data.message ?? `RunPod status HTTP ${res.status}`));
  }
  return data;
}

function mapRunpodResponse(data: Record<string, unknown>): Record<string, unknown> {
  const status = String(data.status ?? "").toUpperCase();
  const out: Record<string, unknown> = {
    status,
    id: data.id ?? null,
    error: data.error ?? null,
  };
  if (status === "COMPLETED") {
    out.output = data.output ?? null;
    const url = imageUrlFromRunpodOutput(data.output);
    if (url) out.image_url = url;
  }
  return out;
}

async function authorizeEventAccess(
  req: Request,
  pool: pg.Pool,
  orderId: string,
  orderKind: string | undefined,
  deps: Deps,
): Promise<{ table: "event_orders" | "catering_orders"; row: Record<string, unknown> } | null> {
  const resolved = await resolveEventOrderRow(pool, orderId, orderKind);
  if (!resolved) return null;
  const userEmail = String(req.body?.user_email ?? req.query?.user_email ?? "").trim().toLowerCase();
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (cashierEmail && cashierPassword) {
    const auth = await deps.verifyPosStaff(cashierEmail, cashierPassword, ["manager", "supervisor", "cashier"]);
    if (auth.ok) return resolved;
  }
  if (userEmail) {
    const rowEmail = String(resolved.row.email_address ?? "").trim().toLowerCase();
    const rowCustomer = String(resolved.row.customer_id ?? "").trim().toLowerCase();
    if (rowEmail === userEmail) return resolved;
    const { rows } = await pool.query(
      `SELECT 1 FROM customer_accounts WHERE LOWER(TRIM(email)) = $1 AND LOWER(TRIM(COALESCE(customer_id::text, ''))) = $2 LIMIT 1`,
      [userEmail, rowCustomer],
    );
    if (rows.length > 0) return resolved;
  }
  return null;
}

/** Seating layout is manager-only (POS manager credentials required). */
async function authorizeManagerSeatingAccess(
  req: Request,
  pool: pg.Pool,
  orderId: string,
  orderKind: string | undefined,
  deps: Deps,
): Promise<{ table: "event_orders" | "catering_orders"; row: Record<string, unknown> } | null> {
  const cashierEmail = String(req.body?.cashier_email ?? req.query?.cashier_email ?? "")
    .trim()
    .toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? req.query?.cashier_password ?? "");
  if (!cashierEmail || !cashierPassword) return null;
  const auth = await deps.verifyPosStaff(cashierEmail, cashierPassword, ["manager", "supervisor"]);
  if (!auth.ok) return null;
  return resolveEventOrderRow(pool, orderId, orderKind);
}

export function registerEventDesignSeatingRoutes(app: Express, deps: Deps): void {
  const pool = deps.getPool;

  app.post("/api/public/runpod/run", async (req, res) => {
    try {
      const bodyIn = req.body?.input;
      const input =
        bodyIn && typeof bodyIn === "object" && !Array.isArray(bodyIn)
          ? ({ ...(bodyIn as Record<string, unknown>) } as Record<string, unknown>)
          : {};
      const data = await runpodRun(input);
      const mapped = mapRunpodResponse(data);
      if (mapped.status === "COMPLETED") {
        const url = imageUrlFromRunpodOutput(mapped.output);
        const userId = String(input.user_id ?? input.user_email ?? "").trim().toLowerCase();
        if (url && userId) {
          await recordAiGeneration(pool(), {
            userEmail: userId,
            imageUrl: url,
            prompt: String(input.prompt ?? ""),
            designMeta: input,
          });
        }
      }
      res.json(mapped);
    } catch (err) {
      console.error(err);
      res.status(runpodConfig() ? 500 : 503).json({
        error: err instanceof Error ? err.message : "RunPod request failed",
      });
    }
  });

  app.get("/api/public/runpod/status/:jobId", async (req, res) => {
    try {
      const jobId = String(req.params.jobId ?? "").trim();
      if (!jobId) {
        res.status(400).json({ error: "job id required" });
        return;
      }
      const data = await runpodStatus(jobId);
      const mapped = mapRunpodResponse(data);
      if (mapped.status === "COMPLETED") {
        const url = imageUrlFromRunpodOutput(mapped.output);
        const out = mapped.output as Record<string, unknown> | null;
        const jobInput =
          data.input && typeof data.input === "object" && !Array.isArray(data.input)
            ? (data.input as Record<string, unknown>)
            : {};
        const userId = String(
          jobInput.user_id ?? jobInput.user_email ?? out?.user_id ?? out?.user_email ?? "",
        ).trim().toLowerCase();
        if (url && userId) {
          await recordAiGeneration(pool(), {
            userEmail: userId,
            imageUrl: url,
            prompt: String(jobInput.prompt ?? out?.prompt ?? ""),
            jobId,
            designMeta: { ...jobInput, ...(out ?? {}) },
          });
        }
      }
      res.json(mapped);
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: err instanceof Error ? err.message : "RunPod status failed" });
    }
  });

  app.get("/api/mobile/ai-generations", async (req, res) => {
    const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
    const orderId = String(req.query.order_id ?? "").trim();
    const designSessionId = String(req.query.design_session_id ?? "").trim();
    if (!userEmail) {
      res.status(400).json({ error: "user_email is required" });
      return;
    }
    try {
      await ensureAiGenerationsTable(pool());
      const params: string[] = [userEmail];
      let scopeSql = "";
      if (orderId) {
        params.push(orderId);
        scopeSql = ` AND (
          TRIM(COALESCE(design_meta->>'order_id', '')) = $2
          OR TRIM(COALESCE(design_meta->>'orderId', '')) = $2
        )`;
      } else if (designSessionId) {
        params.push(designSessionId);
        scopeSql = ` AND (
          TRIM(COALESCE(design_meta->>'design_session_id', '')) = $2
          OR TRIM(COALESCE(design_meta->>'designSessionId', '')) = $2
        )`;
      }
      const { rows } = await pool().query(
        `SELECT id::text, image_url, prompt, design_meta, job_id, created_at
         FROM ai_generations
         WHERE LOWER(TRIM(user_email)) = $1${scopeSql}
         ORDER BY created_at DESC
         LIMIT 48`,
        params,
      );
      res.json(rows);
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: "database error" });
    }
  });

  app.get("/api/mobile/events/:id/theme-design", async (req, res) => {
    const orderId = String(req.params.id ?? "").trim();
    const orderKind = String(req.query.order_kind ?? "").trim().toLowerCase();
    try {
      const access = await authorizeEventAccess(req, pool(), orderId, orderKind || undefined, deps);
      if (!access) {
        res.status(403).json({ error: "forbidden" });
        return;
      }
      if (access.table !== "event_orders") {
        res.json({ theme_design: {}, seating_plan: access.row.seating_plan ?? {} });
        return;
      }
      res.json({
        theme_design: access.row.theme_design ?? {},
        seating_plan: access.row.seating_plan ?? {},
        status: access.row.status,
        order_type: access.row.order_type,
      });
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: "database error" });
    }
  });

  app.put("/api/mobile/events/:id/theme-design", async (req, res) => {
    const orderId = String(req.params.id ?? "").trim();
    const orderKind = String(req.body?.order_kind ?? "").trim().toLowerCase();
    const themeDesign = req.body?.theme_design ?? req.body?.themeDesign;
    if (!orderId || themeDesign == null || typeof themeDesign !== "object") {
      res.status(400).json({ error: "id and theme_design object are required" });
      return;
    }
    try {
      const access = await authorizeEventAccess(req, pool(), orderId, orderKind || undefined, deps);
      if (!access) {
        res.status(403).json({ error: "forbidden" });
        return;
      }
      if (access.table !== "event_orders") {
        res.status(400).json({ error: "theme design applies to catering + event orders only" });
        return;
      }
      const st = String(access.row.status ?? "").trim().toLowerCase();
      if (!THEME_EDIT_STATUSES.has(st)) {
        res.status(400).json({ error: "theme design cannot be edited in this stage" });
        return;
      }
      const existing =
        access.row.theme_design && typeof access.row.theme_design === "object"
          ? (access.row.theme_design as Record<string, unknown>)
          : {};
      const merged = { ...existing, ...(themeDesign as Record<string, unknown>) };
      await pool().query(
        `UPDATE event_orders SET theme_design = $2::jsonb, ${CATERING_ORDER_TOUCH_SET} WHERE id::text = $1`,
        [orderId, JSON.stringify(merged)],
      );
      res.json({ ok: true, theme_design: merged });
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: "database error" });
    }
  });

  app.get("/api/mobile/events/:id/seating-plan", async (req, res) => {
    const orderId = String(req.params.id ?? "").trim();
    const orderKind = String(req.query.order_kind ?? "").trim().toLowerCase();
    try {
      const access = await authorizeManagerSeatingAccess(req, pool(), orderId, orderKind || undefined, deps);
      if (!access) {
        res.status(403).json({ error: "manager credentials required for seating layout" });
        return;
      }
      if (access.table !== "event_orders" || !isCateringPlusEvent(access.row, access.table)) {
        res.status(400).json({ error: "seating applies to catering + event orders only" });
        return;
      }
      res.json({
        seating_plan: access.row.seating_plan ?? {},
        status: access.row.status,
        can_edit: canEditSeating(String(access.row.status ?? "")),
      });
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: "database error" });
    }
  });

  app.put("/api/mobile/events/:id/seating-plan", async (req, res) => {
    const orderId = String(req.params.id ?? "").trim();
    const orderKind = String(req.body?.order_kind ?? "").trim().toLowerCase();
    const rawPlan = req.body?.seating_plan ?? req.body?.seatingPlan;
    if (!orderId || rawPlan == null) {
      res.status(400).json({ error: "id and seating_plan are required" });
      return;
    }
    try {
      const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
      const cashierPassword = String(req.body?.cashier_password ?? "");
      const auth = await deps.verifyPosStaff(cashierEmail, cashierPassword, ["manager"]);
      if (!auth.ok) {
        res.status(403).json({ error: "manager credentials required to edit seating layout" });
        return;
      }
      const access = await resolveEventOrderRow(pool(), orderId, orderKind || undefined);
      if (!access) {
        res.status(404).json({ error: "order not found" });
        return;
      }
      if (access.table !== "event_orders" || !isCateringPlusEvent(access.row, access.table)) {
        res.status(400).json({ error: "seating applies to catering + event orders only" });
        return;
      }
      const st = String(access.row.status ?? "").trim().toLowerCase();
      if (!canEditSeating(st)) {
        res.status(400).json({ error: "seating can only be edited while order is in For Processing" });
        return;
      }
      const normalized = normalizeSeatingPlan(rawPlan);
      await pool().query(
        `UPDATE event_orders SET seating_plan = $2::jsonb, ${CATERING_ORDER_TOUCH_SET} WHERE id::text = $1`,
        [orderId, JSON.stringify(normalized)],
      );
      res.json({ ok: true, seating_plan: normalized });
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: "database error" });
    }
  });
}
