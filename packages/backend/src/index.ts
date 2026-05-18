import "./envBootstrap.js";
import crypto from "node:crypto";
import bcrypt from "bcrypt";
import cors from "cors";
import express from "express";
import {
  isMailConfigured,
  mailUsesResend,
  sendMailRequired,
  sendMailSafe,
  sendMailWithPdfAttachment,
  sendMailWithPdfRequired,
} from "./mail.js";
import {
  formatDbStartupError,
  getPool,
  getRestaurantOrdersCustomerIdKind,
  initDb,
} from "./db.js";
import { normalizeSeatingPlan, registerEventDesignSeatingRoutes } from "./eventDesignSeating.js";
import {
  CASHIER_ONLINE_ORDER_WHERE,
  CATERING_TRANSACTION_ID,
  CUSTOMER_ACCOUNT_TOUCH,
  CUSTOMER_FORGOT_OTP_SELECT,
  normalizeOtpDigits,
  normalizePaymentProofBase64,
  RESTAURANT_ORDER_BUSINESS_ID_SQL,
  sqlOtpMatches,
  EVENT_TRANSACTION_ID,
  POST_ANALYSIS_JSON,
  RESTAURANT_ORDER_PATCH_SELECT,
  RESTAURANT_ORDER_SELECT,
  CATERING_ORDER_CREATED_AT_SQL,
  CATERING_ORDER_UPDATED_AT_SQL,
  CATERING_ORDER_TOUCH_SET,
  RESTAURANT_ORDER_CREATED_AT_SQL,
  RESTAURANT_ORDER_UPDATED_AT_SQL,
  RESTAURANT_ORDER_TOUCH_SET,
  RESTAURANT_ORDER_ORDER_BY_CREATED_DESC,
  RESTAURANT_ORDER_ORDER_BY_UPDATED_DESC,
  buildCustomerForgotOtpClearSet,
  buildCustomerForgotOtpUpdateSet,
  buildCustomerForgotOtpValidWhere,
  mapProfileRowForApi,
  mapRestaurantOrderRowForApi,
  restaurantLoyaltyEarnedSql,
  isPgUndefinedColumn,
  getRestaurantOrderSelectSql,
  getRestaurantOrderPatchSelectSql,
  getCashierOnlineOrderWhereSql,
  getRestaurantOrderCreatedAtSql,
  getRestaurantOrderUpdatedAtSql,
  getRestaurantOrderChangedSinceSql,
  getCateringOrderCreatedAtSql,
  restaurantOrderMatchesEmailWhere,
  restaurantOrderEmailExpr,
  restaurantLoyaltyEarnedSqlAsync,
  getTrayDraftColumns,
} from "./sqlCompat.js";
import {
  mapManagerCateringStageToDb,
  cateringStatusesForApiStage,
  normalizeCateringStatusForApi,
  CATERING_ACTIVE_SCHEDULE_STATUSES_SQL,
  CATERING_BILLING_LATE_STATUSES_SQL,
  processingSubstageFromRow,
} from "./cateringStages.js";

function isCashierOnlineRestaurantOrder(row: {
  order_source?: string | null;
  user_email?: string | null;
  guest_contact_email?: string | null;
}): boolean {
  if (String(row.order_source ?? "").trim().toUpperCase() === "POS") return false;
  const email = String(row.user_email ?? "").trim();
  const guest = String(row.guest_contact_email ?? "").trim();
  return email.length > 0 || guest.length > 0;
}
import {
  guestReachFromRow,
  isGuestUserEmail,
  nextGuestCustomerId,
  notifyRestaurantOrderCustomer,
  sendGuestOrderProofConfirmation,
} from "./guestNotify.js";
import { ensureIdCounterRow, nextCusIdFromCounter, nextTrIdFromCounter } from "./idCounters.js";
import { parseAllergenNamesFromRow, queryAllergensCatalog } from "./menuAllergens.js";
import { buildMenuSql, buildSetMenusSql, MINIMAL_PUBLIC_MENU_SQL } from "./menuQuery.js";
import { DEFAULT_PUBLIC_SET_MENUS_SQL } from "./webMenu.js";
import {
  columnExists,
  CUSTOMER_ACCOUNT_STAMP_SQL,
  menuDishesChangedSinceSql,
  menuDishesMaxStampExpr,
} from "./schemaColumns.js";
import { resolveSetMenusSql } from "./webMenu.js";

if (isMailConfigured()) {
  if (mailUsesResend()) {
    console.info(
      "[mail] Resend API (HTTPS) enabled — OTP and notification emails bypass outbound SMTP (recommended on Railway Hobby / blocked SMTP).",
    );
  } else {
    console.info("[mail] SMTP credentials loaded; OTP and notification emails are enabled.");
  }
} else {
  console.warn(
    "[mail] Mail not configured. On Railway Free/Hobby, outbound SMTP (465/587) is often blocked — use RESEND_API_KEY + RESEND_FROM (see .env.example), or upgrade for SMTP. Otherwise set TRANSPORTER_EMAIL + TRANSPORTER_PASSWORD.",
  );
}

const app = express();
const port = Number(process.env.PORT) || 8080;
const otpExpiryMinutes = Number(process.env.MOBILE_OTP_EXPIRY_MINUTES) || 15;
/** When true and SMTP is not configured, OTPs are logged to the server console instead of emailed (local dev only). */
const mobileDevOtpLogging = String(process.env.MOBILE_DEV_OTP_LOGGING ?? "").trim() === "true";
let ensureNewEventSchemaPromise: Promise<void> | null = null;

app.use(cors());
app.use(express.json({ limit: "15mb" }));
app.use((req, _res, next) => {
  if (!req.path.startsWith("/api/mobile/")) {
    next();
    return;
  }
  const body = (req.body ?? {}) as Record<string, unknown>;
  const actorEmail =
    String(
      body.user_email ??
        body.email ??
        body.identity ??
        body.cashier_email ??
        req.query.user_email ??
        req.query.email ??
        "",
    )
      .trim()
      .toLowerCase();
  const details = `${req.method.toUpperCase()} ${req.path}`;
  void logActionBestEffort(
    "api.request",
    actorEmail,
    details,
    {
      query: req.query ?? {},
    },
  );
  next();
});

function ensureNewEventSchemaOnce(): Promise<void> {
  if (ensureNewEventSchemaPromise != null) return ensureNewEventSchemaPromise;
  ensureNewEventSchemaPromise = (async () => {
    const p = getPool();
    // Runtime self-heal for environments that missed some migrations.
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS checklist JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS checklist JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS payment_method TEXT NOT NULL DEFAULT 'cash'`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS payment_method TEXT NOT NULL DEFAULT 'cash'`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS cost_breakdown JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS cost_breakdown JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS labor_cost NUMERIC NOT NULL DEFAULT 0`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS labor_cost NUMERIC NOT NULL DEFAULT 0`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS travel_cost NUMERIC NOT NULL DEFAULT 0`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS travel_cost NUMERIC NOT NULL DEFAULT 0`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS full_payment_due_at TIMESTAMPTZ`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS full_payment_due_at TIMESTAMPTZ`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS stage_entered_at TIMESTAMPTZ DEFAULT NOW()`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS stage_entered_at TIMESTAMPTZ DEFAULT NOW()`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS updated_by TEXT`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS updated_by TEXT`);
    await p.query(
      `ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS inquiry_additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`,
    );
    await p.query(
      `ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS inquiry_additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`,
    );
    await p.query(
      `ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS stage_additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`,
    );
    await p.query(
      `ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS stage_additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`,
    );
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS loyalty_points_catering_obtained INTEGER NOT NULL DEFAULT 0`);
    await p.query(
      `ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS loyalty_points_catering_obtained INTEGER NOT NULL DEFAULT 0`,
    );
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS submitted_order_dt_stamp TIMESTAMPTZ`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS submitted_order_dt_stamp TIMESTAMPTZ`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS last_updated_order_status_dt_stamp TIMESTAMPTZ`);
    await p.query(
      `ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS last_updated_order_status_dt_stamp TIMESTAMPTZ`,
    );
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW()`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW()`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW()`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW()`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS allergens JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS allergens JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS address_lat DOUBLE PRECISION`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS address_lng DOUBLE PRECISION`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS address_lat DOUBLE PRECISION`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS address_lng DOUBLE PRECISION`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS final_status TEXT`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS final_status TEXT`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS down_payment_reference TEXT`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS down_payment_reference TEXT`);
    await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS full_payment_reference TEXT`);
    await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS full_payment_reference TEXT`);
    await p.query(`ALTER TABLE event_orders DROP CONSTRAINT IF EXISTS event_orders_status_check`);
    await p.query(`ALTER TABLE catering_orders DROP CONSTRAINT IF EXISTS catering_orders_status_check`);
    await p.query(
      `UPDATE event_orders SET status = 'for_full_payment' WHERE LOWER(TRIM(status)) = 'for_post_analysis'`,
    );
    await p.query(
      `UPDATE catering_orders SET status = 'for_full_payment' WHERE LOWER(TRIM(status)) = 'for_post_analysis'`,
    );
    const splitLegacyProcessing = `
      UPDATE catering_orders SET status = 'for_ongoing'
      WHERE LOWER(TRIM(status)) = 'for_processing'
        AND (
          LOWER(TRIM(COALESCE(checklist->'post_analysis'->>'processing_phase', ''))) = 'ongoing'
          OR (
            jsonb_typeof(COALESCE(checklist, '[]'::jsonb)) = 'object'
            AND COALESCE(jsonb_array_length(COALESCE(checklist->'items', '[]'::jsonb)), 0) > 0
          )
        );
      UPDATE catering_orders SET status = 'for_down_payment'
      WHERE LOWER(TRIM(status)) = 'for_processing';
      UPDATE event_orders SET status = 'for_ongoing'
      WHERE LOWER(TRIM(status)) = 'for_processing'
        AND (
          LOWER(TRIM(COALESCE(checklist->'post_analysis'->>'processing_phase', ''))) = 'ongoing'
          OR (
            jsonb_typeof(COALESCE(checklist, '[]'::jsonb)) = 'object'
            AND COALESCE(jsonb_array_length(COALESCE(checklist->'items', '[]'::jsonb)), 0) > 0
          )
        );
      UPDATE event_orders SET status = 'for_down_payment'
      WHERE LOWER(TRIM(status)) = 'for_processing';
    `;
    await p.query(splitLegacyProcessing);
    const allowedStatuses = `'new_event', 'online_inquiries', 'for_down_payment', 'for_ongoing', 'for_full_payment', 'completed', 'cancelled'`;
    await p.query(`
      UPDATE event_orders SET status = 'new_event'
      WHERE LOWER(TRIM(COALESCE(status, ''))) NOT IN (${allowedStatuses})
    `);
    await p.query(`
      UPDATE catering_orders SET status = 'new_event'
      WHERE LOWER(TRIM(COALESCE(status, ''))) NOT IN (${allowedStatuses})
    `);
    await p.query(`
      ALTER TABLE event_orders ADD CONSTRAINT event_orders_status_check
      CHECK (status = ANY (ARRAY[
        'new_event'::text, 'online_inquiries'::text, 'for_down_payment'::text, 'for_ongoing'::text,
        'for_full_payment'::text, 'completed'::text, 'cancelled'::text
      ]))
    `).catch((err) => console.warn("[schema] event_orders_status_check:", err));
    await p.query(`
      ALTER TABLE catering_orders ADD CONSTRAINT catering_orders_status_check
      CHECK (status = ANY (ARRAY[
        'new_event'::text, 'online_inquiries'::text, 'for_down_payment'::text, 'for_ongoing'::text,
        'for_full_payment'::text, 'completed'::text, 'cancelled'::text
      ]))
    `).catch((err) => console.warn("[schema] catering_orders_status_check:", err));
  })().catch((err) => {
    ensureNewEventSchemaPromise = null;
    throw err;
  });
  return ensureNewEventSchemaPromise;
}

let ensureRestaurantOrdersApiSchemaPromise: Promise<void> | null = null;

let ensureCustomerTrayDraftsSchemaPromise: Promise<void> | null = null;

function ensureCustomerTrayDraftsSchemaOnce(): Promise<void> {
  if (ensureCustomerTrayDraftsSchemaPromise != null) return ensureCustomerTrayDraftsSchemaPromise;
  ensureCustomerTrayDraftsSchemaPromise = (async () => {
    const p = getPool();
    await p.query(`
      CREATE TABLE IF NOT EXISTS customer_tray_drafts (
        email TEXT PRIMARY KEY,
        tray_lines JSONB NOT NULL DEFAULT '[]'::jsonb,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
    `);
    await p.query(`ALTER TABLE customer_tray_drafts ADD COLUMN IF NOT EXISTS email TEXT`);
    await p.query(`ALTER TABLE customer_tray_drafts ADD COLUMN IF NOT EXISTS user_email TEXT`);
    await p.query(`ALTER TABLE customer_tray_drafts ADD COLUMN IF NOT EXISTS tray_lines JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE customer_tray_drafts ADD COLUMN IF NOT EXISTS tray_items JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(
      `ALTER TABLE customer_tray_drafts ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`,
    );
    await p.query(`
      UPDATE customer_tray_drafts
      SET email = LOWER(TRIM(user_email))
      WHERE (email IS NULL OR TRIM(email) = '')
        AND user_email IS NOT NULL AND TRIM(user_email) <> ''
    `).catch(() => {});
  })().catch((err) => {
    ensureCustomerTrayDraftsSchemaPromise = null;
    throw err;
  });
  return ensureCustomerTrayDraftsSchemaPromise;
}

/** Self-heal canonical restaurant_orders columns used by customer menu/orders APIs. */
function ensureRestaurantOrdersApiSchemaOnce(): Promise<void> {
  if (ensureRestaurantOrdersApiSchemaPromise != null) return ensureRestaurantOrdersApiSchemaPromise;
  ensureRestaurantOrdersApiSchemaPromise = (async () => {
    const p = getPool();
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS tray_items JSONB NOT NULL DEFAULT '[]'::jsonb`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS total_cost NUMERIC(12,2)`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_id TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_notes TEXT NOT NULL DEFAULT ''`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_tracking_url TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_proof_initial TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_proof_balance TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_uploaded_initial BOOLEAN NOT NULL DEFAULT FALSE`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_uploaded_balance BOOLEAN NOT NULL DEFAULT FALSE`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_confirmed_initial BOOLEAN NOT NULL DEFAULT FALSE`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_confirmed_balance BOOLEAN NOT NULL DEFAULT FALSE`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_status TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS loyalty_points_restaurant_obtained INTEGER NOT NULL DEFAULT 0`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS submitted_order_dt_stamp TIMESTAMPTZ`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS last_updated_order_status_dt_stamp TIMESTAMPTZ`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS guest_contact_email TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_lat DOUBLE PRECISION`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_lng DOUBLE PRECISION`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS feedback_stars INTEGER`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS feedback_remarks TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS amount_paid NUMERIC(12,2)`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS change_given NUMERIC(12,2)`);
    await p.query(
      `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS balance_proof_pending_review BOOLEAN NOT NULL DEFAULT FALSE`,
    );
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_mode TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_reference_initial TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_reference_balance TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS full_name TEXT NOT NULL DEFAULT ''`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS contact_number TEXT NOT NULL DEFAULT ''`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_address TEXT NOT NULL DEFAULT ''`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_time TEXT`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_source TEXT`);
    await p.query(
      `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS pos_customer_label TEXT NOT NULL DEFAULT ''`,
    );
    await p.query(
      `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS cashier_amount_received_initial NUMERIC(12,2)`,
    );
    await p.query(
      `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS cashier_amount_received_balance NUMERIC(12,2)`,
    );
    await p.query(
      `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS loyalty_points_catering_obtained INTEGER NOT NULL DEFAULT 0`,
    );
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ`);
    await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ`);
  })().catch((err) => {
    ensureRestaurantOrdersApiSchemaPromise = null;
    throw err;
  });
  return ensureRestaurantOrdersApiSchemaPromise;
}

/** Cashier POS + customer orders share restaurant_orders canonical columns. */
function ensureCashierPosSchemaOnce(): Promise<void> {
  return ensureRestaurantOrdersApiSchemaOnce();
}

function parseJsonTextArray(raw: unknown): string[] {
  if (raw == null) return [];
  if (Array.isArray(raw)) {
    return raw.map((x) => String(x)).filter((t) => t.trim().length > 0);
  }
  const s = String(raw).trim();
  if (!s) return [];
  try {
    const v = JSON.parse(s);
    return Array.isArray(v) ? v.map((x) => String(x)).filter((t) => t.trim().length > 0) : [];
  } catch {
    return [];
  }
}

function processingSubstageFromPostAndChecklist(postAnalysis: unknown, checklistRaw: unknown): "down_payment" | "ongoing" {
  const post = postAnalysis && typeof postAnalysis === "object" ? (postAnalysis as Record<string, unknown>) : {};
  const raw = String(post.processing_phase ?? "").trim().toLowerCase();
  if (raw === "ongoing") return "ongoing";
  if (raw === "down_payment") return "down_payment";
  if (normalizeChecklist(checklistRaw).length > 0) return "ongoing";
  return "down_payment";
}

const fallbackThemeSuggestions: Array<Record<string, string>> = [
  {
    title: "Elegant Event Tablescape",
    source: "fallback",
    imageUrl: "https://images.unsplash.com/photo-1519225421980-715cb0215aed",
    thumbnailUrl: "https://images.unsplash.com/photo-1519225421980-715cb0215aed",
  },
  {
    title: "Floral Centerpiece Inspiration",
    source: "fallback",
    imageUrl: "https://images.unsplash.com/photo-1478146059778-26028b07395a",
    thumbnailUrl: "https://images.unsplash.com/photo-1478146059778-26028b07395a",
  },
  {
    title: "Modern Reception Setup",
    source: "fallback",
    imageUrl: "https://images.unsplash.com/photo-1469371670807-013ccf25f16a",
    thumbnailUrl: "https://images.unsplash.com/photo-1469371670807-013ccf25f16a",
  },
  {
    title: "Garden Party Decor",
    source: "fallback",
    imageUrl: "https://images.unsplash.com/photo-1522673607200-164d1b6ce486",
    thumbnailUrl: "https://images.unsplash.com/photo-1522673607200-164d1b6ce486",
  },
  {
    title: "Romantic Wedding Setup",
    source: "fallback",
    imageUrl: "https://images.unsplash.com/photo-1511285560929-80b456fea0bc",
    thumbnailUrl: "https://images.unsplash.com/photo-1511285560929-80b456fea0bc",
  },
];

function buildPexelsQuery(params: {
  eventTitle?: unknown;
  eventType?: unknown;
  formalityLevel?: unknown;
  prompt?: unknown;
  baseImageUrl?: unknown;
  forceNoPeople?: boolean;
}): string {
  const {
    eventTitle,
    eventType,
    formalityLevel,
    prompt,
    baseImageUrl,
    forceNoPeople = true,
  } = params;
  return [
    String(eventType ?? "").trim(),
    String(formalityLevel ?? "").trim(),
    String(eventTitle ?? "").trim(),
    String(prompt ?? "").trim(),
    baseImageUrl ? "matching style composition" : "",
    "event decor background",
    forceNoPeople ? "-people -person -human -portrait -face -model -selfie" : "",
  ]
    .filter(Boolean)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

function sanitizeThemeSuggestions(rows: unknown): Array<Record<string, string>> {
  if (!Array.isArray(rows)) return [];
  return rows
    .filter((row) => row && typeof row === "object")
    .map((row) => row as Record<string, unknown>)
    .filter((row) => {
      const text = [
        row.title,
        row.description,
        row.imageUrl,
        row.thumbnailUrl,
        row.pexelsUrl,
      ]
        .map((v) => String(v ?? "").toLowerCase())
        .join(" ");
      const looksPeople = /\b(person|people|human|portrait|selfie|face|man|woman|model|boy|girl|bride|groom|crowd|group)\b/.test(text);
      const looksDecor = /\b(decor|decoration|event|venue|hall|setup|tablescape|table|centerpiece|balloon|floral|flower|banquet|reception|aisle|stage|backdrop|dinner|wedding|birthday|celebration)\b/.test(
        text,
      );
      return !looksPeople && looksDecor;
    })
    .map((row) => ({
      title: String(row.title ?? "Theme suggestion"),
      source: String(row.source ?? "fallback"),
      imageUrl: String(row.imageUrl ?? ""),
      thumbnailUrl: String(row.thumbnailUrl ?? row.imageUrl ?? ""),
      photographer: String(row.photographer ?? ""),
      pexelsUrl: String(row.pexelsUrl ?? ""),
    }))
    .filter((row) => row.imageUrl.trim().length > 0);
}

async function fetchPexelsImages(params: {
  query: string;
  perPage?: number;
  page?: number;
}): Promise<{ images: Array<Record<string, string>>; error: string; rateLimited: boolean }> {
  const pexelsKey = String(process.env.PEXELS_API_KEY ?? "").trim();
  const { query, perPage = 20, page = 1 } = params;
  if (!pexelsKey) {
    return { images: [], error: "PEXELS_API_KEY is not configured", rateLimited: false };
  }
  if (!query.trim()) {
    return { images: [], error: "search query is empty", rateLimited: false };
  }
  const url = new URL("https://api.pexels.com/v1/search");
  url.searchParams.set("query", query);
  url.searchParams.set("per_page", String(Math.max(1, Math.min(perPage, 30))));
  url.searchParams.set("page", String(Math.max(1, page)));
  url.searchParams.set("orientation", "landscape");

  try {
    const upstream = await fetch(url, {
      method: "GET",
      headers: { Authorization: pexelsKey },
    });
    if (upstream.status === 429) {
      return { images: [], error: "Pexels rate limit reached. Please wait and try again.", rateLimited: true };
    }
    if (!upstream.ok) {
      const t = await upstream.text().catch(() => "");
      return {
        images: [],
        error: `Pexels request failed (${upstream.status})${t ? `: ${t.slice(0, 160)}` : ""}`,
        rateLimited: false,
      };
    }
    const json = (await upstream.json().catch(() => ({}))) as Record<string, unknown>;
    const rows = Array.isArray(json.photos) ? json.photos : [];
    const images = rows
      .filter((row: unknown) => row && typeof row === "object")
      .map((row: unknown) => {
        const r = row as Record<string, unknown>;
        const src = (r.src ?? {}) as Record<string, unknown>;
        return {
          title: String(r.alt ?? "Pexels theme suggestion"),
          source: "pexels",
          thumbnailUrl: String(src.medium ?? src.small ?? ""),
          imageUrl: String(src.large2x ?? src.large ?? src.original ?? ""),
          photographer: String(r.photographer ?? ""),
          pexelsUrl: String(r.url ?? ""),
        };
      })
      .filter((row) => row.imageUrl.trim().length > 0);
    return { images: sanitizeThemeSuggestions(images), error: "", rateLimited: false };
  } catch (err) {
    return {
      images: [],
      error: `Pexels request failed: ${err instanceof Error ? err.message : String(err)}`,
      rateLimited: false,
    };
  }
}

const AI_SERVICE_BASE_URL = String(process.env.AI_SERVICE_BASE_URL ?? process.env.FASTAPI_INTERNAL_URL ?? "").replace(
  /\/+$/,
  "",
);
const AI_SERVICE_TIMEOUT_SEGMENT_MS = Number(process.env.AI_SERVICE_TIMEOUT_SEGMENT_MS ?? 20000);
const AI_SERVICE_TIMEOUT_RECOLOR_MS = Number(process.env.AI_SERVICE_TIMEOUT_RECOLOR_MS ?? 8000);
const AI_SERVICE_TIMEOUT_COMPOSE_MS = Number(process.env.AI_SERVICE_TIMEOUT_COMPOSE_MS ?? 12000);
const AI_SERVICE_TIMEOUT_ADD_BY_PROMPT_MS = Number(process.env.AI_SERVICE_TIMEOUT_ADD_BY_PROMPT_MS ?? 180000);
const AI_SERVICE_SEGMENT_TIMEOUT_RETRIES = Math.max(0, Number(process.env.AI_SERVICE_SEGMENT_TIMEOUT_RETRIES ?? 1));
const AI_SERVICE_TOKEN = String(process.env.AI_SERVICE_TOKEN ?? "").trim();
const AI_SERVICE_MAX_IMAGE_BYTES = Number(process.env.AI_SERVICE_MAX_IMAGE_BYTES ?? 8_000_000);

function ensureHexColor(rawValue: unknown, fallback = "#f4511e"): string {
  const value = String(rawValue ?? "").trim();
  const match = value.match(/^#?([0-9a-f]{6})$/i);
  if (!match) return String(fallback).toLowerCase();
  return `#${match[1].toLowerCase()}`;
}

function sanitizeBase64Image(input: unknown): string {
  if (typeof input !== "string" || !input.trim()) {
    throw new Error("imageBase64 is required");
  }
  const value = input.trim();
  const cleaned = value.includes(",") ? value.split(",").pop() : value;
  if (!cleaned || !/^[A-Za-z0-9+/=\s]+$/.test(cleaned)) {
    throw new Error("imageBase64 must be valid base64");
  }
  const sizeBytes = Buffer.byteLength(cleaned, "base64");
  if (sizeBytes <= 0 || sizeBytes > AI_SERVICE_MAX_IMAGE_BYTES) {
    throw new Error(`imageBase64 exceeds size limit (${AI_SERVICE_MAX_IMAGE_BYTES} bytes)`);
  }
  return cleaned;
}

function normalizePolygonPoints(raw: unknown): Array<{ x: number; y: number }> {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((p: unknown) => {
      if (!p || typeof p !== "object") return null;
      const o = p as Record<string, unknown>;
      const x = Number(o.x ?? o.left ?? 0);
      const y = Number(o.y ?? o.top ?? 0);
      if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
      return { x, y };
    })
    .filter((p): p is { x: number; y: number } => p != null);
}

async function callAiService(routePath: string, payload: Record<string, unknown>, timeoutMs: number): Promise<Record<string, unknown>> {
  if (!AI_SERVICE_BASE_URL) {
    throw new Error("AI service is not configured (AI_SERVICE_BASE_URL missing)");
  }
  let lastErr: unknown;
  const maxAttempts = 1 + AI_SERVICE_SEGMENT_TIMEOUT_RETRIES;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), Math.max(1000, timeoutMs));
    try {
      const headers: Record<string, string> = { "Content-Type": "application/json" };
      if (AI_SERVICE_TOKEN) {
        headers.Authorization = `Bearer ${AI_SERVICE_TOKEN}`;
        headers["X-AI-Service-Token"] = AI_SERVICE_TOKEN;
      }
      const response = await fetch(`${AI_SERVICE_BASE_URL}${routePath}`, {
        method: "POST",
        headers,
        body: JSON.stringify(payload),
        signal: ctrl.signal,
      });
      const json = (await response.json().catch(() => ({}))) as Record<string, unknown>;
      if (!response.ok) {
        const msg = String(json.error ?? json.message ?? `AI service error (${response.status})`);
        if (response.status >= 500 && attempt < maxAttempts) {
          await new Promise((r) => setTimeout(r, 300 * attempt));
          continue;
        }
        throw new Error(msg);
      }
      return json;
    } catch (err) {
      lastErr = err;
      const message = err instanceof Error ? err.message : String(err);
      const transient =
        message.includes("ECONNRESET") ||
        message.includes("UND_ERR_SOCKET") ||
        message.includes("fetch failed") ||
        message.includes("aborted");
      if (!transient || attempt >= maxAttempts) {
        break;
      }
      await new Promise((r) => setTimeout(r, 300 * attempt));
    } finally {
      clearTimeout(timer);
    }
  }
  throw (lastErr instanceof Error ? lastErr : new Error(String(lastErr ?? "AI service request failed")));
}

function toNum(v: unknown, fallback = 0): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

/** Parsed calendar day + local minutes for catering schedule overlap checks. */
interface CateringScheduleWindow {
  y: number;
  mo: number;
  d: number;
  sm: number;
  em: number;
}

function parseScheduleSlotDate(v: unknown): { y: number; mo: number; d: number } | null {
  const s = String(v ?? "").trim();
  if (!s) return null;
  const dt = new Date(s);
  if (Number.isNaN(dt.getTime())) return null;
  return { y: dt.getFullYear(), mo: dt.getMonth() + 1, d: dt.getDate() };
}

function parseScheduleTimeMinutes(v: unknown): number | null {
  const m = /^(\d{1,2}):(\d{2})/.exec(String(v ?? "").trim());
  if (!m) return null;
  const hh = Number(m[1]);
  const mm = Number(m[2]);
  if (!Number.isFinite(hh) || !Number.isFinite(mm)) return null;
  if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
  return hh * 60 + mm;
}

function windowsFromScheduleSlots(raw: unknown): CateringScheduleWindow[] {
  const out: CateringScheduleWindow[] = [];
  let arr: unknown[] = [];
  if (raw == null) return out;
  if (Array.isArray(raw)) arr = raw;
  else if (typeof raw === "object") arr = [raw];
  else if (typeof raw === "string") {
    const t = raw.trim();
    if (!t.startsWith("[") && !t.startsWith("{")) return out;
    try {
      const j = JSON.parse(t) as unknown;
      if (Array.isArray(j)) arr = j;
      else if (j && typeof j === "object") arr = [j];
    } catch {
      return out;
    }
  }
  for (const item of arr) {
    if (!item || typeof item !== "object") continue;
    const o = item as Record<string, unknown>;
    const date = parseScheduleSlotDate(o.date ?? o.label);
    const sm = parseScheduleTimeMinutes(o.from);
    const em = parseScheduleTimeMinutes(o.to);
    if (!date || sm == null || em == null) continue;
    if (em <= sm) continue;
    out.push({ ...date, sm, em });
  }
  return out;
}

function cateringWindowsOverlap(a: CateringScheduleWindow, b: CateringScheduleWindow): boolean {
  if (a.y !== b.y || a.mo !== b.mo || a.d !== b.d) return false;
  return a.sm < b.em && a.em > b.sm;
}

/** Count of *other* For Processing orders whose event window overlaps this row on the same calendar day. */
function attachForProcessingScheduleOverlaps(rows: Array<Record<string, unknown>>): void {
  const parsed = rows.map((r) => ({
    id: String(r.id ?? "").trim(),
    wins: windowsFromScheduleSlots(r.schedule_slots),
  }));
  for (let i = 0; i < parsed.length; i++) {
    let overlapsOtherOrders = 0;
    for (let j = 0; j < parsed.length; j++) {
      if (i === j) continue;
      let hit = false;
      for (const wa of parsed[i].wins) {
        for (const wb of parsed[j].wins) {
          if (cateringWindowsOverlap(wa, wb)) {
            hit = true;
            break;
          }
        }
        if (hit) break;
      }
      if (hit) overlapsOtherOrders++;
    }
    rows[i].processing_schedule_overlaps = overlapsOtherOrders;
  }
}

async function logActionBestEffort(
  action: string,
  actorEmail: string,
  details: string,
  metadata: Record<string, unknown> = {},
) {
  try {
    await getPool().query(
      `INSERT INTO action_logs (actor_email, action, details, metadata, created_at)
       VALUES ($1, $2, $3, $4::jsonb, NOW())`,
      [actorEmail, action, details, JSON.stringify(metadata)],
    );
  } catch {
    // best effort only
  }
}

async function resolveCustomerAccountByIdentity(identityRaw: string): Promise<{
  email: string;
  phone_number: string;
} | null> {
  const identity = identityRaw.trim().toLowerCase();
  if (!identity) return null;
  const { rows } = await getPool().query(
    `SELECT email, contact_number AS phone_number
     FROM customer_accounts
     WHERE LOWER(email) = $1
        OR REGEXP_REPLACE(COALESCE(contact_number, ''), '[^0-9]+', '', 'g') = REGEXP_REPLACE($1, '[^0-9]+', '', 'g')
     LIMIT 1`,
    [identity],
  );
  const row = rows[0] as { email: string; phone_number: string } | undefined;
  return row ?? null;
}

async function customerBusinessIdForEmail(emailRaw: string): Promise<string | null> {
  const email = emailRaw.trim().toLowerCase();
  if (!email) return null;
  try {
    const { rows } = await getPool().query(
      `SELECT NULLIF(TRIM(customer_id), '') AS customer_id
       FROM customer_accounts
       WHERE LOWER(TRIM(email)) = $1
       LIMIT 1`,
      [email],
    );
    return (rows[0] as { customer_id: string | null } | undefined)?.customer_id ?? null;
  } catch {
    return null;
  }
}

/** @deprecated Use [customerBusinessIdForEmail]. */
async function customerProfileIdForEmail(emailRaw: string): Promise<string | null> {
  return customerBusinessIdForEmail(emailRaw);
}

/** Resolves `restaurant_orders.customer_id` (CUS-**** from customer_accounts). */
async function restaurantOrderCustomerIdForCheckout(userEmail: string, isGuest: boolean): Promise<string | null> {
  if (isGuest) return await nextGuestCustomerId();
  return customerBusinessIdForEmail(userEmail.trim().toLowerCase());
}

async function nextTransactionNo(_kind: "catering" | "event"): Promise<string> {
  void _kind;
  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    await ensureIdCounterRow(client, "TR", 0);
    const id = await nextTrIdFromCounter(client);
    await client.query("COMMIT");
    return id;
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

type ChecklistItem = {
  item: string;
  description: string;
  quantity: string;
  cost: string;
  status: "completed" | "not done";
};

type TaskAssignmentRow = {
  employee: string;
  tasks: string;
  schedule_of_tasks: string;
  budget: string;
  status: "completed" | "not done";
};

function checklistItemsRaw(raw: unknown): unknown {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    const wrapped = raw as Record<string, unknown>;
    if (Array.isArray(wrapped.items)) return wrapped.items;
  }
  return raw;
}

function postAnalysisFromChecklistRaw(raw: unknown): Record<string, unknown> {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    const pa = (raw as Record<string, unknown>).post_analysis;
    if (pa && typeof pa === "object") return pa as Record<string, unknown>;
  }
  return {};
}

/** Persist checklist items and post_analysis together in checklist JSONB. */
function packChecklistWithPost(
  items: ChecklistItem[] | null | undefined,
  postAnalysis: Record<string, unknown> | null | undefined,
  existingChecklistRaw: unknown,
): Record<string, unknown> | null {
  const existingItems = normalizeChecklist(existingChecklistRaw);
  const finalItems = items ?? existingItems;
  const existingPost = postAnalysisFromChecklistRaw(existingChecklistRaw);
  const post =
    postAnalysis != null
      ? { ...existingPost, ...postAnalysis }
      : Object.keys(existingPost).length > 0
        ? existingPost
        : null;
  if (finalItems.length === 0 && !post) return null;
  const out: Record<string, unknown> = {};
  if (finalItems.length > 0) out.items = finalItems;
  if (post) out.post_analysis = post;
  return out;
}

function normalizeChecklist(raw: unknown): ChecklistItem[] {
  const source = checklistItemsRaw(raw);
  const arr = Array.isArray(source) ? source : [];
  return arr
    .map((x) => {
      if (typeof x === "string")
        return { item: x.trim(), description: "", quantity: "", cost: "", status: "not done" as const };
      if (x && typeof x === "object") {
        const r = x as Record<string, unknown>;
        const st = String(r.status ?? "not done").trim().toLowerCase();
        const status: ChecklistItem["status"] = st === "completed" ? "completed" : "not done";
        return {
          item: String(r.item ?? "").trim(),
          description: String(r.description ?? "").trim(),
          quantity: String(r.quantity ?? "").trim(),
          cost: String(r.cost ?? "").trim(),
          status,
        };
      }
      return { item: "", description: "", quantity: "", cost: "", status: "not done" as const };
    })
    .filter((x) => x.item.length > 0);
}

async function generateChecklistFromMenu(menuRaw: unknown): Promise<ChecklistItem[]> {
  try {
    const menu = Array.isArray(menuRaw) ? menuRaw : [];
    const dishNames = menu
      .map((x) => {
        if (typeof x === "string") return x.trim();
        if (x && typeof x === "object") return String((x as Record<string, unknown>).name ?? "").trim();
        return "";
      })
      .filter((x) => x.length > 0);
    if (dishNames.length === 0) return [];
    const out: ChecklistItem[] = [];
    for (const dishName of dishNames) {
      let { rows } = await getPool().query(
        `SELECT ingredients FROM menu_dishes WHERE LOWER(TRIM(name)) = LOWER(TRIM($1)) LIMIT 1`,
        [dishName],
      );
      if (!rows.length) {
        ({ rows } = await getPool().query(
          `SELECT ingredients FROM menu_dishes
           WHERE LENGTH(TRIM($1::text)) > 2 AND LOWER(TRIM(name)) LIKE '%' || LOWER(TRIM($1::text)) || '%'
           ORDER BY LENGTH(name) ASC
           LIMIT 1`,
          [dishName],
        ));
      }
      const ingredients = parseJsonTextArray((rows[0] as Record<string, unknown> | undefined)?.ingredients);
      for (const ing of ingredients) {
        const cleaned = ing.trim();
        if (!cleaned) continue;
        out.push({
          item: cleaned,
          description: dishName,
          quantity: "",
          cost: "",
          status: "not done",
        });
      }
    }
    return out;
  } catch (err) {
    console.error("[checklist] generateChecklistFromMenu skipped:", err);
    return [];
  }
}

function additionalCostsDbColumnForStatus(status: string): "inquiry_additional_costs" | "stage_additional_costs" {
  const s = String(status ?? "").trim().toLowerCase();
  if (s === "new_event" || s === "online_inquiries") return "inquiry_additional_costs";
  return "stage_additional_costs";
}

/** Catering rows no longer store `theme_design`; merge API-facing theme fields from columns + post_analysis. */
function enrichCateringThemeDesignForApi(row: Record<string, unknown>): void {
  if (String(row.order_kind ?? "").trim().toLowerCase() !== "catering") return;
  const post =
    row.post_analysis && typeof row.post_analysis === "object" && !Array.isArray(row.post_analysis)
      ? (row.post_analysis as Record<string, unknown>)
      : {};
  const rawTd = row.theme_design;
  const td =
    rawTd && typeof rawTd === "object" && !Array.isArray(rawTd) && Object.keys(rawTd as object).length > 0
      ? (rawTd as Record<string, unknown>)
      : {};
  const guestRaw = td.guest_allergens ?? post.guest_allergens;
  const guestAllergens = Array.isArray(guestRaw)
    ? guestRaw.map((x) => String(x).trim()).filter((x) => x.length > 0)
    : [];
  const genUrl = String(
    td.generatedImageUrl ?? td.imageUrl ?? post.generatedImageUrl ?? post.generated_image_url ?? "",
  ).trim();
  row.theme_design = {
    ...td,
    event_setting: String(row.event_setting ?? td.event_setting ?? "").trim() || String(td.event_setting ?? ""),
    formality_level:
      String(row.formality_level ?? td.formality_level ?? "").trim() || String(td.formality_level ?? ""),
    service_included: String(row.service_included ?? td.service_included ?? "").trim(),
    ...(guestAllergens.length > 0 ? { guest_allergens: guestAllergens } : {}),
    ...(genUrl.length > 0 ? { generatedImageUrl: genUrl } : {}),
    ...(String(td.note ?? post.note ?? "").trim()
      ? { note: String(td.note ?? post.note ?? "").trim() }
      : {}),
  };
}

function mergeThemeDesignIntoPostAnalysis(
  postAnalysis: Record<string, unknown> | null,
  themeDesign: unknown,
): Record<string, unknown> | null {
  if (themeDesign == null || typeof themeDesign !== "object" || Array.isArray(themeDesign)) {
    return postAnalysis;
  }
  const td = themeDesign as Record<string, unknown>;
  const base = postAnalysis != null ? { ...postAnalysis } : {};
  if (Array.isArray(td.guest_allergens)) {
    base.guest_allergens = td.guest_allergens;
  }
  const gen = String(td.generatedImageUrl ?? td.imageUrl ?? "").trim();
  if (gen) base.generatedImageUrl = gen;
  const note = String(td.note ?? td.customInstructions ?? "").trim();
  if (note) base.note = note;
  return base;
}

function defaultTaskAssignmentRows(): TaskAssignmentRow[] {
  return Array.from({ length: 5 }).map(() => ({
    employee: "",
    tasks: "",
    schedule_of_tasks: "",
    budget: "",
    status: "not done",
  }));
}

/** Idempotency key for mobile / POS loyalty rows in `restaurant_orders.payment_reference`. */
const MOBILE_LOYALTY_PAYMENT_PREFIX = "curatering-mobile:";
const RESTAURANT_LOYALTY_STEP_AMOUNT = 100;
const RESTAURANT_LOYALTY_STEP_POINTS = 2;
const CATERING_LOYALTY_STEP_AMOUNT = 500;
const CATERING_LOYALTY_STEP_POINTS = 8;
const CATERING_ONLY_MIN_GUESTS = 10;
const CATERING_EVENT_MIN_GUESTS = 50;

/** Extra add-on units beyond the first cost this much each (per main dish qty). */
const RESTAURANT_ADDON_EXTRA_PHP = 15;

type ParsedRestaurantLine = {
  item_name: string;
  dip: string;
  dip_qty: number;
  qty: number;
  price: number;
};

function parseRestaurantOrderLine(i: unknown): ParsedRestaurantLine | null {
  if (!i || typeof i !== "object") return null;
  const r = i as Record<string, unknown>;
  let dip = String(r.dip ?? "").trim();
  if (dip.toLowerCase() === "none") dip = "";
  const item_name = String(r.item_name ?? "").trim();
  const qty = Number(r.qty ?? 0);
  const price = Number(r.price ?? 0);
  let dip_qty = Math.floor(Number(r.dip_qty ?? 1));
  if (!Number.isFinite(dip_qty) || dip_qty < 0) dip_qty = 0;
  if (!dip) dip_qty = 1;
  if (!item_name || qty <= 0 || price < 0) return null;
  return { item_name, dip, dip_qty, qty, price };
}

function restaurantLineSubtotal(line: ParsedRestaurantLine): number {
  const hasDip = line.dip.length > 0;
  const extra = hasDip ? Math.max(0, line.dip_qty - 1) * RESTAURANT_ADDON_EXTRA_PHP * line.qty : 0;
  return Math.round((line.qty * line.price + extra) * 100) / 100;
}

type LoyaltyEarnKind = "restaurant_mobile" | "catering_event";

function loyaltyPointsFor(kind: LoyaltyEarnKind, totalAmount: number): number {
  if (!Number.isFinite(totalAmount) || totalAmount <= 0) return 0;
  if (kind === "catering_event") {
    return Math.floor(totalAmount / CATERING_LOYALTY_STEP_AMOUNT) * CATERING_LOYALTY_STEP_POINTS;
  }
  return Math.floor(totalAmount / RESTAURANT_LOYALTY_STEP_AMOUNT) * RESTAURANT_LOYALTY_STEP_POINTS;
}

async function refreshLoyaltyTotalsForUser(userEmailRaw: string): Promise<void> {
  const email = userEmailRaw.trim().toLowerCase();
  if (!email || email.endsWith("@guest.curatering.internal")) return;
  const pool = getPool();
  const roMatch = await restaurantOrderMatchesEmailWhere(pool, "ro", "$1");
  const subFrom = `(
     SELECT
       COALESCE((
         SELECT SUM(COALESCE(ro.loyalty_points_restaurant_obtained, 0))::int
         FROM restaurant_orders ro
         WHERE ${roMatch}
           AND COALESCE(ro.delivery_notes, '') NOT LIKE '%Catering event loyalty%'
       ), 0) AS r,
       (
         COALESCE((
           SELECT SUM(COALESCE(loyalty_points_catering_obtained, 0))::int
           FROM event_orders
           WHERE LOWER(TRIM(email_address)) = $1
             AND LOWER(TRIM(status)) IN ('for_full_payment', 'completed')
         ), 0)
         + COALESCE((
           SELECT SUM(COALESCE(loyalty_points_catering_obtained, 0))::int
           FROM catering_orders
           WHERE LOWER(TRIM(email_address)) = $1
             AND LOWER(TRIM(status)) IN ('for_full_payment', 'completed')
         ), 0)
       )::int AS c
   )`;
  try {
    await getPool().query(
      `UPDATE customer_accounts ca
       SET restaurant_loyalty_points = sub.r,
           catering_loyalty_points = sub.c,
           ${CUSTOMER_ACCOUNT_TOUCH}
       FROM ${subFrom} sub
       WHERE LOWER(ca.email) = $1`,
      [email],
    );
  } catch (e) {
    console.warn("[loyalty] refresh totals for user failed:", e instanceof Error ? e.message : e);
  }
}

async function recomputeHistoricalLoyaltyPoints(): Promise<void> {
  try {
    await getPool().query(
      `UPDATE restaurant_orders
       SET loyalty_points_restaurant_obtained = CASE
         WHEN COALESCE(delivery_notes, '') LIKE '%Catering event loyalty%' THEN
           FLOOR(COALESCE(total_cost, 0)::numeric / $1::numeric)::int * $2::int
         ELSE
           FLOOR(COALESCE(total_cost, 0)::numeric / $3::numeric)::int * $4::int
       END`,
      [
        CATERING_LOYALTY_STEP_AMOUNT,
        CATERING_LOYALTY_STEP_POINTS,
        RESTAURANT_LOYALTY_STEP_AMOUNT,
        RESTAURANT_LOYALTY_STEP_POINTS,
      ],
    );
    await getPool().query(
      `UPDATE event_orders
       SET loyalty_points_catering_obtained = CASE
         WHEN LOWER(TRIM(status)) IN ('for_full_payment', 'completed')
           THEN FLOOR(COALESCE(total_cost, 0)::numeric / $1::numeric)::int * $2::int
         ELSE 0
       END`,
      [CATERING_LOYALTY_STEP_AMOUNT, CATERING_LOYALTY_STEP_POINTS],
    );
    await getPool().query(
      `UPDATE catering_orders
       SET loyalty_points_catering_obtained = CASE
         WHEN LOWER(TRIM(status)) IN ('for_full_payment', 'completed')
           THEN FLOOR(COALESCE(total_cost, 0)::numeric / $1::numeric)::int * $2::int
         ELSE 0
       END`,
      [CATERING_LOYALTY_STEP_AMOUNT, CATERING_LOYALTY_STEP_POINTS],
    );

    await getPool().query(
      `WITH agg AS (
         SELECT email_key,
                SUM(rp)::int AS restaurant_points,
                SUM(cp)::int AS catering_points
         FROM (
           SELECT LOWER(TRIM(COALESCE(ca.email, ro.user_email, ''))) AS email_key,
                  CASE
                    WHEN COALESCE(ro.delivery_notes, '') NOT LIKE '%Catering event loyalty%'
                      THEN COALESCE(ro.loyalty_points_restaurant_obtained, 0)
                    ELSE 0
                  END AS rp,
                  0::int AS cp
           FROM restaurant_orders ro
           LEFT JOIN customer_accounts ca ON (
             ca.customer_id = ro.customer_id::text
             OR LOWER(TRIM(ca.email)) = LOWER(TRIM(COALESCE(ro.user_email, '')))
           )
           WHERE NULLIF(LOWER(TRIM(COALESCE(ca.email, ro.user_email, ''))), '') IS NOT NULL
           UNION ALL
           SELECT LOWER(TRIM(email_address)) AS email_key,
                  0 AS rp,
                  COALESCE(loyalty_points_catering_obtained, 0) AS cp
           FROM event_orders
           WHERE LOWER(TRIM(status)) IN ('for_full_payment', 'completed')
             AND NULLIF(LOWER(TRIM(email_address)), '') IS NOT NULL
           UNION ALL
           SELECT LOWER(TRIM(email_address)) AS email_key,
                  0 AS rp,
                  COALESCE(loyalty_points_catering_obtained, 0) AS cp
           FROM catering_orders
           WHERE LOWER(TRIM(status)) IN ('for_full_payment', 'completed')
             AND NULLIF(LOWER(TRIM(email_address)), '') IS NOT NULL
         ) t
         WHERE email_key <> ''
         GROUP BY email_key
       )
       UPDATE customer_accounts ca
       SET restaurant_loyalty_points = COALESCE(agg.restaurant_points, 0),
           catering_loyalty_points = COALESCE(agg.catering_points, 0),
           ${CUSTOMER_ACCOUNT_TOUCH}
       FROM agg
       WHERE LOWER(ca.email) = agg.email_key`,
    );
  } catch (e) {
    console.warn("[db] loyalty recompute skipped:", e instanceof Error ? e.message : e);
  }
}

async function applyLoyaltyRewardsBestEffort(
  userEmail: string,
  orderNo: string,
  totalAmount: number,
  kind: LoyaltyEarnKind = "restaurant_mobile",
) {
  const pointsEarned = loyaltyPointsFor(kind, totalAmount);
  if (!userEmail || pointsEarned <= 0) return;
  const email = userEmail.trim().toLowerCase();
  if (email.endsWith("@guest.curatering.internal")) {
    return;
  }
  const paymentRef = `${MOBILE_LOYALTY_PAYMENT_PREFIX}${orderNo}`;
  try {
    const dup = await getPool().query(
      `SELECT 1 FROM restaurant_orders WHERE payment_reference_initial = $1 LIMIT 1`,
      [paymentRef],
    );
    if (dup.rowCount && dup.rowCount > 0) {
      return;
    }

    const customerId = await customerBusinessIdForEmail(email);
    if (!customerId) return;

    const deliveryNotes =
      kind === "catering_event" ? `Catering event loyalty · ${email}` : `Mobile app loyalty · ${email}`;

    const pool = getPool();
    const roMatch = await restaurantOrderMatchesEmailWhere(pool, "", "$1");
    await pool.query(
      `UPDATE restaurant_orders
       SET loyalty_points_restaurant_obtained = GREATEST(COALESCE(loyalty_points_restaurant_obtained, 0), $3)
       WHERE ${roMatch}
         AND COALESCE(order_source, 'MOBILE_APP') NOT IN ('POS', 'LOYALTY_SYNC')
         AND (
           NULLIF(TRIM(order_id), '') = $2
           OR 'ORD-' || LPAD(mobile_id::text, 6, '0') = $2
         )`,
      [email, orderNo, pointsEarned],
    );

    const hasRoUserEmail = await columnExists(pool, "restaurant_orders", "user_email");
    if (hasRoUserEmail) {
      await pool.query(
        `INSERT INTO restaurant_orders (
           user_email, customer_id, tray_items, total_cost, delivery_notes,
           order_status, payment_reference_initial, payment_confirmed_initial,
           loyalty_points_restaurant_obtained, order_source
         )
         VALUES ($1, $2, '[]'::jsonb, $3, $4, 'DELIVERED', $5, TRUE, $6, 'LOYALTY_SYNC')`,
        [email, customerId, totalAmount, deliveryNotes, paymentRef, pointsEarned],
      );
    } else {
      await pool.query(
        `INSERT INTO restaurant_orders (
           customer_id, tray_items, total_cost, delivery_notes,
           order_status, payment_reference_initial, payment_confirmed_initial,
           loyalty_points_restaurant_obtained, order_source
         )
         VALUES ($1, '[]'::jsonb, $2, $3, 'DELIVERED', $4, TRUE, $5, 'LOYALTY_SYNC')`,
        [customerId, totalAmount, deliveryNotes, paymentRef, pointsEarned],
      );
    }

    if (kind === "catering_event") {
      await getPool().query(
        `UPDATE customer_accounts
         SET catering_loyalty_points = COALESCE(catering_loyalty_points, 0) + $2,
             ${CUSTOMER_ACCOUNT_TOUCH}
         WHERE LOWER(TRIM(email)) = LOWER($1)`,
        [email, pointsEarned],
      );
    } else {
      await getPool().query(
        `UPDATE customer_accounts
         SET restaurant_loyalty_points = COALESCE(restaurant_loyalty_points, 0) + $2,
             ${CUSTOMER_ACCOUNT_TOUCH}
         WHERE LOWER(TRIM(email)) = LOWER($1)`,
        [email, pointsEarned],
      );
    }
    await logActionBestEffort(
      "loyalty.points.earned",
      email,
      `Earned +${pointsEarned} points from order ${orderNo}`,
      { order_no: orderNo, points_delta: pointsEarned, total_amount: totalAmount },
    );
  } catch (err) {
    console.warn("Loyalty reward sync skipped:", err instanceof Error ? err.message : err);
  }
}

async function backfillLoyaltyForConfirmedMobileOrders(): Promise<void> {
  try {
    const pool = getPool();
    const moEmail = await restaurantOrderEmailExpr(pool, "mo");
    const { rows } = await pool.query(
      `SELECT COALESCE(mo.order_id, 'ORD-' || LPAD(mo.mobile_id::text, 6, '0')) AS order_no,
              ${moEmail} AS user_email, mo.total_cost::float AS total
       FROM restaurant_orders mo
       WHERE ${moEmail} <> ''
         AND mo.order_source = 'MOBILE_APP'
         AND (upper(COALESCE(mo.order_status, '')) LIKE '%ORDER CONFIRMED%'
              OR upper(COALESCE(mo.order_status, '')) LIKE '%OVERPAYMENT%')
         AND NOT EXISTS (
           SELECT 1 FROM restaurant_orders ro
           WHERE ro.payment_reference_initial = $1 || COALESCE(mo.order_id, 'ORD-' || LPAD(mo.mobile_id::text, 6, '0'))
         )`,
      [MOBILE_LOYALTY_PAYMENT_PREFIX],
    );
    for (const r of rows as Array<{ order_no: string; user_email: string; total: number }>) {
      if (!String(r.user_email ?? "").trim()) continue;
      await applyLoyaltyRewardsBestEffort(r.user_email, r.order_no, r.total);
    }
    if (rows.length) {
      console.log(`[db] loyalty backfill: credited ${rows.length} confirmed mobile order(s)`);
    }
  } catch (e) {
    console.warn("[db] loyalty backfill skipped:", e instanceof Error ? e.message : e);
  }
}

app.get("/health", (_req, res) => {
  res.json({ ok: true });
});

app.get("/api/items", async (_req, res) => {
  res.json([]);
});

app.post("/api/items", async (_req, res) => {
  res.status(410).json({ error: "items table removed; use restaurant_orders tray_items instead" });
});

app.get("/api/mobile/menu", async (_req, res) => {
  const customMenuSql = process.env.WEB_MENU_SQL?.trim() || "";
  if (!customMenuSql && process.env.DISABLE_DEFAULT_PUBLIC_MENU === "true") {
    res.status(503).json({
      error:
        "Menu query disabled or not configured. Remove DISABLE_DEFAULT_PUBLIC_MENU or set WEB_MENU_SQL / WEB_MENU_TABLE — see .env.example.",
    });
    return;
  }
  const mapMenuRows = (rows: Array<Record<string, unknown>>) =>
    rows.map((r) => ({
      id: String(r.id ?? ""),
      name: String(r.name ?? ""),
      description: String(r.description ?? ""),
      price: Number(r.price ?? 0),
      dips: parseJsonTextArray(r.dips),
      ingredients: parseJsonTextArray(r.ingredients),
      category: String(r.category ?? ""),
      dish_type: String(r.dish_type ?? ""),
      image_base64: r.image_base64 != null ? String(r.image_base64) : null,
      allergens: parseAllergenNamesFromRow(r),
    }));

  try {
    await ensureRestaurantOrdersApiSchemaOnce();
    const pool = getPool();
    let sql = customMenuSql;
    if (!sql) {
      try {
        sql = await buildMenuSql(pool);
      } catch (buildErr) {
        console.error("[menu] buildMenuSql failed", buildErr);
        sql = MINIMAL_PUBLIC_MENU_SQL;
      }
    }
    let rows: Array<Record<string, unknown>>;
    const runMenuQuery = async (querySql: string) => {
      const result = await pool.query(querySql);
      return result.rows as Array<Record<string, unknown>>;
    };
    try {
      rows = await runMenuQuery(sql);
    } catch (err) {
      const pgCode = (err as { code?: string })?.code;
      const canFallback = isPgUndefinedColumn(err) || pgCode === "42804";
      if (!canFallback) throw err;
      console.warn("[menu] primary query failed, trying safe menu SQL", err);
      try {
        rows = await runMenuQuery(await buildMenuSql(pool, { skipAllergens: true }));
      } catch (err2) {
        console.warn("[menu] safe buildMenuSql failed, using minimal menu SQL", err2);
        rows = await runMenuQuery(MINIMAL_PUBLIC_MENU_SQL);
      }
    }
    res.json(mapMenuRows(rows));
  } catch (err) {
    console.error(err);
    // Do not block app login/session — return empty menu so clients can still authenticate.
    res.json([]);
  }
});

app.get("/api/mobile/allergens", async (_req, res) => {
  try {
    res.json(await queryAllergensCatalog(getPool()));
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "could not load allergens" });
  }
});

app.get("/api/mobile/set-menus", async (_req, res) => {
  const customSetSql = process.env.WEB_SET_MENUS_SQL?.trim() || "";
  try {
    const pool = getPool();
    let sql = customSetSql || null;
    if (!sql) {
      try {
        sql = await buildSetMenusSql(pool);
      } catch (buildErr) {
        console.error("[set-menus] buildSetMenusSql failed", buildErr);
        sql = null;
      }
    }
    if (!sql) {
      res.json([]);
      return;
    }
    let rows: Array<Record<string, unknown>>;
    try {
      rows = (await pool.query(sql)).rows as Array<Record<string, unknown>>;
    } catch (err) {
      const canFallback = isPgUndefinedColumn(err) || (err as { code?: string })?.code === "42804";
      if (!canFallback || sql === DEFAULT_PUBLIC_SET_MENUS_SQL) throw err;
      console.warn("[set-menus] primary query failed, trying default public set menus SQL", err);
      rows = (await pool.query(DEFAULT_PUBLIC_SET_MENUS_SQL)).rows as Array<Record<string, unknown>>;
    }
    res.json(
      rows.map((r) => ({
        name: String(r.name ?? ""),
        description: String(r.description ?? ""),
        dishes: parseJsonTextArray(r.dishes),
      })),
    );
  } catch (err) {
    console.error(err);
    res.status(500).json({
      error: "set menu query failed — check set_menus / menu_dishes.set_menus schema",
    });
  }
});

app.post("/api/mobile/auth/signup/request-otp", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  if (!email || !email.includes("@")) {
    res.status(400).json({ error: "valid email is required" });
    return;
  }
  if (!isMailConfigured() && !mobileDevOtpLogging) {
    res.status(503).json({
      error:
        "SMTP not configured — set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD (or GMAIL_USER + GMAIL_APP_PASSWORD)",
    });
    return;
  }
  const code = normalizeOtpDigits(String(crypto.randomInt(100000, 1000000)));
  const expiresAt = new Date(Date.now() + otpExpiryMinutes * 60 * 1000);
  try {
    const existing = await getPool().query(
      "SELECT id, is_verified FROM customer_accounts WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))",
      [email],
    );
    const row0 = existing.rows[0] as { id: string; is_verified: boolean } | undefined;
    if (row0?.is_verified) {
      res.status(409).json({ error: "account already exists — log in instead" });
      return;
    }
    if (row0 && !row0.is_verified) {
      await getPool().query(
        "DELETE FROM customer_accounts WHERE LOWER(TRIM(email)) = LOWER(TRIM($1)) AND is_verified = FALSE",
        [email],
      );
    }
    const { rows: saved } = await getPool().query(
      `INSERT INTO customer_accounts (email, password_hash, full_name, is_verified, signup_otp_code, signup_otp_code_expiry, created_account_dt_stamp)
       VALUES ($1, '', '', FALSE, $2, $3::timestamptz, NOW())
       ON CONFLICT (email) DO UPDATE SET
         signup_otp_code = EXCLUDED.signup_otp_code,
         signup_otp_code_expiry = EXCLUDED.signup_otp_code_expiry,
         ${CUSTOMER_ACCOUNT_TOUCH}
       RETURNING signup_otp_code, signup_otp_code_expiry`,
      [email, code, expiresAt.toISOString()],
    );
    const savedRow = saved[0] as { signup_otp_code: string | null } | undefined;
    if (!savedRow?.signup_otp_code) {
      console.error("[auth] signup OTP not persisted for", email);
      res.status(500).json({ error: "could not store signup code" });
      return;
    }
    await logActionBestEffort("auth.signup.request_otp", email, "Signup OTP requested", {
      channel: "email",
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
    return;
  }
  if (mobileDevOtpLogging && !isMailConfigured()) {
    console.warn(`[MOBILE_DEV_OTP_LOGGING] signup OTP for ${email}: ${code} (expires in ${otpExpiryMinutes}m)`);
    res.json({ ok: true });
    return;
  }
  try {
    await sendMailRequired(
      email,
      "Your Curatering signup code",
      `Your one-time code is: ${code}\n\nIt expires in ${otpExpiryMinutes} minutes.`,
    );
  } catch (err) {
    console.error(err);
    res.status(503).json({
      error: err instanceof Error ? err.message : "failed to send OTP email",
    });
    return;
  }
  res.json({ ok: true });
});

app.post("/api/mobile/auth/signup/complete", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const otp = normalizeOtpDigits(req.body?.otp);
  const password = String(req.body?.password ?? "");
  if (!email || !otp || password.length < 8) {
    res.status(400).json({ error: "email, otp, and password (min 8 chars) are required" });
    return;
  }
  try {
    const taken = await getPool().query(
      "SELECT is_verified FROM customer_accounts WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))",
      [email],
    );
    const takenRow = taken.rows[0] as { is_verified: boolean } | undefined;
    if (takenRow?.is_verified) {
      res.status(409).json({ error: "account already exists — log in instead" });
      return;
    }
    const hash = await bcrypt.hash(password, 10);
    const cusId = await nextCustomerProfileRowId();
    const { rows: updated } = await getPool().query(
      `UPDATE customer_accounts
       SET password_hash = $2,
           is_verified = TRUE,
           customer_id = COALESCE(NULLIF(TRIM(customer_id), ''), $3),
           signup_otp_code = NULL,
           signup_otp_code_expiry = NULL,
           created_account_dt_stamp = COALESCE(created_account_dt_stamp, NOW()),
           updated_pw_dt_stamp = NOW()
       WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))
         AND ${sqlOtpMatches("signup_otp_code", "$4")}
         AND signup_otp_code_expiry > NOW()
       RETURNING email, customer_id`,
      [email, hash, cusId, otp],
    );
    if (!updated.length) {
      res.status(400).json({ error: "invalid or expired code" });
      return;
    }
    await logActionBestEffort("auth.signup.complete", email, "Customer account created", {});
    const ts = new Date().toISOString();
    void sendMailSafe(email, "Welcome to Curatering", `Your account ${email} was created at ${ts}.`).catch((mailErr) => {
      console.warn("[mail] welcome email failed (signup still succeeded):", mailErr);
    });
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

/** Validates signup OTP before showing password fields (does not consume the OTP). */
app.post("/api/mobile/auth/signup/check-otp", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const otp = normalizeOtpDigits(req.body?.otp);
  if (!email || !otp) {
    res.status(400).json({ error: "email and otp are required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT 1 AS ok FROM customer_accounts
       WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))
         AND ${sqlOtpMatches("signup_otp_code", "$2")}
         AND signup_otp_code_expiry > NOW()
         AND COALESCE(is_verified, FALSE) = FALSE
       LIMIT 1`,
      [email, otp],
    );
    if (!rows.length) {
      res.status(400).json({ error: "invalid or expired code" });
      return;
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/auth/login", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const password = String(req.body?.password ?? "");
  if (!email || !password) {
    res.status(400).json({ error: "email and password are required" });
    return;
  }
  try {
    const cashierFirst = await getPool().query(
      "SELECT password_hash, role, pos_role, COALESCE(NULLIF(TRIM(full_name), ''), '') AS display_name FROM users WHERE email = $1",
      [email],
    );
    const cRow = cashierFirst.rows[0] as {
      password_hash: string;
      role: string;
      pos_role: string;
      display_name: string;
    } | undefined;
    if (cRow) {
      if (!(await bcrypt.compare(password, cRow.password_hash))) {
        res.status(401).json({ error: "invalid email or password" });
        return;
      }
      const posRole = resolveStaffPosRole({
        role: String(cRow.role ?? ""),
        pos_role: String(cRow.pos_role ?? ""),
      });
      const role = posRole ?? "customer";
      let displayName = String(cRow.display_name ?? "").trim();
      if (!displayName && posRole === "manager") {
        displayName = "Manager";
      }
      await logActionBestEffort("auth.login", email, "Staff login successful", { role });
      const tsStaff = new Date().toISOString();
      void sendMailSafe(
        email,
        "Macrina's Kitchen login notice",
        `A cashier/staff login was completed for ${email} at ${tsStaff}. If this was not you, change your password immediately.`,
      ).catch((mailErr) => {
        console.warn("[mail] staff login notice email failed (login still succeeds):", mailErr);
      });
      res.json({ ok: true, email, role, display_name: displayName });
      return;
    }
    const { rows } = await getPool().query(
      "SELECT password_hash, full_name, is_verified FROM customer_accounts WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))",
      [email],
    );
    let row = rows[0] as { password_hash: string; full_name: string; is_verified: boolean } | undefined;
    if (!row) {
      res.status(401).json({ error: "invalid email or password" });
      return;
    }
    const hash = row?.password_hash ?? "";
    if (!hash || !(await bcrypt.compare(password, hash))) {
      res.status(401).json({ error: "invalid email or password" });
      return;
    }
    const cusId = await customerBusinessIdForEmail(email);
    if (!cusId) {
      try {
        const newCusId = await nextCustomerProfileRowId();
        await getPool().query(
          `UPDATE customer_accounts
           SET customer_id = $2
           WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))
             AND (customer_id IS NULL OR TRIM(customer_id::text) = '')`,
          [email, newCusId],
        );
      } catch (assignErr) {
        console.warn("[auth] customer_id assignment failed (login still succeeds):", assignErr);
      }
    }
    const ts = new Date().toISOString();
    try {
      await sendMailSafe(
        email,
        "Macrina's Kitchen login notice",
        `A login was completed for ${email} at ${ts}. If this was not you, change your password.`,
      );
    } catch (mailErr) {
      console.warn("[mail] login notice email failed (login still succeeds):", mailErr);
    }
    const role = "customer";
    const displayName = String(row?.full_name ?? "").trim();
    await logActionBestEffort("auth.login", email, "Customer login successful", { role: "customer" });
    res.json({ ok: true, email, role, display_name: displayName });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/auth/request-password-reset", async (req, res) => {
  const identity = String(req.body?.identity ?? req.body?.email ?? "").trim().toLowerCase();
  const role = String(req.body?.role ?? "customer").trim().toLowerCase();
  if (!identity) {
    res.status(400).json({ error: "email is required" });
    return;
  }
  if (!identity.includes("@")) {
    res.status(400).json({ error: "enter a valid email address" });
    return;
  }
  if (!isMailConfigured() && !mobileDevOtpLogging) {
    res.status(503).json({
      error:
        "SMTP not configured — set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD (or GMAIL_USER + GMAIL_APP_PASSWORD)",
    });
    return;
  }
  const otp = normalizeOtpDigits(String(crypto.randomInt(100000, 1000000)));
  const expiresAt = new Date(Date.now() + 60 * 60 * 1000);
  let targetEmail = "";
  try {
    if (role === "cashier") {
      const { rows } = await getPool().query(`SELECT email FROM users WHERE LOWER(email) = $1 LIMIT 1`, [identity]);
      const row = rows[0] as { email: string } | undefined;
      if (!row) {
        res.json({ ok: true });
        return;
      }
      targetEmail = row.email;
      await getPool().query(
        `UPDATE users SET password_reset_otp = $2, password_reset_expires_at = $3 WHERE email = $1`,
        [targetEmail, otp, expiresAt.toISOString()],
      );
    } else {
      const { rows } = await getPool().query(`SELECT email FROM customer_accounts WHERE LOWER(email) = $1 LIMIT 1`, [
        identity,
      ]);
      const account = rows[0] as { email: string } | undefined;
      if (!account) {
        res.status(404).json({
          error: "not_registered",
          message: "This email is not registered.",
        });
        return;
      }
      targetEmail = account.email;
      const pool = getPool();
      await pool.query(
        `ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS forgot_password_otp_code TEXT`,
      );
      await pool.query(
        `ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS forgot_password_otp_code_expiry TIMESTAMPTZ`,
      );
      await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS password_reset_otp TEXT`);
      await pool.query(
        `ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS password_reset_expires_at TIMESTAMPTZ`,
      );
      const otpSet = await buildCustomerForgotOtpUpdateSet(pool);
      const { rowCount } = await pool.query(
        `UPDATE customer_accounts SET ${otpSet} WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))`,
        [targetEmail, otp, expiresAt],
      );
      if (!rowCount) {
        res.status(500).json({ error: "could not store reset code" });
        return;
      }
    }
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
    return;
  }
  const otpBody = `Your password reset OTP is: ${otp}\n\nIt is valid for 1 hour.`;
  if (mobileDevOtpLogging && !isMailConfigured()) {
    console.warn(`[MOBILE_DEV_OTP_LOGGING] password reset OTP for ${targetEmail} (role=${role}): ${otp}`);
  } else {
    try {
      await sendMailRequired(targetEmail, "Reset your Curatering password", otpBody);
    } catch (err) {
      console.error(err);
      res.status(503).json({
        error: err instanceof Error ? err.message : "failed to send reset email",
      });
      return;
    }
  }
  try {
    await logActionBestEffort(
      "auth.reset.request",
      targetEmail,
      "Password reset requested",
      { channel: "email", role },
    );
  } catch (logErr) {
    console.warn("[auth] password reset logging failed (non-fatal):", logErr);
  }
  res.json({ ok: true });
});

/** Validates OTP before showing the new-password step (does not consume the OTP). */
app.post("/api/mobile/auth/check-password-reset-otp", async (req, res) => {
  const identity = String(req.body?.identity ?? req.body?.email ?? "").trim().toLowerCase();
  const otp = normalizeOtpDigits(req.body?.otp);
  const role = String(req.body?.role ?? "customer").trim().toLowerCase();
  if (!identity || !otp) {
    res.status(400).json({ error: "identity and otp are required" });
    return;
  }
  try {
    if (role === "cashier") {
      const { rows } = await getPool().query(
        `SELECT email FROM users
         WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))
           AND ${sqlOtpMatches("password_reset_otp", "$2")}
           AND password_reset_expires_at > NOW()
         LIMIT 1`,
        [identity, otp],
      );
      if (!rows.length) {
        res.status(400).json({ error: "invalid or expired reset OTP" });
        return;
      }
    } else {
      const account = await resolveCustomerAccountByIdentity(identity);
      if (!account) {
        res.status(400).json({ error: "invalid or expired reset OTP" });
        return;
      }
      const pool = getPool();
      const otpValidWhere = await buildCustomerForgotOtpValidWhere(pool, "$2");
      const { rows } = await pool.query(
        `SELECT 1 AS ok FROM customer_accounts
         WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))
           AND ${otpValidWhere}
         LIMIT 1`,
        [account.email, otp],
      );
      if (!rows.length) {
        res.status(400).json({ error: "invalid or expired reset OTP" });
        return;
      }
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/auth/reset-password", async (req, res) => {
  const identity = String(req.body?.identity ?? req.body?.email ?? "").trim().toLowerCase();
  const otp = normalizeOtpDigits(req.body?.otp ?? req.body?.token);
  const role = String(req.body?.role ?? "customer").trim().toLowerCase();
  const password = String(req.body?.password ?? "");
  if (!identity || !otp || password.length < 8) {
    res.status(400).json({ error: "identity, otp, and password (min 8 chars) are required" });
    return;
  }
  try {
    const hash = await bcrypt.hash(password, 10);
    let email = "";
    if (role === "cashier") {
      const { rows: staffOtpRows } = await getPool().query(
        `SELECT email FROM users
         WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))
           AND ${sqlOtpMatches("password_reset_otp", "$2")}
           AND password_reset_expires_at > NOW()
         LIMIT 1`,
        [identity, otp],
      );
      const sr = staffOtpRows[0] as { email: string } | undefined;
      if (!sr) {
        res.status(400).json({ error: "invalid or expired reset OTP" });
        return;
      }
      email = sr.email;
      await getPool().query(
        `UPDATE users
         SET password_hash = $2, password_reset_otp = NULL, password_reset_expires_at = NULL
         WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))`,
        [email, hash],
      );
    } else {
      const account = await resolveCustomerAccountByIdentity(identity);
      if (!account) {
        res.status(400).json({ error: "invalid or expired reset OTP" });
        return;
      }
      email = account.email;
      const pool = getPool();
      const otpClearSet = await buildCustomerForgotOtpClearSet(pool);
      const otpValidWhere = await buildCustomerForgotOtpValidWhere(pool, "$3");
      const { rows: updated } = await pool.query(
        `UPDATE customer_accounts
         SET password_hash = $2,
             ${otpClearSet}
         WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))
           AND ${otpValidWhere}
         RETURNING email`,
        [email, hash, otp],
      );
      if (!updated.length) {
        res.status(400).json({ error: "invalid or expired reset OTP" });
        return;
      }
    }
    await logActionBestEffort("auth.reset.complete", email, "Password reset completed", {});
    const ts = new Date().toISOString();
    const resetSubject =
      role === "cashier" ? "Your Macrina's Kitchen cashier password was reset" : "Your Curatering password was reset";
    const resetBody =
      role === "cashier"
        ? `The cashier account password for ${email} was successfully reset at ${ts}.\n\nIf you did not make this change, contact your administrator immediately.`
        : `The password for ${email} was successfully reset at ${ts}.\n\nIf you did not make this change, contact support immediately.`;
    void sendMailSafe(email, resetSubject, resetBody);
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

type PosStaffRole = "cashier" | "manager" | "supervisor";

function mapDbRoleToPosRole(dbRole: string): PosStaffRole | null {
  const r = String(dbRole ?? "").trim().toLowerCase();
  if (r === "manager") return "manager";
  if (r === "supervisor") return "supervisor";
  if (r === "cashier") return "cashier";
  // Admin/super_admin are web platform roles and should not auto-map to cashier POS.
  return null;
}

/** Prefer explicit `pos_role` when set; otherwise derive from `role`. */
function resolveStaffPosRole(row: { role: string; pos_role: string }): PosStaffRole | null {
  const pr = String(row.pos_role ?? "").trim().toLowerCase();
  if (pr === "cashier" || pr === "manager" || pr === "supervisor") {
    return pr;
  }
  return mapDbRoleToPosRole(String(row.role ?? ""));
}

async function verifyPosStaff(
  email: string,
  password: string,
  allowedRoles: PosStaffRole[] = ["cashier", "manager", "supervisor"],
): Promise<{ ok: boolean; role: PosStaffRole | null }> {
  const e = email.trim().toLowerCase();
  const { rows } = await getPool().query(`SELECT password_hash, role, pos_role FROM users WHERE email = $1`, [e]);
  const row = rows[0] as { password_hash: string; role: string; pos_role: string } | undefined;
  if (!row) return { ok: false, role: null };
  const role = resolveStaffPosRole(row);
  if (!role || !allowedRoles.includes(role)) return { ok: false, role: null };
  const ok = await bcrypt.compare(password, row.password_hash);
  return { ok, role: ok ? role : null };
}

/** All mobile-app customer orders for cashier review (not walk-in POS). */
app.post("/api/mobile/pos/online-orders/list", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (!cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  try {
    await ensureCashierPosSchemaOnce();
    const pool = getPool();
    const roSelect = await getRestaurantOrderSelectSql(pool);
    const roOrderBy = `ORDER BY ${await getRestaurantOrderCreatedAtSql(pool, "mo")} DESC`;
    const moEmail = await restaurantOrderEmailExpr(pool, "mo");
    const { rows } = await pool.query(
      `SELECT ${roSelect},
              COALESCE(NULLIF(TRIM(mo.full_name), ''), NULLIF(${moEmail}, ''), mo.guest_contact_email) AS customer_display_name,
              ${await restaurantLoyaltyEarnedSqlAsync(pool, RESTAURANT_LOYALTY_STEP_AMOUNT, RESTAURANT_LOYALTY_STEP_POINTS, "mo")}
       FROM restaurant_orders mo
       WHERE ${await getCashierOnlineOrderWhereSql(pool)}
       ${roOrderBy}`,
    );
    const out = await attachOrderItems(rows as Array<Record<string, unknown>>);
    res.json(out);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/pos/online-orders/:id/review", async (req, res) => {
  const id = Number(req.params.id);
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const action = String(req.body?.action ?? "").trim().toLowerCase();
  const amountReceived = Number(req.body?.amount_received ?? NaN);
  const supplementalAmtIn = Number(req.body?.supplemental_amount_received ?? NaN);
  if (!id || !cashierEmail || !cashierPassword || !action) {
    res.status(400).json({ error: "id, cashier credentials, and action are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  if (!["confirm", "insufficient", "overpayment"].includes(action)) {
    res.status(400).json({ error: "action must be confirm, insufficient, or overpayment" });
    return;
  }
  try {
    await ensureCashierPosSchemaOnce();
    const { rows: orows } = await getPool().query(
      `SELECT ${RESTAURANT_ORDER_PATCH_SELECT}
       FROM restaurant_orders WHERE mobile_id = $1`,
      [id],
    );
    type OrdRow = {
      id: number;
      user_email: string | null;
      order_no: string;
      status: string;
      total: string;
      order_source: string;
      cashier_amount_received: string | null;
      supplemental_payment_proof: string | null;
      payment_reference_balance: string | null;
      payment_reference_initial: string | null;
      balance_proof_pending_review: boolean;
      guest_contact_email: string | null;
      delivery_contact: string | null;
    };
    const ord = orows[0] as OrdRow | undefined;
    if (!ord || !isCashierOnlineRestaurantOrder(ord)) {
      res.status(404).json({ error: "online order not found" });
      return;
    }
    const total = Number(ord.total);
    let newStatus = ord.status;
    let mailSubject = "";
    let mailBody = "";
    let cashReceived: number | null = null;
    let changeAmt: number | null = null;

    if (action === "confirm") {
      const proof2 =
        (ord.supplemental_payment_proof != null && String(ord.supplemental_payment_proof).trim().length > 0) ||
        String((ord as { payment_reference_balance?: string }).payment_reference_balance ?? "").trim().length > 0;
      const bpr = ord.balance_proof_pending_review as unknown;
      const pendingReview =
        bpr === true ||
        bpr === 1 ||
        String(bpr ?? "")
          .trim()
          .toLowerCase() === "t";
      const statusUp = String(ord.status).toUpperCase();
      const awaitingBalanceConfirm =
        statusUp.includes("WAITING FOR BALANCE") || statusUp.includes("BALANCE PAYMENT CONFIRMATION");

      if (proof2 && (pendingReview || awaitingBalanceConfirm)) {
        if (!Number.isFinite(supplementalAmtIn) || supplementalAmtIn < 0) {
          res.status(400).json({ error: "supplemental_amount_received is required (balance payment amount)" });
          return;
        }
        const first = Number(ord.cashier_amount_received) || 0;
        const combined = first + supplementalAmtIn;
        if (combined + 1e-9 < total) {
          res.status(400).json({
            error: `Recorded payments are still below the order total (need at least ₱${(total - first).toFixed(2)} more).`,
          });
          return;
        }
        newStatus = "ORDER CONFIRMED";
        mailSubject = `Order ${ord.order_no} confirmed`;
        mailBody = `Good news — your order ${ord.order_no} has been confirmed.\nTotal: ₱${total.toFixed(2)}\nThank you for choosing Macrina's Kitchen and Catering.`;
        changeAmt = Math.round((combined - total) * 100) / 100;

        await getPool().query(
          `UPDATE restaurant_orders
           SET order_status = $2,
               cashier_amount_received_balance = $3,
               payment_confirmed_balance = TRUE,
               amount_paid = $4,
               change_given = $5,
               ${RESTAURANT_ORDER_TOUCH_SET}
           WHERE mobile_id = $1`,
          [id, newStatus, supplementalAmtIn, combined, changeAmt],
        );

        await notifyRestaurantOrderCustomer(guestReachFromRow(ord), mailSubject, mailBody, {
          orderNo: ord.order_no,
          inAppMessage: `[${ord.order_no}] Order confirmed. Total: ₱${total.toFixed(2)}`,
        });
        if (!isGuestUserEmail(String(ord.user_email ?? ""))) {
          await applyLoyaltyRewardsBestEffort(String(ord.user_email), ord.order_no, total, "restaurant_mobile");
        }
        res.json({ ok: true, status: newStatus });
        return;
      }

      if (statusUp.includes("INSUFFICIENT") && !proof2) {
        res.status(400).json({
          error: "Customer must provide balance payment proof or reference before you can confirm.",
        });
        return;
      }

      newStatus = "ORDER CONFIRMED";
      mailSubject = `Order ${ord.order_no} confirmed`;
      mailBody = `Good news — your order ${ord.order_no} has been confirmed.\nTotal: ₱${total.toFixed(2)}\nThank you for choosing Macrina's Kitchen and Catering.`;
      if (!Number.isNaN(amountReceived) && amountReceived >= 0) {
        cashReceived = amountReceived;
        changeAmt = Math.round((amountReceived - total) * 100) / 100;
      }
    } else if (action === "insufficient") {
      const proof2Bal =
        (ord.supplemental_payment_proof != null && String(ord.supplemental_payment_proof).trim().length > 0) ||
        String(ord.payment_reference_balance ?? "").trim().length > 0;
      const statusUpBal = String(ord.status).toUpperCase();
      const awaitingBalanceConfirmBal =
        statusUpBal.includes("WAITING FOR BALANCE") || statusUpBal.includes("BALANCE PAYMENT CONFIRMATION");
      const bprBal = ord.balance_proof_pending_review as unknown;
      const pendingReviewBal =
        bprBal === true ||
        bprBal === 1 ||
        String(bprBal ?? "")
          .trim()
          .toLowerCase() === "t";
      const balanceReview = proof2Bal && (pendingReviewBal || awaitingBalanceConfirmBal);

      if (balanceReview) {
        if (!Number.isFinite(supplementalAmtIn) || supplementalAmtIn < 0) {
          res.status(400).json({ error: "supplemental_amount_received is required (balance payment amount)" });
          return;
        }
        const first = Number(ord.cashier_amount_received) || 0;
        const remaining = Math.round((total - first) * 100) / 100;
        if (supplementalAmtIn + 1e-9 >= remaining) {
          res.status(400).json({
            error:
              "Additional amount is not below the remaining balance. Use Confirm order if payment is exact or sufficient.",
          });
          return;
        }
        newStatus = "PAYMENT INSUFFICIENT - PAY REMAINDER";
        mailSubject = `Action needed: balance payment for ${ord.order_no}`;
        mailBody =
          `Our team reviewed your balance payment for order ${ord.order_no}.\n\n` +
          `The additional amount received (₱${supplementalAmtIn.toFixed(2)}) is still below the remaining balance of ₱${remaining.toFixed(2)}.\n\n` +
          `Please pay the remaining balance and upload a new payment proof in the app under your order.`;
        await getPool().query(
          `UPDATE restaurant_orders
           SET order_status = $2,
               cashier_amount_received_balance = $3,
               payment_proof_balance = NULL,
               payment_uploaded_balance = FALSE,
               ${RESTAURANT_ORDER_TOUCH_SET}
           WHERE mobile_id = $1`,
          [id, newStatus, supplementalAmtIn],
        );
        await notifyRestaurantOrderCustomer(guestReachFromRow(ord), mailSubject, mailBody, {
          orderNo: ord.order_no,
          inAppMessage: `[${ord.order_no}] Payment update: please pay the remaining balance (total ₱${total.toFixed(2)}).`,
        });
        res.json({ ok: true, status: newStatus });
        return;
      }

      newStatus = "PAYMENT INSUFFICIENT - PAY REMAINDER";
      mailSubject = `Action needed: payment for ${ord.order_no}`;
      mailBody =
        `Our team reviewed your payment for order ${ord.order_no}.\n\n` +
        `The amount received was not enough to cover your order total of ₱${total.toFixed(2)}.\n\n` +
        `Please pay the remaining balance through the payment channel we use for your order.\n\n` +
        `Upload your additional payment proof in the app under your order.`;
      if (!Number.isNaN(amountReceived) && amountReceived >= 0) {
        cashReceived = amountReceived;
        changeAmt = Math.round((amountReceived - total) * 100) / 100;
      }
    } else {
      const proof2Bal =
        (ord.supplemental_payment_proof != null && String(ord.supplemental_payment_proof).trim().length > 0) ||
        String(ord.payment_reference_balance ?? "").trim().length > 0;
      const statusUpBal = String(ord.status).toUpperCase();
      const awaitingBalanceConfirmBal =
        statusUpBal.includes("WAITING FOR BALANCE") || statusUpBal.includes("BALANCE PAYMENT CONFIRMATION");
      const bprBal = ord.balance_proof_pending_review as unknown;
      const pendingReviewBal =
        bprBal === true ||
        bprBal === 1 ||
        String(bprBal ?? "")
          .trim()
          .toLowerCase() === "t";
      const balanceReview = proof2Bal && (pendingReviewBal || awaitingBalanceConfirmBal);

      if (balanceReview) {
        if (!Number.isFinite(supplementalAmtIn) || supplementalAmtIn < 0) {
          res.status(400).json({ error: "supplemental_amount_received is required (balance payment amount)" });
          return;
        }
        const first = Number(ord.cashier_amount_received) || 0;
        const combined = first + supplementalAmtIn;
        if (combined - 1e-9 <= total) {
          res.status(400).json({
            error: "Combined payments do not exceed the order total. Use Confirm order or Insufficient payment instead.",
          });
          return;
        }
        newStatus = "ORDER CONFIRMED — OVERPAYMENT (EXCESS REFUND ON DELIVERY)";
        changeAmt = Math.round((combined - total) * 100) / 100;
        mailSubject = `Order ${ord.order_no} confirmed — overpayment notice`;
        mailBody =
          `Your order ${ord.order_no} has been confirmed.\n\n` +
          `We detected an overpayment relative to your order total of ₱${total.toFixed(2)}. ` +
          `The excess amount will be returned to you when your order is delivered (or per our coordinator's instructions).\n\n` +
          `Thank you for choosing Macrina's Kitchen and Catering.`;
        await getPool().query(
          `UPDATE restaurant_orders
           SET order_status = $2,
               cashier_amount_received_balance = $3,
               payment_confirmed_balance = TRUE,
               amount_paid = $4,
               change_given = $5,
               ${RESTAURANT_ORDER_TOUCH_SET}
           WHERE mobile_id = $1`,
          [id, newStatus, supplementalAmtIn, combined, changeAmt],
        );
        await notifyRestaurantOrderCustomer(guestReachFromRow(ord), mailSubject, mailBody, {
          orderNo: ord.order_no,
          inAppMessage: `[${ord.order_no}] Order confirmed. Total: ₱${total.toFixed(2)}`,
        });
        if (!isGuestUserEmail(String(ord.user_email ?? ""))) {
          await applyLoyaltyRewardsBestEffort(String(ord.user_email), ord.order_no, total, "restaurant_mobile");
        }
        res.json({ ok: true, status: newStatus });
        return;
      }

      newStatus = "ORDER CONFIRMED — OVERPAYMENT (EXCESS REFUND ON DELIVERY)";
      mailSubject = `Order ${ord.order_no} confirmed — overpayment notice`;
      mailBody =
        `Your order ${ord.order_no} has been confirmed.\n\n` +
        `We detected an overpayment relative to your order total of ₱${total.toFixed(2)}. ` +
        `The excess amount will be returned to you when your order is delivered (or per our coordinator's instructions).\n\n` +
        `Thank you for choosing Macrina's Kitchen and Catering.`;
      if (!Number.isNaN(amountReceived) && amountReceived >= 0) {
        cashReceived = amountReceived;
        changeAmt = Math.round((amountReceived - total) * 100) / 100;
      }
    }

    const amountPaidVal =
      cashReceived != null && Number.isFinite(cashReceived) ? cashReceived : null;
    const changeVal = changeAmt != null && Number.isFinite(changeAmt) ? changeAmt : null;
    await getPool().query(
      `UPDATE restaurant_orders
       SET order_status = $2,
           cashier_amount_received_initial = COALESCE($3, cashier_amount_received_initial),
           amount_paid = COALESCE($4, amount_paid),
           change_given = COALESCE($5, change_given),
           ${RESTAURANT_ORDER_TOUCH_SET}
       WHERE mobile_id = $1`,
      [id, newStatus, cashReceived, amountPaidVal, changeVal],
    );

    let inApp = `[${ord.order_no}] Status: ${newStatus}`;
    if (action === "confirm" || (action === "overpayment" && newStatus.toUpperCase().includes("CONFIRMED"))) {
      inApp = `[${ord.order_no}] Order confirmed. Total: ₱${total.toFixed(2)}`;
    } else if (action === "insufficient") {
      inApp = `[${ord.order_no}] Payment update: please pay the remaining balance (total ₱${total.toFixed(2)}).`;
    }
    await notifyRestaurantOrderCustomer(guestReachFromRow(ord), mailSubject, mailBody, {
      orderNo: ord.order_no,
      inAppMessage: inApp,
    });
    const stUp = newStatus.toUpperCase();
    if (stUp.includes("ORDER CONFIRMED") && ord.user_email && !isGuestUserEmail(String(ord.user_email))) {
      await applyLoyaltyRewardsBestEffort(String(ord.user_email), ord.order_no, total, "restaurant_mobile");
    }
    res.json({ ok: true, status: newStatus });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/pos/online-orders/:id/remind-balance", async (req, res) => {
  const id = Number(req.params.id);
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (!id || !cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "id and cashier credentials are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  try {
    await ensureCashierPosSchemaOnce();
    const { rows } = await getPool().query(
      `SELECT user_email,
              ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_no,
              COALESCE(total_cost, 0) AS total,
              COALESCE(order_status, '') AS status,
              guest_contact_email,
              contact_number AS delivery_contact,
              order_source
       FROM restaurant_orders
       WHERE mobile_id = $1`,
      [id],
    );
    const ord = rows[0] as
      | {
          user_email: string | null;
          order_no: string;
          total: string;
          status: string;
          guest_contact_email: string | null;
          delivery_contact: string | null;
          order_source: string;
        }
      | undefined;
    if (!ord || !isCashierOnlineRestaurantOrder(ord)) {
      res.status(404).json({ error: "online order not found" });
      return;
    }
    const up = String(ord.status ?? "").toUpperCase();
    if (!up.includes("INSUFFICIENT")) {
      res.status(400).json({ error: "order is not in payment insufficient status" });
      return;
    }
    const total = Number(ord.total) || 0;
    const subject = `Reminder: remaining balance for ${ord.order_no}`;
    const body =
      `This is a follow-up reminder for order ${ord.order_no}.\n\n` +
      `Your total order amount is ₱${total.toFixed(2)} and we are still waiting for the remaining balance.\n` +
      `Please upload your additional payment proof in the app so we can continue processing your order.\n\n` +
      `Thank you.`;
    await notifyRestaurantOrderCustomer(guestReachFromRow(ord), subject, body, {
      orderNo: ord.order_no,
      inAppMessage: `[${ord.order_no}] Please pay and upload proof for the remaining balance.`,
    });
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/pos/online-orders/:id/fulfillment", async (req, res) => {
  const id = Number(req.params.id);
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const stage = String(req.body?.fulfillment_stage ?? "").trim().toUpperCase();
  const tracking = String(req.body?.delivery_tracking_url ?? "").trim();
  if (!id || !cashierEmail || !cashierPassword || !stage) {
    res.status(400).json({ error: "id, cashier credentials, and fulfillment_stage are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  const allowed = ["PENDING_CASHIER", "IN_PREPARATION", "OUT_FOR_DELIVERY", "DELIVERED"];
  if (!allowed.includes(stage)) {
    res.status(400).json({ error: "invalid fulfillment_stage" });
    return;
  }
  try {
    await ensureCashierPosSchemaOnce();
    const { rows: before } = await getPool().query(
      `SELECT user_email,
              ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_no,
              guest_contact_email,
              contact_number AS delivery_contact,
              order_source
       FROM restaurant_orders
       WHERE mobile_id = $1`,
      [id],
    );
    const beforeRow = before[0] as
      | {
          user_email: string | null;
          order_no: string;
          guest_contact_email: string | null;
          delivery_contact: string | null;
          order_source: string;
        }
      | undefined;
    if (!beforeRow || !isCashierOnlineRestaurantOrder(beforeRow)) {
      res.status(404).json({ error: "online order not found" });
      return;
    }
    const { rows } = await getPool().query(
      `UPDATE restaurant_orders
       SET order_status = $2,
           delivery_tracking_url = $3,
           ${RESTAURANT_ORDER_TOUCH_SET}
       WHERE mobile_id = $1 AND order_source <> 'POS'
       RETURNING mobile_id AS id`,
      [id, stage, tracking],
    );
    if (!rows[0]) {
      res.status(404).json({ error: "online order not found" });
      return;
    }
    if (beforeRow?.user_email) {
      const trackBody =
        `Your order ${beforeRow.order_no} is now in stage: ${stage}.` + (tracking ? `\nTracking link: ${tracking}` : "");
      await notifyRestaurantOrderCustomer(guestReachFromRow(beforeRow), `Order ${beforeRow.order_no} update`, trackBody, {
        orderNo: beforeRow.order_no,
        inAppMessage:
          `[${beforeRow.order_no}] Fulfillment: ${stage.replace(/_/g, " ")}` +
          (tracking.length > 0 ? "\nTracking link added." : ""),
      });
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

/** Walk-in sale from cashier POS (no customer app account). */
app.post("/api/mobile/pos/walkin-order", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const paymentMethod = String(req.body?.payment_method ?? "").trim().toUpperCase();
  const note = String(req.body?.note ?? "");
  const customerLabel = String(req.body?.pos_customer_label ?? "").trim();
  const amountReceivedRaw = req.body?.amount_received;
  const paymentProof = normalizePaymentProofBase64(req.body?.payment_proof);
  const items: unknown[] = Array.isArray(req.body?.items) ? (req.body.items as unknown[]) : [];
  if (!cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  if (paymentMethod !== "CASH" && paymentMethod !== "GCASH") {
    res.status(400).json({ error: "payment_method must be CASH or GCASH" });
    return;
  }
  const parsedItems = items.map((i) => parseRestaurantOrderLine(i)).filter((x): x is ParsedRestaurantLine => x != null);
  if (parsedItems.length === 0) {
    res.status(400).json({ error: "valid items are required" });
    return;
  }
  const total = parsedItems.reduce((sum, i) => sum + restaurantLineSubtotal(i), 0);
  const amountReceived = Number(amountReceivedRaw);
  const changeDue =
    !Number.isNaN(amountReceived) && amountReceived >= 0 ? Math.round((amountReceived - total) * 100) / 100 : null;

  if (paymentMethod === "GCASH" && !paymentProof) {
    res.status(400).json({ error: "payment_proof is required for GCASH" });
    return;
  }

  const proofUploaded = paymentMethod === "GCASH";
  const proofVal = proofUploaded ? paymentProof : null;

  const client = await getPool().connect();
  try {
    await ensureCashierPosSchemaOnce();
    await client.query("BEGIN");
    const posNote =
      [note.trim(), customerLabel ? `Customer: ${customerLabel}` : ""].filter((x) => x.length > 0).join(" · ") || "";
    const orderId = await insertPosWalkInOrder(client, {
      posNote,
      paymentMethod,
      proofUploaded,
      proofVal,
      customerLabel: customerLabel || "Walk-in",
      total,
      amountReceived: !Number.isNaN(amountReceived) ? amountReceived : null,
      changeGiven: changeDue,
    });
    const orderNo = await finalizeRestaurantOrderAfterInsert(client, orderId, parsedItems, {
      note,
      total,
      deliveryName: "",
      deliveryContact: "",
      deliveryAddress: "",
      deliveryTime: "NOW",
      customerId: null,
    });
    await client.query("COMMIT");
    res.status(201).json({ id: orderId, order_no: orderNo, total, change: changeDue });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error(err);
    res.status(500).json({ error: "database error" });
  } finally {
    client.release();
  }
});

function numOrNull(v: unknown): number | null {
  if (v === undefined || v === null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

async function nextCustomerProfileRowId(): Promise<string> {
  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    await ensureIdCounterRow(client, "CUS", 0);
    const id = await nextCusIdFromCounter(client);
    await client.query("COMMIT");
    return id;
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

async function insertPosWalkInOrder(
  client: import("pg").PoolClient,
  params: {
    posNote: string;
    paymentMethod: string;
    proofUploaded: boolean;
    proofVal: string | null;
    customerLabel: string;
    total: number;
    amountReceived: number | null;
    changeGiven: number | null;
  },
): Promise<number> {
  const { posNote, paymentMethod, proofUploaded, proofVal, customerLabel, total, amountReceived, changeGiven } =
    params;
  const label = customerLabel.trim() || "Walk-in";
  const { rows } = await client.query(
    `INSERT INTO restaurant_orders
      (user_email, order_id, delivery_notes, payment_mode, payment_uploaded_initial, payment_proof_initial,
       full_name, contact_number, delivery_address, delivery_time, total_cost,
       order_source, pos_customer_label, cashier_amount_received_initial, amount_paid, change_given,
       order_status, submitted_order_dt_stamp, last_updated_order_status_dt_stamp)
     VALUES
      (NULL, 'TEMP', $1, $2, $3, $4, $5, '', '', 'NOW', $6,
       'POS', $7, $8, $9, $10, 'ORDER CONFIRMED', NOW(), NOW())
     RETURNING mobile_id AS id`,
    [
      posNote,
      paymentMethod,
      proofUploaded,
      proofVal,
      label,
      total,
      label,
      amountReceived,
      amountReceived,
      changeGiven,
    ],
  );
  return Number(rows[0].id);
}

async function attachOrderItems(rows: Array<Record<string, unknown>>): Promise<Array<Record<string, unknown>>> {
  type LineOut = { item_name: string; dip: string; dip_qty: number; qty: number; price: number };
  return rows.map((row) => {
    const mapped = mapRestaurantOrderRowForApi(row);
    let items: LineOut[] = [];
    const snap = mapped.order_lines_snapshot;
    if (snap != null) {
      const arr = Array.isArray(snap) ? snap : [];
      items = arr.map((it: Record<string, unknown>) => ({
        item_name: String(it.item_name ?? ""),
        dip: String(it.dip ?? ""),
        dip_qty: Math.max(0, Math.floor(Number(it.dip_qty ?? 1)) || 0),
        qty: Number(it.qty ?? 0),
        price: Number(it.price ?? 0),
      }));
    }
    return {
      ...mapped,
      items,
      total: Number(mapped.total),
    };
  });
}

async function finalizeRestaurantOrderAfterInsert(
  client: import("pg").PoolClient,
  orderId: number,
  parsedItems: ParsedRestaurantLine[],
  fields: {
    note: string;
    total: number;
    deliveryName: string;
    deliveryContact: string;
    deliveryAddress: string;
    deliveryTime: string;
    customerId: string | null;
  },
): Promise<string> {
  const orderNo = `ORD-${String(orderId).padStart(6, "0")}`;
  const itemsJson = JSON.stringify(parsedItems);
  let fullName = fields.deliveryName;
  let contactNumber = fields.deliveryContact;
  if (fields.customerId) {
    const { rows: ca } = await client.query(
      `SELECT full_name, contact_number FROM customer_accounts
       WHERE customer_id = $1
       LIMIT 1`,
      [fields.customerId],
    );
    const c = ca[0] as { full_name: string; contact_number: string } | undefined;
    if (c) {
      if (String(c.full_name ?? "").trim()) fullName = String(c.full_name).trim();
      if (String(c.contact_number ?? "").trim()) contactNumber = String(c.contact_number).trim();
    }
  }
  const updateParams = [
    orderNo,
    fields.total,
    fields.note,
    fullName,
    contactNumber,
    fields.deliveryAddress,
    fields.deliveryTime,
    itemsJson,
    orderId,
  ];
  await client.query(
    `UPDATE restaurant_orders SET
       order_id = $1,
       total_cost = $2,
       delivery_notes = $3,
       full_name = $4,
       contact_number = $5,
       delivery_address = $6,
       delivery_time = $7,
       tray_items = $8::jsonb,
       order_status = COALESCE(NULLIF(TRIM(order_status), ''), 'WAITING FOR ORDER CONFIRMATION'),
       submitted_order_dt_stamp = COALESCE(submitted_order_dt_stamp, NOW()),
       ${RESTAURANT_ORDER_TOUCH_SET}
     WHERE mobile_id = $9`,
    updateParams,
  );
  return orderNo;
}

/** Recent POS / online orders for cashier history screen — completed only (delivered online or claimed walk-in). */
app.post("/api/mobile/pos/order-history", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (!cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  try {
    await ensureCashierPosSchemaOnce();
    const pool = getPool();
    const roSelect = await getRestaurantOrderSelectSql(pool);
    const roOrderBy = `ORDER BY ${await getRestaurantOrderCreatedAtSql(pool)} DESC`;
    const { rows } = await pool.query(
      `SELECT ${roSelect},
              ${await restaurantLoyaltyEarnedSqlAsync(pool, RESTAURANT_LOYALTY_STEP_AMOUNT, RESTAURANT_LOYALTY_STEP_POINTS)}
       FROM restaurant_orders
       WHERE (
         (order_source = 'MOBILE_APP' AND upper(COALESCE(order_status, '')) LIKE '%DELIVERED%')
         OR (order_source = 'POS' AND upper(COALESCE(order_status, '')) LIKE '%CLAIMED%')
       )
       ${roOrderBy}
       LIMIT 250`,
    );
    const out = await attachOrderItems(rows as Array<Record<string, unknown>>);
    res.json(out);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

/** Walk-in POS queue: preparing (not claimed) vs claimed vs cancelled. */
app.post("/api/mobile/pos/walkin-queue", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const filter = String(req.body?.filter ?? "preparing").toLowerCase();
  if (!cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  if (!["preparing", "claimed", "cancelled"].includes(filter)) {
    res.status(400).json({ error: "filter must be preparing, claimed, or cancelled" });
    return;
  }
  try {
    await ensureCashierPosSchemaOnce();
    const pool = getPool();
    const roSelect = await getRestaurantOrderSelectSql(pool);
    const roOrderByUpdated = `ORDER BY ${await getRestaurantOrderUpdatedAtSql(pool)} DESC`;
    const roOrderByCreated = `ORDER BY ${await getRestaurantOrderCreatedAtSql(pool)} DESC`;
    if (filter === "cancelled") {
      const { rows } = await pool.query(
        `SELECT ${roSelect}, 0 AS loyalty_points_earned
         FROM restaurant_orders
         WHERE order_source = 'POS' AND upper(COALESCE(order_status, '')) LIKE '%CANCEL%'
         ${roOrderByUpdated}
         LIMIT 120`,
      );
      const out = await attachOrderItems(rows as Array<Record<string, unknown>>);
      res.json(out);
      return;
    }
    const claimed = filter === "claimed";
    const claimedClause = claimed
      ? `upper(COALESCE(order_status, '')) LIKE '%CLAIMED%'`
      : `upper(COALESCE(order_status, '')) NOT LIKE '%CLAIMED%'`;
    const { rows } = await pool.query(
      `SELECT ${roSelect},
              ${await restaurantLoyaltyEarnedSqlAsync(pool, RESTAURANT_LOYALTY_STEP_AMOUNT, RESTAURANT_LOYALTY_STEP_POINTS)}
       FROM restaurant_orders
       WHERE order_source = 'POS'
         AND ${claimedClause}
         AND upper(COALESCE(order_status, '')) NOT LIKE '%CANCEL%'
       ${roOrderByCreated}
       LIMIT 120`,
    );
    const out = await attachOrderItems(rows as Array<Record<string, unknown>>);
    res.json(out);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/pos/walkin-orders/:id/cancel", async (req, res) => {
  const id = Number(req.params.id);
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (!id || !cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "id and cashier credentials are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  try {
    await ensureCashierPosSchemaOnce();
    const { rows } = await getPool().query(
      `UPDATE restaurant_orders
       SET order_status = 'CANCELLED BY CASHIER', ${RESTAURANT_ORDER_TOUCH_SET}
       WHERE mobile_id = $1 AND order_source = 'POS'
         AND upper(COALESCE(order_status, '')) NOT LIKE '%CANCEL%'
       RETURNING mobile_id AS id`,
      [id],
    );
    if (!rows[0]) {
      res.status(404).json({ error: "walk-in order cannot be cancelled (not found, already claimed, or already cancelled)" });
      return;
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/pos/walkin-orders/:id/claim", async (req, res) => {
  const id = Number(req.params.id);
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  if (!id || !cashierEmail || !cashierPassword) {
    res.status(400).json({ error: "id and cashier credentials are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["cashier"])).ok) {
    res.status(403).json({ error: "invalid cashier credentials" });
    return;
  }
  try {
    await ensureCashierPosSchemaOnce();
    const { rows } = await getPool().query(
      `UPDATE restaurant_orders
       SET order_status = 'WALK-IN CLAIMED', ${RESTAURANT_ORDER_TOUCH_SET}
       WHERE mobile_id = $1 AND order_source = 'POS'
         AND upper(COALESCE(order_status, '')) NOT LIKE '%CLAIMED%'
       RETURNING mobile_id AS id`,
      [id],
    );
    if (!rows[0]) {
      res.status(404).json({ error: "walk-in order not found" });
      return;
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/profile", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    await refreshLoyaltyTotalsForUser(userEmail);
    const { rows } = await getPool().query(
      `SELECT email AS user_email, full_name, contact_number,
              COALESCE(primary_delivery_address, '') AS delivery_address,
              delivery_map_confirmed, delivery_lat, delivery_lng,
              COALESCE(restaurant_loyalty_points, 0) AS loyalty_points_restaurant,
              COALESCE(catering_loyalty_points, 0) AS loyalty_points_catering,
              COALESCE(restaurant_loyalty_points, 0) + COALESCE(catering_loyalty_points, 0) AS loyalty_points,
              COALESCE(other_delivery_addresses, '[]'::jsonb) AS delivery_addresses,
              customer_id
       FROM customer_accounts WHERE LOWER(TRIM(email)) = $1`,
      [userEmail],
    );
    if (!rows[0]) {
      res.json({
        user_email: userEmail,
        full_name: "",
        contact_number: "",
        delivery_address: "",
        delivery_map_confirmed: false,
        delivery_lat: null,
        delivery_lng: null,
        loyalty_points: 0,
        loyalty_points_restaurant: 0,
        loyalty_points_catering: 0,
        delivery_addresses: [],
      });
      return;
    }
    res.json(mapProfileRowForApi(rows[0] as Record<string, unknown>));
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/loyalty-history", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    await ensureNewEventSchemaOnce();
    const pool = getPool();
    const roMatch = await restaurantOrderMatchesEmailWhere(pool, "ro", "$1");
    const roCreatedAt = await getRestaurantOrderCreatedAtSql(pool, "ro");
    const eoCreatedAt = await getCateringOrderCreatedAtSql(pool, "event_orders", "eo");
    const coCreatedAt = await getCateringOrderCreatedAtSql(pool, "catering_orders", "co");
    const { rows } = await pool.query(
      `SELECT order_no, points_delta, created_at, source
       FROM (
         SELECT SUBSTRING(ro.payment_reference_initial FROM LENGTH($3::text) + 1) AS order_no,
                COALESCE(
                  ro.loyalty_points_restaurant_obtained,
                  CASE
                    WHEN COALESCE(ro.delivery_notes, '') LIKE '%Catering event loyalty%' THEN
                      FLOOR(COALESCE(ro.total_cost, 0)::numeric / ${CATERING_LOYALTY_STEP_AMOUNT}::numeric)::int * ${CATERING_LOYALTY_STEP_POINTS}
                    ELSE
                      FLOOR(COALESCE(ro.total_cost, 0)::numeric / ${RESTAURANT_LOYALTY_STEP_AMOUNT}::numeric)::int * ${RESTAURANT_LOYALTY_STEP_POINTS}
                  END
                ) AS points_delta,
                ${roCreatedAt} AS created_at,
                CASE
                  WHEN COALESCE(ro.delivery_notes, '') LIKE '%Catering event loyalty%' THEN 'catering'
                  ELSE 'restaurant'
                END AS source
         FROM restaurant_orders ro
         WHERE ro.payment_reference_initial LIKE $2
           AND (
             ${roMatch}
             OR POSITION(LOWER($1) IN LOWER(COALESCE(ro.delivery_notes, ''))) > 0
           )
         UNION ALL
         SELECT ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_no,
                GREATEST(
                  COALESCE(ro.loyalty_points_restaurant_obtained, 0),
                  CASE
                    WHEN upper(COALESCE(ro.order_status, '')) LIKE '%ORDER CONFIRMED%'
                      OR upper(COALESCE(ro.order_status, '')) LIKE '%OVERPAYMENT%'
                      OR upper(COALESCE(ro.order_status, '')) LIKE '%DELIVERED%'
                      THEN FLOOR(COALESCE(ro.total_cost, 0)::numeric / ${RESTAURANT_LOYALTY_STEP_AMOUNT}::numeric)::int * ${RESTAURANT_LOYALTY_STEP_POINTS}
                    ELSE 0
                  END
                ) AS points_delta,
                ${roCreatedAt} AS created_at,
                'restaurant' AS source
         FROM restaurant_orders ro
         WHERE ${roMatch}
           AND COALESCE(ro.order_source, '') NOT IN ('POS', 'LOYALTY_SYNC')
           AND (
             upper(COALESCE(ro.order_status, '')) LIKE '%ORDER CONFIRMED%'
             OR upper(COALESCE(ro.order_status, '')) LIKE '%OVERPAYMENT%'
             OR upper(COALESCE(ro.order_status, '')) LIKE '%DELIVERED%'
           )
         UNION ALL
         SELECT COALESCE(NULLIF(TRIM(${EVENT_TRANSACTION_ID}), ''), 'EVT-' || eo.id::text) AS order_no,
                COALESCE(eo.loyalty_points_catering_obtained, 0) AS points_delta,
                ${eoCreatedAt} AS created_at,
                'catering' AS source
         FROM event_orders eo
         WHERE LOWER(TRIM(eo.email_address)) = LOWER($1)
           AND COALESCE(eo.loyalty_points_catering_obtained, 0) > 0
           AND LOWER(TRIM(eo.status)) = 'completed'
         UNION ALL
         SELECT COALESCE(NULLIF(TRIM(${CATERING_TRANSACTION_ID}), ''), 'CAT-' || co.id::text) AS order_no,
                COALESCE(co.loyalty_points_catering_obtained, 0) AS points_delta,
                ${coCreatedAt} AS created_at,
                'catering' AS source
         FROM catering_orders co
         WHERE LOWER(TRIM(co.email_address)) = LOWER($1)
           AND COALESCE(co.loyalty_points_catering_obtained, 0) > 0
           AND LOWER(TRIM(co.status)) = 'completed'
       ) combined
       WHERE points_delta > 0
       ORDER BY created_at DESC
       LIMIT 150`,
      [userEmail, `${MOBILE_LOYALTY_PAYMENT_PREFIX}%`, MOBILE_LOYALTY_PAYMENT_PREFIX],
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.put("/api/mobile/profile", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const fullName = String(req.body?.full_name ?? "").trim();
  const contactNumber = String(req.body?.contact_number ?? "").trim();
  const deliveryAddress = String(req.body?.delivery_address ?? "").trim();
  const mapConfirmed =
    typeof req.body?.delivery_map_confirmed === "boolean" ? req.body.delivery_map_confirmed : false;
  const latNum = numOrNull(req.body?.delivery_lat);
  const lngNum = numOrNull(req.body?.delivery_lng);
  let deliveryAddressesJson = "[]";
  if (Array.isArray(req.body?.delivery_addresses)) {
    const arr = (req.body.delivery_addresses as unknown[])
      .map((x) => String(x ?? "").trim())
      .filter((s) => s.length > 0);
    deliveryAddressesJson = JSON.stringify(arr);
  }
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const existingId = await getPool().query(
      `SELECT customer_id FROM customer_accounts WHERE LOWER(TRIM(email)) = $1`,
      [userEmail],
    );
    const rowId =
      (existingId.rows[0] as { customer_id: string } | undefined)?.customer_id ??
      (await nextCustomerProfileRowId());
    const { rows } = await getPool().query(
      `INSERT INTO customer_accounts (
         email, password_hash, full_name, contact_number, is_verified, customer_id,
         primary_delivery_address, delivery_map_confirmed, delivery_lat, delivery_lng, other_delivery_addresses,
         created_account_dt_stamp, updated_pw_dt_stamp
       )
       VALUES ($2, '', $3, $4, TRUE, $1, $5, $6, $7, $8, $9::jsonb, NOW(), NOW())
       ON CONFLICT (email)
       DO UPDATE SET full_name = EXCLUDED.full_name,
                     contact_number = EXCLUDED.contact_number,
                     primary_delivery_address = EXCLUDED.primary_delivery_address,
                     delivery_map_confirmed = EXCLUDED.delivery_map_confirmed,
                     delivery_lat = EXCLUDED.delivery_lat,
                     delivery_lng = EXCLUDED.delivery_lng,
                     other_delivery_addresses = EXCLUDED.other_delivery_addresses,
                     customer_id = COALESCE(NULLIF(TRIM(customer_accounts.customer_id), ''), EXCLUDED.customer_id),
                     updated_pw_dt_stamp = NOW()
       RETURNING email AS user_email, full_name, contact_number,
                 COALESCE(primary_delivery_address, '') AS delivery_address,
                 delivery_map_confirmed, delivery_lat, delivery_lng,
                 COALESCE(other_delivery_addresses, '[]'::jsonb) AS delivery_addresses,
                 COALESCE(restaurant_loyalty_points, 0) AS loyalty_points_restaurant,
                 COALESCE(catering_loyalty_points, 0) AS loyalty_points_catering,
                 COALESCE(restaurant_loyalty_points, 0) + COALESCE(catering_loyalty_points, 0) AS loyalty_points,
                 customer_id`,
      [rowId, userEmail, fullName, contactNumber, deliveryAddress, mapConfirmed, latNum, lngNum, deliveryAddressesJson],
    );
    await logActionBestEffort("profile.update", userEmail, "Customer profile updated", {
      has_map_pin: mapConfirmed,
    });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/orders", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  const contactEmail = String(req.query.contact_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    await ensureRestaurantOrdersApiSchemaOnce();
    const pool = getPool();
    const roSelect = await getRestaurantOrderSelectSql(pool);
    const roMatch = await restaurantOrderMatchesEmailWhere(pool, "", "$1");
    const { rows } = await pool.query(
      `SELECT ${roSelect},
              ${await restaurantLoyaltyEarnedSqlAsync(pool, RESTAURANT_LOYALTY_STEP_AMOUNT, RESTAURANT_LOYALTY_STEP_POINTS)}
       FROM restaurant_orders
       WHERE ${roMatch}
          OR LOWER(TRIM(COALESCE(guest_contact_email, ''))) = LOWER(TRIM($1))
          OR ($2 <> '' AND LOWER(TRIM(COALESCE(guest_contact_email, ''))) = LOWER(TRIM($2)))
       ORDER BY ${await getRestaurantOrderCreatedAtSql(pool)} DESC`,
      [userEmail, contactEmail],
    );
    const out = await attachOrderItems(rows as Array<Record<string, unknown>>);
    res.json(out);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/orders", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const note = String(req.body?.note ?? "");
  const paymentMode = "GCASH ONLY";
  const deliveryName = String(req.body?.delivery_name ?? "");
  const deliveryContact = String(req.body?.delivery_contact ?? "");
  const deliveryAddress = String(req.body?.delivery_address ?? "");
  const deliveryTimeRaw = String(req.body?.delivery_time ?? "NOW").trim();
  const deliveryTime = deliveryTimeRaw.length > 0 ? deliveryTimeRaw : "NOW";
  const items: unknown[] = Array.isArray(req.body?.items) ? (req.body.items as unknown[]) : [];
  if (!userEmail || items.length === 0) {
    res.status(400).json({ error: "user_email and items are required" });
    return;
  }
  if (!deliveryName.trim() || !deliveryContact.trim() || !deliveryAddress.trim()) {
    res.status(400).json({ error: "delivery_name, delivery_contact, and delivery_address are required" });
    return;
  }
  const parsedItems = items.map((i) => parseRestaurantOrderLine(i)).filter((x): x is ParsedRestaurantLine => x != null);
  if (parsedItems.length === 0) {
    res.status(400).json({ error: "valid items are required" });
    return;
  }
  const total = parsedItems.reduce((sum, i) => sum + restaurantLineSubtotal(i), 0);
  const contactEmail = String(req.body?.contact_email ?? "").trim().toLowerCase();
  const isGuest = isGuestUserEmail(userEmail);
  const customerId = await restaurantOrderCustomerIdForCheckout(userEmail, isGuest);
  const guestContactEmail = isGuest && contactEmail ? contactEmail : null;
  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    const hasRoUserEmail = await columnExists(getPool(), "restaurant_orders", "user_email");
    const { rows } = await client.query(
      hasRoUserEmail
        ? `INSERT INTO restaurant_orders
            (user_email, customer_id, guest_contact_email, order_id, delivery_notes, payment_mode,
             full_name, contact_number, delivery_address, delivery_time, total_cost)
           VALUES
            ($1, $2, $3, 'TEMP', $4, $5, $6, $7, $8, $9, $10)
           RETURNING mobile_id AS id`
        : `INSERT INTO restaurant_orders
            (customer_id, guest_contact_email, order_id, delivery_notes, payment_mode,
             full_name, contact_number, delivery_address, delivery_time, total_cost)
           VALUES
            ($1, $2, 'TEMP', $3, $4, $5, $6, $7, $8, $9)
           RETURNING mobile_id AS id`,
      hasRoUserEmail
        ? [userEmail, customerId, guestContactEmail, note, paymentMode, deliveryName, deliveryContact, deliveryAddress, deliveryTime, total]
        : [customerId, guestContactEmail, note, paymentMode, deliveryName, deliveryContact, deliveryAddress, deliveryTime, total],
    );
    const orderId = Number(rows[0].id);
    const orderNo = await finalizeRestaurantOrderAfterInsert(client, orderId, parsedItems, {
      note,
      total,
      deliveryName,
      deliveryContact,
      deliveryAddress,
      deliveryTime,
      customerId,
    });
    await client.query("COMMIT");
    // Loyalty is awarded when the cashier confirms the order (see online-orders review), not on submit.
    void logActionBestEffort("order.submit", userEmail, `Order submitted: ${orderNo}`, {
      order_no: orderNo,
      total,
      item_count: parsedItems.length,
    });
    if (!isGuest) {
      void sendMailSafe(
        userEmail,
        `${orderNo} — order placed`,
        `Thank you for ordering with Macrina's Kitchen and Catering.\n\n` +
          `Your restaurant order ${orderNo} has been placed and is awaiting payment confirmation from our team.\n` +
          `You will be notified by email as soon as your payment has been confirmed.\n\n` +
          `Total: ₱${total.toFixed(2)}\n\n` +
          `Please complete payment (GCash) and upload your proof in the app if you have not already.`,
      );
    }
    res.status(201).json({ id: orderId, order_id: orderNo, order_no: orderNo, total });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error(err);
    res.status(500).json({ error: "database error" });
  } finally {
    client.release();
  }
});

async function saveRestaurantPaymentProof(
  id: number,
  proof: string,
  insufficient: boolean,
): Promise<void> {
  const pool = getPool();
  const touch = RESTAURANT_ORDER_TOUCH_SET;
  if (insufficient) {
    try {
      await pool.query(
        `UPDATE restaurant_orders
         SET payment_proof_balance = $2,
             order_status = 'WAITING FOR BALANCE PAYMENT CONFIRMATION',
             payment_uploaded_balance = TRUE,
             ${touch}
         WHERE mobile_id = $1`,
        [id, proof],
      );
      return;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (!/payment_proof_balance|payment_uploaded_balance/i.test(msg)) throw e;
      await pool.query(
        `UPDATE restaurant_orders
         SET supplemental_payment_proof = $2,
             order_status = 'WAITING FOR BALANCE PAYMENT CONFIRMATION',
             payment_uploaded = TRUE,
             ${touch}
         WHERE mobile_id = $1`,
        [id, proof],
      );
      return;
    }
  }
  try {
    await pool.query(
      `UPDATE restaurant_orders
       SET payment_uploaded_initial = TRUE,
           payment_proof_initial = $2,
           ${touch}
       WHERE mobile_id = $1`,
      [id, proof],
    );
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (!/payment_proof_initial|payment_uploaded_initial/i.test(msg)) throw e;
    await pool.query(
      `UPDATE restaurant_orders
       SET payment_uploaded = TRUE,
           payment_proof = $2,
           ${touch}
       WHERE mobile_id = $1`,
      [id, proof],
    );
  }
}

app.patch("/api/mobile/orders/:id/payment", async (req, res) => {
  const id = Number(req.params.id);
  const paymentProof = normalizePaymentProofBase64(req.body?.payment_proof);
  if (!id || !paymentProof) {
    res.status(400).json({ error: "id and payment_proof are required" });
    return;
  }
  if (paymentProof.length > 6_000_000) {
    res.status(400).json({ error: "payment proof image is too large" });
    return;
  }
  try {
    await ensureRestaurantOrdersApiSchemaOnce();
    const { rows: found } = await getPool().query(
      `SELECT mobile_id AS id,
              COALESCE(order_status, 'PENDING_CASHIER') AS status,
              ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_no,
              COALESCE(total_cost, 0) AS total,
              COALESCE(delivery_notes, '') AS note,
              user_email, guest_contact_email,
              COALESCE(contact_number, '') AS delivery_contact,
              COALESCE(payment_uploaded_initial, FALSE) AS payment_uploaded,
              COALESCE(tray_items, '[]'::jsonb) AS order_lines_snapshot
       FROM restaurant_orders WHERE mobile_id = $1`,
      [id],
    );
    const row = found[0] as {
      id: number;
      status: string;
      order_no: string;
      total: string;
      note: string;
      user_email: string | null;
      guest_contact_email: string | null;
      delivery_contact: string | null;
      payment_uploaded: boolean;
      order_lines_snapshot: unknown;
    } | undefined;
    if (!row) {
      res.status(404).json({ error: "order not found" });
      return;
    }
    const insufficient = String(row.status).toUpperCase().includes("INSUFFICIENT");
    const hadProofBefore = row.payment_uploaded === true;
    if (insufficient) {
      await saveRestaurantPaymentProof(id, paymentProof, true);
      try {
        await getPool().query(
          `INSERT INTO notifications (user_id, message)
           SELECT email, $1
           FROM users
           WHERE role = 'cashier'`,
          [`Balance payment proof uploaded for ${row.order_no}. Please review and confirm the order.`],
        );
      } catch (notifyErr) {
        console.warn("[payment] cashier inbox notify skipped:", notifyErr instanceof Error ? notifyErr.message : notifyErr);
      }
      const notify = process.env.CASHIER_BALANCE_NOTIFY_EMAIL?.trim();
      if (notify) {
        void sendMailSafe(
          notify,
          `Balance payment proof — ${row.order_no}`,
          `A customer uploaded supplemental payment proof for order ${row.order_no}. Open Online Orders in the cashier app to review and enter the amount received.`,
        );
      }
    } else {
      await saveRestaurantPaymentProof(id, paymentProof, false);
      const totalNum = Number(row.total) || 0;
      const emailTo = String(row.user_email ?? "").trim().toLowerCase();
      if (!hadProofBefore) {
        if (isGuestUserEmail(emailTo)) {
          const guestEm = String(row.guest_contact_email ?? "").trim().toLowerCase();
          const snap = row.order_lines_snapshot;
          const arr = Array.isArray(snap) ? snap : [];
          const lines = arr.map((i) => parseRestaurantOrderLine(i)).filter((x): x is ParsedRestaurantLine => x != null);
          if (guestEm) {
            void sendGuestOrderProofConfirmation({
              orderNo: row.order_no,
              guestContactEmail: guestEm,
              deliveryContact: String(row.delivery_contact ?? ""),
              lines,
              total: totalNum,
              note: row.note ?? "",
              paymentProofBase64: paymentProof,
            });
          }
        } else if (emailTo) {
          void sendMailSafe(
            emailTo,
            `Order ${row.order_no} — checkout complete`,
            `Your order ${row.order_no} payment proof was received.\nTotal: ₱${totalNum.toFixed(2)}\nNote: ${row.note || "(none)"}\n\nOur team will review your payment shortly.`,
          );
        }
      }
    }
    const { rows } = await getPool().query(
      `SELECT mobile_id AS id,
              ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_no,
              ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_id,
              COALESCE(payment_uploaded_initial, payment_uploaded, FALSE) AS payment_uploaded
       FROM restaurant_orders WHERE mobile_id = $1`,
      [id],
    );
    const orderNo = String((rows[0] as { order_no?: string } | undefined)?.order_no ?? "");
    await logActionBestEffort("order.payment.upload", "", "Payment proof uploaded", {
      order_id: id,
      order_no: orderNo,
      supplemental: insufficient,
    });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/inquiries/:id/cancel-customer", async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  if (!id || !userEmail) {
    res.status(400).json({ error: "id and user_email are required" });
    return;
  }
  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    const tryCancel = async (table: "catering_orders" | "event_orders") => {
      const txCol = table === "catering_orders" ? "catering_id" : "event_id";
      const { rows } = await client.query(
        `SELECT id::text AS id, status, COALESCE(NULLIF(TRIM(${txCol}::text), ''), CONCAT('TRX-', id::text)) AS tx
         FROM ${table}
         WHERE id::text = $1
           AND (LOWER(TRIM(email_address)) = $2 OR LOWER(TRIM(COALESCE(customer_id::text, ''))) = $2)
         FOR UPDATE`,
        [id, userEmail],
      );
      const row = rows[0] as { id: string; status: string; tx: string } | undefined;
      if (!row) return { found: false, cancelled: false, tx: "" };
      const st = String(row.status ?? "").trim().toLowerCase();
      if (
        st !== "new_event" &&
        st !== "online_inquiries" &&
        st !== "for_down_payment" &&
        st !== "for_ongoing"
      ) {
        return { found: true, cancelled: false, tx: row.tx };
      }
      await client.query(
        `UPDATE ${table}
         SET status = 'cancelled', ${CATERING_ORDER_TOUCH_SET}, updated_by = $3
         WHERE id::text = $1
           AND (LOWER(TRIM(email_address)) = $2 OR LOWER(TRIM(COALESCE(customer_id::text, ''))) = $2)`,
        [id, userEmail, userEmail],
      );
      return { found: true, cancelled: true, tx: row.tx };
    };
    const first = await tryCancel("catering_orders");
    const second = first.found ? first : await tryCancel("event_orders");
    if (!second.found) {
      await client.query("ROLLBACK");
      res.status(404).json({ error: "inquiry not found" });
      return;
    }
    if (!second.cancelled) {
      await client.query("ROLLBACK");
      res.status(400).json({ error: "this inquiry can no longer be cancelled" });
      return;
    }
    try {
      await client.query(
        `INSERT INTO notifications (user_id, message)
         SELECT email, $1
         FROM users
         WHERE LOWER(TRIM(role)) IN ('manager', 'supervisor') AND COALESCE(archived, FALSE) = FALSE`,
        [`Inquiry cancelled: ${second.tx} (${userEmail}). Check the Cancelled tab.`],
      );
    } catch (notifyErr) {
      console.warn("[inquiry-cancel] manager notify skipped:", notifyErr instanceof Error ? notifyErr.message : notifyErr);
    }
    await client.query("COMMIT");
    res.json({ ok: true, transaction_no: second.tx });
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    console.error(err);
    res.status(500).json({ error: "database error" });
  } finally {
    client.release();
  }
});

app.patch("/api/mobile/orders/:id/cancel-customer", async (req, res) => {
  const id = Number(req.params.id);
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  if (!id || !userEmail) {
    res.status(400).json({ error: "id and user_email are required" });
    return;
  }
  try {
    const pool = getPool();
    const roMatch = await restaurantOrderMatchesEmailWhere(pool, "", "$2");
    const { rows } = await pool.query(
      `SELECT mobile_id AS id, COALESCE(order_status, '') AS status, ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_no
       FROM restaurant_orders WHERE mobile_id = $1 AND ${roMatch}`,
      [id, userEmail],
    );
    const row = rows[0] as { id: number; status: string; order_no: string } | undefined;
    if (!row) {
      res.status(404).json({ error: "order not found" });
      return;
    }
    const st = String(row.status).toUpperCase();
    const cancellable =
      st.includes("WAITING FOR PAYMENT CONFIRMATION") ||
      st.includes("WAITING FOR ORDER CONFIRMATION") ||
      st.includes("WAITING FOR ORDER") ||
      st.includes("INSUFFICIENT");
    if (!cancellable) {
      res.status(400).json({ error: "This order can no longer be cancelled from the app." });
      return;
    }
    await getPool().query(
      `UPDATE restaurant_orders SET order_status = $2, last_updated_order_status_dt_stamp = NOW() WHERE mobile_id = $1`,
      [
      id,
      "CANCELLED BY CUSTOMER",
    ]);
    await logActionBestEffort("order.cancel.customer", userEmail, `Customer cancelled ${row.order_no}`, {
      order_id: id,
      order_no: row.order_no,
    });
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

/** Public: count how many proposed event windows overlap any order currently in For Processing. */
app.post("/api/mobile/catering/schedule-conflicts", async (req, res) => {
  const windowsBody = Array.isArray(req.body?.windows) ? (req.body.windows as unknown[]) : [];
  const fakeSlots: unknown[] = [];
  for (const w of windowsBody) {
    if (w && typeof w === "object" && !Array.isArray(w)) fakeSlots.push(w);
  }
  const candidate = windowsFromScheduleSlots(fakeSlots);
  try {
    const { rows } = await getPool().query(
      `SELECT schedule_slots FROM catering_orders WHERE status IN (${CATERING_ACTIVE_SCHEDULE_STATUSES_SQL})
       UNION ALL
       SELECT schedule_slots FROM event_orders WHERE status IN (${CATERING_ACTIVE_SCHEDULE_STATUSES_SQL})`,
    );
    let conflictWindowCount = 0;
    for (const c of candidate) {
      let hit = false;
      for (const row of rows) {
        const busy = windowsFromScheduleSlots((row as { schedule_slots: unknown }).schedule_slots);
        for (const b of busy) {
          if (cateringWindowsOverlap(c, b)) {
            hit = true;
            break;
          }
        }
        if (hit) break;
      }
      if (hit) conflictWindowCount++;
    }
    res.json({
      conflict_window_count: conflictWindowCount,
      has_conflict: conflictWindowCount > 0,
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/public/events/theme-design/theme-search", async (req, res) => {
  try {
    const query = String(req.body?.prompt ?? "").trim();
    const eventTitle = String(req.body?.eventTitle ?? "").trim();
    const eventType = String(req.body?.eventType ?? "").trim();
    const formalityLevel = String(req.body?.formalityLevel ?? "").trim();
    const pageNum = Math.max(1, Number(req.body?.page ?? 1));
    const perPage = Math.max(1, Math.min(24, Number(req.body?.perPage ?? 12)));
    const pexelsQuery = buildPexelsQuery({
      eventTitle,
      eventType,
      formalityLevel,
      prompt: query,
      forceNoPeople: true,
    });
    const pex = await fetchPexelsImages({ query: pexelsQuery, perPage: 30, page: pageNum });
    const source = pex.images.length > 0 ? pex.images : sanitizeThemeSuggestions(fallbackThemeSuggestions);
    const start = 0;
    const total = source.length;
    const images = source.slice(start, start + perPage);
    res.json({
      ok: true,
      query,
      usedFallback: pex.images.length === 0,
      error: pex.images.length === 0 ? pex.error || undefined : undefined,
      images,
      page: pageNum,
      perPage,
      total,
      hasMore: images.length < total,
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "theme search failed" });
  }
});

app.post("/api/public/events/theme-design/yolo-sam-infer", async (req, res) => {
  try {
    const cleanedImageBase64 = sanitizeBase64Image(req.body?.imageBase64);
    const fast = await callAiService(
      "/v1/infer/yolo-sam",
      {
        image_base64: cleanedImageBase64,
        confidence_threshold: Number.isFinite(Number(req.body?.confidenceThreshold))
          ? Number(req.body?.confidenceThreshold)
          : 0.25,
        max_detections: Number.isFinite(Number(req.body?.maxDetections)) ? Number(req.body?.maxDetections) : 30,
        mask_format: ["polygon", "rle", "alpha_png"].includes(String(req.body?.maskFormat))
          ? String(req.body?.maskFormat)
          : "polygon",
      },
      AI_SERVICE_TIMEOUT_SEGMENT_MS,
    );
    const objects = Array.isArray(fast.objects) ? fast.objects : [];
    res.json({
      ok: true,
      imageWidth: Number(fast.image_width ?? fast.imageWidth ?? 0),
      imageHeight: Number(fast.image_height ?? fast.imageHeight ?? 0),
      detections: Array.isArray(fast.detections) ? fast.detections : [],
      objects,
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err instanceof Error ? err.message : "Failed to run YOLO+SAM inference" });
  }
});

app.post("/api/public/events/theme-design/swap-colors", async (req, res) => {
  try {
    const cleanedImageBase64 = sanitizeBase64Image(req.body?.imageBase64);
    const masks = Array.isArray(req.body?.masks) ? req.body.masks : [];
    const edits = Array.isArray(req.body?.edits) ? req.body.edits : [];
    const normalizedMasks = masks
      .filter((m: unknown) => m && typeof m === "object")
      .map((m: unknown) => {
        const o = m as Record<string, unknown>;
        return {
          object_id: String(o.objectId ?? o.object_id ?? ""),
          polygon_points: Array.isArray(o.polygonPoints) ? o.polygonPoints : Array.isArray(o.polygon_points) ? o.polygon_points : undefined,
          mask_rle: o.maskRle ?? o.mask_rle ?? undefined,
          mask_base64: o.maskBase64 ?? o.mask_base64 ?? undefined,
        };
      })
      .filter((m: { object_id: string }) => Boolean(m.object_id));
    const normalizedEdits = edits
      .filter((e: unknown) => e && typeof e === "object")
      .map((e: unknown) => {
        const o = e as Record<string, unknown>;
        return {
          object_id: String(o.objectId ?? o.object_id ?? ""),
          target_hex: ensureHexColor(o.targetHex ?? o.target_hex ?? req.body?.currentTintColorHex),
          intensity: Number(o.intensity ?? 1),
        };
      })
      .filter((e: { object_id: string }) => Boolean(e.object_id));
    const fast = await callAiService(
      "/v1/edit/recolor",
      {
        image_base64: cleanedImageBase64,
        masks: normalizedMasks,
        edits: normalizedEdits,
      },
      AI_SERVICE_TIMEOUT_RECOLOR_MS,
    );
    res.json({
      ok: true,
      imageBase64: String(fast.image_base64 ?? fast.imageBase64 ?? ""),
      applied: Array.isArray(fast.applied) ? fast.applied : [],
      skipped: Array.isArray(fast.skipped) ? fast.skipped : [],
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err instanceof Error ? err.message : "Failed to recolor theme objects" });
  }
});

app.post("/api/public/events/theme-design/extract-objects", async (req, res) => {
  try {
    const imagesBase64 = Array.isArray(req.body?.imagesBase64) ? req.body.imagesBase64 : [];
    const results: Array<Record<string, unknown>> = [];
    for (let i = 0; i < imagesBase64.length; i++) {
      try {
        const cleaned = sanitizeBase64Image(imagesBase64[i]);
        const fast = await callAiService(
          "/v1/infer/yolo-sam-extract",
          {
            image_base64: cleaned,
            confidence_threshold: Number.isFinite(Number(req.body?.confidenceThreshold))
              ? Number(req.body?.confidenceThreshold)
              : 0.35,
            max_detections: Number.isFinite(Number(req.body?.maxDetections)) ? Number(req.body?.maxDetections) : 20,
            mask_format: "alpha_png",
          },
          AI_SERVICE_TIMEOUT_SEGMENT_MS,
        );
        const objects = Array.isArray(fast.objects)
          ? fast.objects.map((obj: unknown, idx: number) => {
              const o = obj as Record<string, unknown>;
              return {
                id: String(o.id ?? o.object_id ?? `obj_${i}_${idx}`),
                label: String(o.label ?? "Object"),
                score: Number(o.score ?? 0),
                sourceImageIndex: i,
                boundingBox: {
                  left: Number((o.box as Record<string, unknown> | undefined)?.x ?? (o.box as Record<string, unknown> | undefined)?.left ?? 0),
                  top: Number((o.box as Record<string, unknown> | undefined)?.y ?? (o.box as Record<string, unknown> | undefined)?.top ?? 0),
                  width: Number((o.box as Record<string, unknown> | undefined)?.width ?? 0),
                  height: Number((o.box as Record<string, unknown> | undefined)?.height ?? 0),
                },
                polygonPoints: normalizePolygonPoints(o.polygon_points ?? o.polygonPoints ?? []),
                maskBase64: String(o.mask_base64 ?? o.maskBase64 ?? ""),
                objectImageBase64: String(o.object_image_base64 ?? o.objectImageBase64 ?? ""),
              };
            })
          : [];
        results.push({
          imageIndex: i,
          imageWidth: Number(fast.image_width ?? fast.imageWidth ?? 0),
          imageHeight: Number(fast.image_height ?? fast.imageHeight ?? 0),
          objects,
        });
      } catch {
        results.push({ imageIndex: i, imageWidth: 0, imageHeight: 0, objects: [] });
      }
    }
    res.json({ ok: true, images: results });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err instanceof Error ? err.message : "Failed to extract theme objects" });
  }
});

app.post("/api/public/events/theme-design/analyze-base", async (req, res) => {
  try {
    const cleaned = sanitizeBase64Image(req.body?.baseImageBase64);
    let objects: Array<Record<string, unknown>> = [];
    try {
      const fast = await callAiService(
        "/v1/infer/yolo-sam",
        {
          image_base64: cleaned,
          confidence_threshold: 0.25,
          max_detections: 20,
          mask_format: "polygon",
        },
        AI_SERVICE_TIMEOUT_SEGMENT_MS,
      );
      objects = Array.isArray(fast.objects) ? (fast.objects as Array<Record<string, unknown>>) : [];
    } catch {
      objects = [];
    }
    const occupied = objects.map((obj) => {
      const box = (obj.box ?? {}) as Record<string, unknown>;
      return {
        left: Number(box.x ?? box.left ?? 0),
        top: Number(box.y ?? box.top ?? 0),
        width: Number(box.width ?? 0),
        height: Number(box.height ?? 0),
        label: String(obj.label ?? "Object"),
      };
    });
    const freeSpaces: Array<Record<string, number>> = [];
    const grid = 3;
    for (let row = 0; row < grid; row++) {
      for (let col = 0; col < grid; col++) {
        const left = col / grid;
        const top = row / grid;
        const width = 1 / grid;
        const height = 1 / grid;
        const overlaps = occupied.some((box) => {
          const xOverlap = Math.max(0, Math.min(left + width, box.left + box.width) - Math.max(left, box.left));
          const yOverlap = Math.max(0, Math.min(top + height, box.top + box.height) - Math.max(top, box.top));
          return xOverlap * yOverlap > 0.02;
        });
        if (!overlaps) freeSpaces.push({ left, top, width, height });
      }
    }
    res.json({
      ok: true,
      freeSpaces,
      recommendations: occupied.some((o) => /table|desk|counter|buffet/i.test(String(o.label)))
        ? ["flowers", "fruit platter", "plates", "napkins"]
        : ["flowers", "lights", "decorative elements", "table setup"],
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err instanceof Error ? err.message : "Failed to analyze base image" });
  }
});

app.post("/api/public/events/theme-design/auto-place", async (req, res) => {
  try {
    const freeSpaces = Array.isArray(req.body?.freeSpaces) ? req.body.freeSpaces : [];
    const objects = Array.isArray(req.body?.objects) ? req.body.objects : [];
    const placements = objects.map((obj: unknown, idx: number) => {
      const slot = (freeSpaces[idx % Math.max(1, freeSpaces.length)] as Record<string, unknown> | undefined) ?? {
        left: 0.1 + ((idx % 3) * 0.25),
        top: 0.2 + ((idx % 2) * 0.25),
        width: 0.25,
        height: 0.25,
      };
      const o = obj as Record<string, unknown>;
      return {
        objectId: String(o.id ?? `obj_${idx}`),
        x: Number(slot.left ?? 0),
        y: Number(slot.top ?? 0),
        width: Number(slot.width ?? 0.25),
        height: Number(slot.height ?? 0.25),
        rotation: 0,
        zIndex: idx,
        confidence: 0.72,
        reason: "Placed in low-occupancy region",
      };
    });
    res.json({ ok: true, placements });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err instanceof Error ? err.message : "Failed to auto-place objects" });
  }
});

app.post("/api/public/events/theme-design/render-composite", async (req, res) => {
  try {
    const cleanedBase = sanitizeBase64Image(req.body?.baseImageBase64);
    const objectsRaw = Array.isArray(req.body?.objects) ? req.body.objects : [];
    const objects = objectsRaw
      .filter((obj: unknown) => obj && typeof obj === "object")
      .map((obj: unknown, idx: number) => {
        const o = obj as Record<string, unknown>;
        return {
          object_image_base64: String(o.objectImageBase64 ?? o.object_image_base64 ?? ""),
          x: Number(o.x ?? 0),
          y: Number(o.y ?? 0),
          width: Number(o.width ?? 120),
          height: Number(o.height ?? 120),
          rotation: Number(o.rotation ?? 0),
          z_index: Number(o.zIndex ?? o.z_index ?? idx),
          target_hex: o.targetHex ? ensureHexColor(o.targetHex) : null,
          intensity: Number(o.intensity ?? 1),
        };
      })
      .filter((o: { object_image_base64: string }) => Boolean(o.object_image_base64));
    const fast = await callAiService(
      "/v1/edit/compose",
      { base_image_base64: cleanedBase, objects },
      AI_SERVICE_TIMEOUT_COMPOSE_MS,
    );
    res.json({ ok: true, imageBase64: String(fast.image_base64 ?? fast.imageBase64 ?? "") });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err instanceof Error ? err.message : "Failed to render composite" });
  }
});

app.post("/api/public/events/theme-design/add-by-prompt", async (req, res) => {
  try {
    const cleanedBase = sanitizeBase64Image(req.body?.baseImageBase64);
    const prompt = String(req.body?.prompt ?? "").trim();
    if (!prompt) {
      res.status(400).json({ error: "prompt is required" });
      return;
    }
    const sourceQuery = buildPexelsQuery({
      eventTitle: req.body?.eventTitle,
      eventType: req.body?.eventType,
      formalityLevel: req.body?.formalityLevel,
      prompt,
      baseImageUrl: req.body?.baseImageUrl,
      forceNoPeople: true,
    });
    const pex = await fetchPexelsImages({ query: sourceQuery, perPage: 30, page: 1 });
    const sourceImages = (pex.images.length > 0 ? pex.images : sanitizeThemeSuggestions(fallbackThemeSuggestions)).slice(0, 10);
    const imageDownloads = await Promise.all(
      sourceImages.map(async (row) => {
        const url = String(row.imageUrl ?? "").trim();
        if (!url) return "";
        try {
          const dl = await fetch(url, { method: "GET" });
          if (!dl.ok) return "";
          const buf = Buffer.from(await dl.arrayBuffer());
          return buf.toString("base64");
        } catch {
          return "";
        }
      }),
    );
    const imagesBase64 = imageDownloads.filter((b) => b);
    if (imagesBase64.length === 0) {
      res.json({
        ok: true,
        usedFallback: true,
        error: pex.error || "No prompt images found.",
        imageBase64: cleanedBase,
        placements: [],
      });
      return;
    }

    let occupied: Array<{ left: number; top: number; width: number; height: number; label: string }> = [];
    try {
      const baseInfo = await callAiService(
        "/v1/infer/yolo-sam",
        {
          image_base64: cleanedBase,
          confidence_threshold: 0.35,
          max_detections: 20,
          mask_format: "polygon",
        },
        AI_SERVICE_TIMEOUT_ADD_BY_PROMPT_MS,
      );
      occupied = (Array.isArray(baseInfo.objects) ? baseInfo.objects : []).map((obj: unknown) => {
        const o = obj as Record<string, unknown>;
        const box = (o.box ?? {}) as Record<string, unknown>;
        return {
          left: Number(box.x ?? box.left ?? 0),
          top: Number(box.y ?? box.top ?? 0),
          width: Number(box.width ?? 0),
          height: Number(box.height ?? 0),
          label: String(o.label ?? "Object"),
        };
      });
    } catch {
      occupied = [];
    }

    const freeSpaces: Array<{ left: number; top: number; width: number; height: number }> = [];
    const grid = 3;
    for (let row = 0; row < grid; row++) {
      for (let col = 0; col < grid; col++) {
        const left = col / grid;
        const top = row / grid;
        const width = 1 / grid;
        const height = 1 / grid;
        const overlaps = occupied.some((box) => {
          const xOverlap = Math.max(0, Math.min(left + width, box.left + box.width) - Math.max(left, box.left));
          const yOverlap = Math.max(0, Math.min(top + height, box.top + box.height) - Math.max(top, box.top));
          return xOverlap * yOverlap > 0.02;
        });
        if (!overlaps) freeSpaces.push({ left, top, width, height });
      }
    }

    const extractedGroups: Array<{ id: string; label: string; objectImageBase64: string }> = [];
    for (let i = 0; i < imagesBase64.length; i++) {
      try {
        const fast = await callAiService(
          "/v1/infer/yolo-sam-extract",
          {
            image_base64: imagesBase64[i],
            confidence_threshold: 0.35,
            max_detections: 20,
            mask_format: "alpha_png",
          },
          AI_SERVICE_TIMEOUT_ADD_BY_PROMPT_MS,
        );
        const objects = Array.isArray(fast.objects)
          ? fast.objects.map((obj: unknown, idx: number) => {
              const o = obj as Record<string, unknown>;
              return {
                id: String(o.id ?? o.object_id ?? `obj_${i}_${idx}`),
                label: String(o.label ?? "Object"),
                objectImageBase64: String(o.object_image_base64 ?? o.objectImageBase64 ?? ""),
              };
            })
          : [];
        extractedGroups.push(...objects.filter((o) => o.objectImageBase64));
      } catch {
        // Skip failed source and continue.
      }
    }

    let usedSourceImageFallback = false;
    if (extractedGroups.length === 0) {
      usedSourceImageFallback = true;
      for (let i = 0; i < Math.min(imagesBase64.length, 6); i++) {
        extractedGroups.push({
          id: `fallback_source_${i}`,
          label: "Source image",
          objectImageBase64: String(imagesBase64[i] ?? ""),
        });
      }
    }
    if (extractedGroups.length === 0) {
      res.status(422).json({ error: "No objects extracted from prompt sources" });
      return;
    }

    const placements = extractedGroups.map((obj, idx) => {
      const slot = freeSpaces[idx % Math.max(1, freeSpaces.length)] ?? {
        left: 0.1 + ((idx % 3) * 0.25),
        top: 0.2 + ((idx % 2) * 0.25),
        width: 0.25,
        height: 0.25,
      };
      return {
        objectImageBase64: obj.objectImageBase64,
        x: Number(slot.left ?? 0),
        y: Number(slot.top ?? 0),
        width: Number(slot.width ?? 0.25),
        height: Number(slot.height ?? 0.25),
        rotation: 0,
        zIndex: idx,
        intensity: 1.0,
        targetHex: null,
      };
    });

    const composeResp = await callAiService(
      "/v1/edit/compose",
      {
        base_image_base64: cleanedBase,
        objects: placements.map((o) => ({
          object_image_base64: o.objectImageBase64,
          x: o.x,
          y: o.y,
          width: o.width,
          height: o.height,
          rotation: o.rotation,
          z_index: o.zIndex,
          intensity: o.intensity,
          target_hex: o.targetHex,
        })),
      },
      AI_SERVICE_TIMEOUT_COMPOSE_MS,
    );

    res.json({
      ok: true,
      imageBase64: String(composeResp.image_base64 ?? composeResp.imageBase64 ?? ""),
      placements,
      images: sourceImages,
      usedSourceImageFallback,
    });
  } catch (err) {
    console.error(err);
    let safeBase = "";
    try {
      safeBase = sanitizeBase64Image(req.body?.baseImageBase64);
    } catch {
      safeBase = "";
    }
    res.json({
      ok: true,
      usedFallback: true,
      error: err instanceof Error ? err.message : "Failed to add objects by prompt",
      imageBase64: safeBase,
      placements: [],
      images: fallbackThemeSuggestions.slice(0, 6),
    });
  }
});

app.get("/api/mobile/inquiries", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    await ensureNewEventSchemaOnce();
    const { rows } = await getPool().query(
      `SELECT * FROM (
         SELECT id::text AS id,
              ('INQ-' || UPPER(SUBSTRING(id::text, 1, 8))) AS inquiry_no,
              ${EVENT_TRANSACTION_ID} AS transaction_no,
              'CATERING AND EVENT' AS inquiry_type,
              COALESCE(event_title, '') AS event_title,
              COALESCE(event_type, '') AS event_type,
              customer_name AS customer,
              contact_person,
              contact_number,
              email_address AS inquiry_email,
              CASE
                WHEN jsonb_typeof(schedule_slots) = 'array' AND jsonb_array_length(schedule_slots) > 0
                  THEN schedule_slots::text
                ELSE ''
              END AS date_of_event,
              COALESCE((${POST_ANALYSIS_JSON})->>'note', '') AS note,
              FALSE AS curate_own_menu,
              '' AS selected_set_menu,
              menu AS selected_dishes,
              TRUE AS include_event_theme,
              guest_count,
              '' AS menu_suggestion_note,
              '' AS theme_suggestion_note,
              COALESCE(total_cost, 0) AS estimated_total,
              COALESCE(down_payment_amount, 0)::float8 AS down_payment_amount,
              COALESCE(full_payment_amount, 0)::float8 AS full_payment_amount,
              CASE
                WHEN LOWER(TRIM(status)) IN ('for_full_payment', 'completed')
                  THEN FLOOR(COALESCE(total_cost, 0)::numeric / ${CATERING_LOYALTY_STEP_AMOUNT}::numeric)::int * ${CATERING_LOYALTY_STEP_POINTS}
                ELSE 0
              END AS loyalty_points_earned,
              status, ${CATERING_ORDER_CREATED_AT_SQL} AS created_at,
              address AS event_city,
              COALESCE(NULLIF(TRIM(theme_design->>'event_setting'), ''), '') AS event_setting,
              '' AS service_included,
              COALESCE(formality_level, '') AS formality_level,
              FALSE AS food_tasting_requested,
              COALESCE(theme_design, '{}'::jsonb) AS theme_design,
              COALESCE(seating_plan, '{}'::jsonb) AS seating_plan,
              COALESCE(NULLIF(TRIM(order_type), ''), 'catering_event') AS order_type,
              'event'::text AS order_kind
         FROM event_orders
         WHERE LOWER(TRIM(email_address)) = LOWER(TRIM($1))
            OR EXISTS (
              SELECT 1 FROM customer_accounts ca
              WHERE LOWER(TRIM(ca.email)) = LOWER(TRIM($1))
                AND ca.customer_id IS NOT NULL
                AND TRIM(ca.customer_id::text) <> ''
                AND TRIM(ca.customer_id::text) = TRIM(COALESCE(event_orders.customer_id::text, ''))
            )
         UNION ALL
         SELECT id::text AS id,
                ('INQ-' || UPPER(SUBSTRING(id::text, 1, 8))) AS inquiry_no,
                ${CATERING_TRANSACTION_ID} AS transaction_no,
                'CATERING' AS inquiry_type,
                '' AS event_title,
                '' AS event_type,
                customer_name AS customer,
                contact_person,
                contact_number,
                email_address AS inquiry_email,
                CASE
                  WHEN jsonb_typeof(schedule_slots) = 'array' AND jsonb_array_length(schedule_slots) > 0
                    THEN schedule_slots::text
                  ELSE ''
                END AS date_of_event,
                COALESCE((${POST_ANALYSIS_JSON})->>'note', '') AS note,
                FALSE AS curate_own_menu,
                '' AS selected_set_menu,
                menu AS selected_dishes,
                FALSE AS include_event_theme,
                guest_count,
                '' AS menu_suggestion_note,
                '' AS theme_suggestion_note,
                COALESCE(total_cost, 0) AS estimated_total,
                COALESCE(down_payment_amount, 0)::float8 AS down_payment_amount,
                COALESCE(full_payment_amount, 0)::float8 AS full_payment_amount,
                CASE
                  WHEN LOWER(TRIM(status)) IN ('for_full_payment', 'completed')
                  THEN FLOOR(COALESCE(total_cost, 0)::numeric / ${CATERING_LOYALTY_STEP_AMOUNT}::numeric)::int * ${CATERING_LOYALTY_STEP_POINTS}
                ELSE 0
              END AS loyalty_points_earned,
              status, ${CATERING_ORDER_CREATED_AT_SQL} AS created_at,
              address AS event_city,
              COALESCE(NULLIF(TRIM(event_setting), ''), '') AS event_setting,
                '' AS service_included,
                COALESCE(NULLIF(TRIM(formality_level), ''), '') AS formality_level,
                FALSE AS food_tasting_requested,
                '{}'::jsonb AS theme_design,
                '{}'::jsonb AS seating_plan,
                'catering'::text AS order_type,
                'catering'::text AS order_kind
         FROM catering_orders
         WHERE LOWER(TRIM(email_address)) = LOWER(TRIM($1))
            OR EXISTS (
              SELECT 1 FROM customer_accounts ca
              WHERE LOWER(TRIM(ca.email)) = LOWER(TRIM($1))
                AND ca.customer_id IS NOT NULL
                AND TRIM(ca.customer_id::text) <> ''
                AND TRIM(ca.customer_id::text) = TRIM(COALESCE(catering_orders.customer_id::text, ''))
            )
       ) q
       ORDER BY created_at DESC`,
      [userEmail],
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/inquiries", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  const inquiryType = String(req.body?.inquiry_type ?? "CATERING").trim().toUpperCase();
  if (!["CATERING", "CATERING AND EVENT"].includes(inquiryType)) {
    res.status(400).json({ error: "inquiry_type must be CATERING or CATERING AND EVENT" });
    return;
  }
  const eventTitle = String(req.body?.event_title ?? "").trim();
  const eventType = String(req.body?.event_type ?? "").trim();
  const customer = String(req.body?.customer ?? "").trim();
  const contactPerson = String(req.body?.contact_person ?? "").trim();
  const contactNumber = String(req.body?.contact_number ?? "").trim();
  const inquiryEmail = String(req.body?.inquiry_email ?? "").trim().toLowerCase();
  const dateOfEvent = String(req.body?.date_of_event ?? "").trim();
  const note = String(req.body?.note ?? "").trim();
  const serviceIncluded =
    String(req.body?.service_included ?? "no").trim().toLowerCase() === "yes" ? "yes" : "no";
  const selectedDishes = Array.isArray(req.body?.selected_dishes) ? req.body.selected_dishes : [];
  const guestCountRaw = Number(req.body?.guest_count ?? NaN);
  const guestCount = Number.isFinite(guestCountRaw) ? Math.max(0, Math.floor(guestCountRaw)) : 0;
  const estimatedTotal = Number(req.body?.estimated_total ?? 0);
  const eventCity = String(req.body?.event_city ?? "").trim();
  const formalityLevel = String(req.body?.formality_level ?? "").trim();
  const eventSetting = String(req.body?.event_setting ?? "").trim();
  const curateOwnMenu = Boolean(req.body?.curate_own_menu);
  const foodTastingRequested = Boolean(req.body?.food_tasting_requested);
  const foodTastingDate = String(req.body?.food_tasting_date ?? "").trim();
  const foodTastingTime = String(req.body?.food_tasting_time ?? "").trim();

  if (!contactPerson) {
    res.status(400).json({ error: "contact_person is required" });
    return;
  }
  if (!contactNumber || contactNumber.length < 7 || !/^[0-9+\-\s()]+$/.test(contactNumber)) {
    res.status(400).json({ error: "valid contact_number is required" });
    return;
  }
  if (!inquiryEmail || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(inquiryEmail)) {
    res.status(400).json({ error: "valid inquiry_email is required" });
    return;
  }
  if (!eventCity) {
    res.status(400).json({ error: "event_city is required" });
    return;
  }
  const minGuests = inquiryType === "CATERING AND EVENT" ? CATERING_EVENT_MIN_GUESTS : CATERING_ONLY_MIN_GUESTS;
  const paxBufferRaw = Number(req.body?.pax_buffer ?? 0);
  const paxBuffer = Number.isFinite(paxBufferRaw) ? Math.max(0, Math.floor(paxBufferRaw)) : 0;
  if (guestCount < minGuests) {
    res.status(400).json({ error: `minimum guests for ${inquiryType} is ${minGuests}` });
    return;
  }
  if (curateOwnMenu && selectedDishes.length < 1) {
    res.status(400).json({ error: "select at least one dish for curate_own_menu" });
    return;
  }
  if (!eventType) {
    res.status(400).json({ error: "event_type is required" });
    return;
  }
  if (inquiryType === "CATERING AND EVENT" && !eventTitle) {
    res.status(400).json({ error: "event_title is required for CATERING AND EVENT" });
    return;
  }
  if (foodTastingRequested && (!foodTastingDate || !foodTastingTime)) {
    res.status(400).json({ error: "food_tasting_date and food_tasting_time are required when food tasting is requested" });
    return;
  }
  let scheduleSlots: unknown[] = [];
  if (dateOfEvent.startsWith("[")) {
    try {
      const parsed = JSON.parse(dateOfEvent);
      if (Array.isArray(parsed)) scheduleSlots = parsed;
    } catch {
      scheduleSlots = [];
    }
  }
  if (scheduleSlots.length === 0 && dateOfEvent) {
    scheduleSlots = [{ label: dateOfEvent }];
  }
  if (scheduleSlots.length < 1) {
    res.status(400).json({ error: "at least one schedule slot is required" });
    return;
  }
  for (const rawSlot of scheduleSlots) {
    const slot = rawSlot && typeof rawSlot === "object" ? (rawSlot as Record<string, unknown>) : null;
    if (!slot) {
      res.status(400).json({ error: "each schedule slot must be an object" });
      return;
    }
    const date = String(slot.date ?? "").trim();
    const from = String(slot.from ?? "").trim();
    const to = String(slot.to ?? "").trim();
    if (!date || !from || !to) {
      res.status(400).json({ error: "each schedule slot must include date, from, and to" });
      return;
    }
    const dateOk = /^\d{4}-\d{2}-\d{2}$/.test(date);
    const timeOk = /^\d{2}:\d{2}$/.test(from) && /^\d{2}:\d{2}$/.test(to);
    if (!dateOk || !timeOk) {
      res.status(400).json({ error: "schedule slot date/time format is invalid" });
      return;
    }
    const fromMinutes = Number(from.slice(0, 2)) * 60 + Number(from.slice(3, 5));
    const toMinutes = Number(to.slice(0, 2)) * 60 + Number(to.slice(3, 5));
    if (!Number.isFinite(fromMinutes) || !Number.isFinite(toMinutes) || toMinutes <= fromMinutes) {
      res.status(400).json({ error: "schedule slot end time must be after start time" });
      return;
    }
  }
  try {
    const cateringOnly = inquiryType.trim().toUpperCase() == "CATERING";
    const customerId = (await customerBusinessIdForEmail(inquiryEmail)) ?? "";
    const txNo = await nextTransactionNo(cateringOnly ? "catering" : "event");
    const paymentMethod = String(req.body?.payment_method ?? "cash").trim().toLowerCase();
    const menuJson = JSON.stringify(selectedDishes);
    const autoChecklist = await generateChecklistFromMenu(selectedDishes);
    const costBreakdown = Array.isArray(req.body?.cost_breakdown) ? req.body.cost_breakdown : [];
    const laborCost = toNum(req.body?.labor_cost, 0);
    const travelCost = toNum(req.body?.travel_cost, 0);
    const themeFromClient =
      req.body?.theme_design != null && typeof req.body.theme_design === "object"
        ? (req.body.theme_design as Record<string, unknown>)
        : {};
    const guestAllergens = Array.isArray(req.body?.guest_allergens)
      ? (req.body.guest_allergens as unknown[])
          .map((x) => String(x ?? "").trim())
          .filter((s) => s.length > 0)
      : [];
    const themeDesignMerged: Record<string, unknown> = {
      inquiry_type: inquiryType,
      service_included: serviceIncluded,
      event_setting: eventSetting,
      ...(guestAllergens.length > 0 ? { guest_allergens: guestAllergens } : {}),
      ...themeFromClient,
    };
    if (!String(themeDesignMerged.note ?? "").trim() && note.trim()) {
      themeDesignMerged.note = note.trim();
    }
    const themeDesignJson = JSON.stringify(themeDesignMerged);
    const seatingPlanJson = JSON.stringify({});
    const sql = cateringOnly
      ? `INSERT INTO catering_orders
         (source, status, order_type, customer_name, contact_person, contact_number, email_address,
          schedule_slots, address, guest_count, pax_buffer, menu, event_title, event_type, formality_level, event_setting, checklist,
          total_cost, customer_id, catering_id, payment_method, cost_breakdown, labor_cost, travel_cost, full_payment_due_at)
         VALUES
         ('online_inquiry', 'online_inquiries', 'catering', $1, $2, $3, $4, $5::jsonb, $6, $7, $8, $9::jsonb, $10, $11, $12, $13, $14::jsonb, $15, $16, $17, $18, $19, $20::jsonb, $21, $22, $23)
         RETURNING id::text`
      : `INSERT INTO event_orders
         (source, status, order_type, event_title, event_type, formality_level, customer_name, contact_person, contact_number,
          email_address, schedule_slots, address, guest_count, pax_buffer, menu, theme_design, seating_plan, checklist,
          total_cost, customer_id, event_id, payment_method, cost_breakdown, labor_cost, travel_cost, full_payment_due_at)
         VALUES
         ('online_inquiry', 'online_inquiries', 'catering_event', $1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11, $12::jsonb, $13::jsonb, $14::jsonb, $15::jsonb, $16, $17, $18, $19, $20::jsonb, $21, $22, $23)
         RETURNING id::text`;
    const params = cateringOnly
      ? [
          customer || contactPerson,
          contactPerson,
          contactNumber,
          inquiryEmail,
          JSON.stringify(scheduleSlots),
          eventCity,
          guestCount,
          paxBuffer,
          menuJson,
          eventTitle.trim(),
          eventType.trim(),
          formalityLevel.trim(),
          eventSetting,
          JSON.stringify({
            items: autoChecklist,
            post_analysis: {
              note,
              inquiry_type: inquiryType,
              service_included: serviceIncluded,
              pax_buffer: paxBuffer,
              ...(guestAllergens.length > 0 ? { guest_allergens: guestAllergens } : {}),
            },
          }),
          estimatedTotal + laborCost + travelCost,
          customerId || null,
          txNo,
          paymentMethod,
          JSON.stringify(costBreakdown),
          laborCost,
          travelCost,
          scheduleSlots.length > 0 ? new Date().toISOString() : null,
        ]
      : [
          eventTitle,
          eventType,
          formalityLevel,
          customer || contactPerson,
          contactPerson,
          contactNumber,
          inquiryEmail,
          JSON.stringify(scheduleSlots),
          eventCity,
          guestCount,
          paxBuffer,
          menuJson,
          themeDesignJson,
          seatingPlanJson,
          JSON.stringify({
            items: autoChecklist,
            post_analysis: {
              note,
              inquiry_type: inquiryType,
              pax_buffer: paxBuffer,
              ...(guestAllergens.length > 0 ? { guest_allergens: guestAllergens } : {}),
            },
          }),
          estimatedTotal + laborCost + travelCost,
          customerId || null,
          txNo,
          paymentMethod,
          JSON.stringify(costBreakdown),
          laborCost,
          travelCost,
          scheduleSlots.length > 0 ? new Date().toISOString() : null,
        ];
    const { rows } = await getPool().query(sql, params);
    const id = String(rows[0].id);
    const inquiryNo = `INQ-${id.substring(0, 8).toUpperCase()}`;
    await logActionBestEffort("inquiry.submit", userEmail, `Inquiry submitted: ${inquiryNo}`, {
      inquiry_no: inquiryNo,
      inquiry_type: inquiryType,
    });
    void sendMailSafe(
      inquiryEmail,
      `Inquiry ${txNo} received`,
      `Thank you for contacting Macrina's Kitchen and Catering.\n\n` +
        `Your catering / catering+event inquiry has been submitted successfully.\n` +
        `Our team will review your request and you will be notified by email soon with next steps.\n\n` +
        `Transaction reference: ${txNo}\n` +
        `Inquiry id: ${inquiryNo}\n` +
        (eventTitle ? `Event: ${eventTitle}\n` : ""),
    );
    res.status(201).json({ id, inquiry_no: inquiryNo, transaction_no: txNo });
  } catch (err) {
    console.error(err);
    res.status(500).json({
      error: err instanceof Error ? err.message : "could not save inquiry — check database migrations",
    });
  }
});

app.post("/api/mobile/pos/catering/list", async (req, res) => {
  const staffEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const staffPassword = String(req.body?.cashier_password ?? "");
  const stage = String(req.body?.stage ?? "new_event").trim().toLowerCase();
  if (!staffEmail || !staffPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  const auth = await verifyPosStaff(staffEmail, staffPassword, ["manager", "supervisor"]);
  if (!auth.ok) {
    res.status(403).json({ error: "invalid manager/supervisor credentials" });
    return;
  }
  if (auth.role === "supervisor" && stage !== "for_ongoing" && mapManagerCateringStageToDb(stage) !== "for_ongoing") {
    res.status(403).json({ error: "supervisor can only access on-going orders" });
    return;
  }
  const canonicalStage = mapManagerCateringStageToDb(stage);
  const allowed = [
    "new_event",
    "online_inquiries",
    "for_down_payment",
    "for_ongoing",
    "for_full_payment",
    "completed",
    "cancelled",
  ];
  if (!allowed.includes(canonicalStage)) {
    res.status(400).json({ error: "invalid stage" });
    return;
  }
  const dbStatuses = cateringStatusesForApiStage(canonicalStage);
  /** When true, omit heavy JSON blobs so large stages (e.g. online_inquiries) load reliably; fetch full row via /catering/item. */
  const summary = Boolean(req.body?.summary);
  const fullPaymentStages = new Set(["for_full_payment"]);
  const pipelineWorkStages = new Set(["for_down_payment", "for_ongoing"]);
  try {
    await ensureNewEventSchemaOnce();
    const { rows } = await getPool().query(
      `SELECT * FROM (
         SELECT 'event'::text AS order_kind,
                id::text, source, status, order_type, customer_name, contact_person, contact_number, email_address,
              CASE
                WHEN ($2::boolean AND $1::text NOT IN ('for_down_payment', 'for_ongoing')) THEN '[]'::jsonb
                ELSE COALESCE(schedule_slots, '[]'::jsonb)
              END AS schedule_slots, address, guest_count, COALESCE(pax_buffer, 0) AS pax_buffer,
              CASE WHEN $2::boolean THEN '[]'::jsonb ELSE COALESCE(menu, '[]'::jsonb) END AS menu,
              CASE WHEN $2::boolean THEN '{}'::jsonb ELSE COALESCE(theme_design, '{}'::jsonb) END AS theme_design,
              CASE WHEN ($2::boolean AND $1::text <> 'for_full_payment') THEN '{}'::jsonb ELSE ${POST_ANALYSIS_JSON} END AS post_analysis,
              CASE WHEN $2::boolean THEN '[]'::jsonb ELSE COALESCE(checklist, '[]'::jsonb) END AS checklist,
              down_payment_amount, down_payment_status, full_payment_amount, full_payment_status,
                total_cost, ${CATERING_ORDER_CREATED_AT_SQL} AS created_at, ${CATERING_ORDER_UPDATED_AT_SQL} AS updated_at, stage_entered_at, event_title, event_type, formality_level,
                '[]'::jsonb AS actual_event_images,
                COALESCE(theme_design->>'service_included', '') AS service_included,
                ${EVENT_TRANSACTION_ID} AS transaction_no, payment_method,
                '[]'::jsonb AS cost_breakdown,
                labor_cost, travel_cost,
                CASE
                  WHEN $1::text IN ('new_event', 'online_inquiries')
                    THEN COALESCE(inquiry_additional_costs, '[]'::jsonb)
                  ELSE COALESCE(stage_additional_costs, '[]'::jsonb)
                END AS additional_costs,
                full_payment_due_at,
                COALESCE(NULLIF(TRIM(theme_design->>'event_setting'), ''), '') AS event_setting,
                (
                  CASE
                    WHEN schedule_slots IS NULL THEN ''
                    WHEN jsonb_typeof(schedule_slots::jsonb) <> 'array' OR COALESCE(jsonb_array_length(schedule_slots::jsonb), 0) < 1 THEN ''
                    ELSE TRIM(BOTH FROM CONCAT_WS(
                      ' · ',
                      NULLIF(TRIM(schedule_slots::jsonb->0->>'date'), ''),
                      NULLIF(TRIM(schedule_slots::jsonb->0->>'label'), ''),
                      CASE
                        WHEN NULLIF(TRIM(schedule_slots::jsonb->0->>'from'), '') IS NOT NULL THEN
                          TRIM(schedule_slots::jsonb->0->>'from') ||
                          CASE
                            WHEN NULLIF(TRIM(schedule_slots::jsonb->0->>'to'), '') IS NOT NULL THEN
                              '–' || TRIM(schedule_slots::jsonb->0->>'to')
                            ELSE ''
                          END
                        ELSE NULL
                      END
                    ))
                  END
                ) AS schedule_preview,
                COALESCE(loyalty_points_catering_obtained, 0) AS points_earned,
                (CASE
                  WHEN jsonb_typeof(COALESCE(checklist, '[]'::jsonb)) = 'array' THEN COALESCE(jsonb_array_length(checklist::jsonb), 0)
                  ELSE 0
                END) AS checklist_count_summary,
                NULLIF(TRIM(COALESCE((${POST_ANALYSIS_JSON})->>'processing_phase', '')), '') AS processing_phase_sk
         FROM event_orders
         WHERE status = ANY($3::text[])
       UNION ALL
         SELECT 'catering'::text AS order_kind,
                id::text, source, status, order_type, customer_name, contact_person, contact_number, email_address,
                CASE
                  WHEN ($2::boolean AND $1::text NOT IN ('for_down_payment', 'for_ongoing')) THEN '[]'::jsonb
                  ELSE COALESCE(schedule_slots, '[]'::jsonb)
                END AS schedule_slots, address, guest_count, COALESCE(pax_buffer, 0) AS pax_buffer,
                CASE WHEN $2::boolean THEN '[]'::jsonb ELSE COALESCE(menu, '[]'::jsonb) END AS menu,
                '{}'::jsonb AS theme_design,
                CASE WHEN ($2::boolean AND $1::text <> 'for_full_payment') THEN '{}'::jsonb ELSE ${POST_ANALYSIS_JSON} END AS post_analysis,
                CASE WHEN $2::boolean THEN '[]'::jsonb ELSE COALESCE(checklist, '[]'::jsonb) END AS checklist,
                down_payment_amount, down_payment_status, full_payment_amount, full_payment_status,
                total_cost, ${CATERING_ORDER_CREATED_AT_SQL} AS created_at, ${CATERING_ORDER_UPDATED_AT_SQL} AS updated_at, stage_entered_at,
                COALESCE(event_title, '') AS event_title,
                COALESCE(event_type, '') AS event_type,
                COALESCE(formality_level, '') AS formality_level,
                '[]'::jsonb AS actual_event_images,
                COALESCE(event_setting, '') AS service_included,
                ${CATERING_TRANSACTION_ID} AS transaction_no, payment_method,
                '[]'::jsonb AS cost_breakdown,
                labor_cost, travel_cost,
                CASE
                  WHEN $1::text IN ('new_event', 'online_inquiries')
                    THEN COALESCE(inquiry_additional_costs, '[]'::jsonb)
                  ELSE COALESCE(stage_additional_costs, '[]'::jsonb)
                END AS additional_costs,
                full_payment_due_at,
                COALESCE(NULLIF(TRIM(event_setting), ''), '') AS event_setting,
                (
                  CASE
                    WHEN schedule_slots IS NULL THEN ''
                    WHEN jsonb_typeof(schedule_slots::jsonb) <> 'array' OR COALESCE(jsonb_array_length(schedule_slots::jsonb), 0) < 1 THEN ''
                    ELSE TRIM(BOTH FROM CONCAT_WS(
                      ' · ',
                      NULLIF(TRIM(schedule_slots::jsonb->0->>'date'), ''),
                      NULLIF(TRIM(schedule_slots::jsonb->0->>'label'), ''),
                      CASE
                        WHEN NULLIF(TRIM(schedule_slots::jsonb->0->>'from'), '') IS NOT NULL THEN
                          TRIM(schedule_slots::jsonb->0->>'from') ||
                          CASE
                            WHEN NULLIF(TRIM(schedule_slots::jsonb->0->>'to'), '') IS NOT NULL THEN
                              '–' || TRIM(schedule_slots::jsonb->0->>'to')
                            ELSE ''
                          END
                        ELSE NULL
                      END
                    ))
                  END
                ) AS schedule_preview,
                COALESCE(loyalty_points_catering_obtained, 0) AS points_earned,
                (CASE
                  WHEN jsonb_typeof(COALESCE(checklist, '[]'::jsonb)) = 'array' THEN COALESCE(jsonb_array_length(checklist::jsonb), 0)
                  ELSE 0
                END) AS checklist_count_summary,
                NULLIF(TRIM(COALESCE((${POST_ANALYSIS_JSON})->>'processing_phase', '')), '') AS processing_phase_sk
         FROM catering_orders
         WHERE status = ANY($3::text[])
       ) q
       ORDER BY created_at DESC`,
      [canonicalStage, summary, dbStatuses],
    );
    if (pipelineWorkStages.has(canonicalStage) || fullPaymentStages.has(canonicalStage) || canonicalStage === "completed") {
      for (const r of rows as Array<Record<string, unknown>>) {
        const existingChecklist = normalizeChecklist(r.checklist);
        const checklistRaw = r.checklist;
        const hasEditorShape =
          checklistRaw != null &&
          typeof checklistRaw === "object" &&
          !Array.isArray(checklistRaw) &&
          "items" in (checklistRaw as Record<string, unknown>);
        if (existingChecklist.length > 0 || hasEditorShape) continue;
        const autoChecklist = await generateChecklistFromMenu(r.menu);
        if (autoChecklist.length == 0) continue;
        const table = String(r.order_kind) === "catering" ? "catering_orders" : "event_orders";
        const id = String(r.id ?? "").trim();
        if (!id) continue;
        const packed = packChecklistWithPost(autoChecklist, null, r.checklist);
        await getPool().query(`UPDATE ${table} SET checklist = $2::jsonb WHERE id::text = $1`, [
          id,
          JSON.stringify(packed ?? { items: autoChecklist }),
        ]);
        r.checklist = packed ?? { items: autoChecklist };
      }
    }
    if (canonicalStage === "for_down_payment" || canonicalStage === "for_ongoing") {
      attachForProcessingScheduleOverlaps(rows as Array<Record<string, unknown>>);
    }
    for (const row of rows as Array<Record<string, unknown>>) {
      row.status = normalizeCateringStatusForApi(String(row.status ?? ""), row);
      enrichCateringThemeDesignForApi(row);
      if (!summary) row.checklist = normalizeChecklist(row.checklist);
    }
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/pos/catering/item", async (req, res) => {
  const staffEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const staffPassword = String(req.body?.cashier_password ?? "");
  const id = String(req.body?.id ?? "").trim();
  const orderKind = String(req.body?.order_kind ?? "").trim().toLowerCase();
  if (!staffEmail || !staffPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  if (!id || (orderKind !== "catering" && orderKind !== "event")) {
    res.status(400).json({ error: "id and order_kind (catering|event) are required" });
    return;
  }
  if (!(await verifyPosStaff(staffEmail, staffPassword, ["manager", "supervisor"])).ok) {
    res.status(403).json({ error: "invalid manager/supervisor credentials" });
    return;
  }
  try {
    await ensureNewEventSchemaOnce();
    const fullSelectEvent = `
      SELECT 'event'::text AS order_kind,
             id::text, source, status, order_type, customer_name, contact_person, contact_number, email_address,
             schedule_slots, address, guest_count, menu, theme_design, COALESCE(seating_plan, '{}'::jsonb) AS seating_plan,
             ${POST_ANALYSIS_JSON} AS post_analysis, checklist,
             down_payment_amount, down_payment_status, full_payment_amount, full_payment_status,
             total_cost, ${CATERING_ORDER_CREATED_AT_SQL} AS created_at, ${CATERING_ORDER_UPDATED_AT_SQL} AS updated_at, stage_entered_at, event_title, event_type, formality_level,
             '[]'::jsonb AS actual_event_images,
             COALESCE(theme_design->>'service_included', '') AS service_included,
             ${EVENT_TRANSACTION_ID} AS transaction_no, payment_method, '[]'::jsonb AS cost_breakdown, labor_cost, travel_cost,
             COALESCE(stage_additional_costs, '[]'::jsonb) AS additional_costs, full_payment_due_at,
             COALESCE(loyalty_points_catering_obtained, 0) AS points_earned
      FROM event_orders WHERE id::text = $1`;
    const fullSelectCatering = `
      SELECT 'catering'::text AS order_kind,
             id::text, source, status, order_type, customer_name, contact_person, contact_number, email_address,
             schedule_slots, address, guest_count, menu, ${POST_ANALYSIS_JSON} AS post_analysis, checklist,
             down_payment_amount, down_payment_status, full_payment_amount, full_payment_status,
             total_cost, ${CATERING_ORDER_CREATED_AT_SQL} AS created_at, ${CATERING_ORDER_UPDATED_AT_SQL} AS updated_at, stage_entered_at,
             COALESCE(event_title, '') AS event_title,
             COALESCE(event_type, '') AS event_type,
             COALESCE(formality_level, '') AS formality_level,
             '[]'::jsonb AS actual_event_images,
             COALESCE(event_setting, '') AS service_included,
             ${CATERING_TRANSACTION_ID} AS transaction_no, payment_method, '[]'::jsonb AS cost_breakdown, labor_cost, travel_cost,
             COALESCE(stage_additional_costs, '[]'::jsonb) AS additional_costs, full_payment_due_at,
             COALESCE(loyalty_points_catering_obtained, 0) AS points_earned
      FROM catering_orders WHERE id::text = $1`;
    const { rows } = await getPool().query(orderKind === "event" ? fullSelectEvent : fullSelectCatering, [id]);
    if (rows.length === 0) {
      res.status(404).json({ error: "not found" });
      return;
    }
    const r = rows[0] as Record<string, unknown>;
    const st = String(r.status ?? "").trim().toLowerCase();
    const stNormItem = normalizeCateringStatusForApi(st, r);
    if (
      stNormItem === "for_down_payment" ||
      stNormItem === "for_ongoing" ||
      stNormItem === "for_full_payment" ||
      stNormItem === "completed"
    ) {
      const existingChecklist = normalizeChecklist(r.checklist);
      const checklistRaw = r.checklist;
      const hasEditorShape =
        checklistRaw != null &&
        typeof checklistRaw === "object" &&
        !Array.isArray(checklistRaw) &&
        "items" in (checklistRaw as Record<string, unknown>);
      if (existingChecklist.length === 0 && !hasEditorShape) {
        const autoChecklist = await generateChecklistFromMenu(r.menu);
        if (autoChecklist.length > 0) {
          const table = orderKind === "catering" ? "catering_orders" : "event_orders";
          const packed = packChecklistWithPost(autoChecklist, null, r.checklist);
          await getPool().query(`UPDATE ${table} SET checklist = $2::jsonb WHERE id::text = $1`, [
            id,
            JSON.stringify(packed ?? { items: autoChecklist }),
          ]);
          r.checklist = packed ?? { items: autoChecklist };
        }
      }
    }
    enrichCateringThemeDesignForApi(r);
    const stNorm = normalizeCateringStatusForApi(st, r);
    if (stNorm === "for_down_payment" || stNorm === "for_ongoing") {
      const { rows: fpRows } = await getPool().query(
        `SELECT 'event'::text AS order_kind, id::text, schedule_slots FROM event_orders
         WHERE status IN (${CATERING_ACTIVE_SCHEDULE_STATUSES_SQL})
         UNION ALL
         SELECT 'catering'::text, id::text, schedule_slots FROM catering_orders
         WHERE status IN (${CATERING_ACTIVE_SCHEDULE_STATUSES_SQL})`,
      );
      attachForProcessingScheduleOverlaps(fpRows as Array<Record<string, unknown>>);
      const me = (fpRows as Array<Record<string, unknown> & { id?: string; processing_schedule_overlaps?: number }>).find(
        (x) => String(x.id) === id,
      );
      r.processing_schedule_overlaps = Number(me?.processing_schedule_overlaps ?? 0);
    }
    r.status = normalizeCateringStatusForApi(String(r.status ?? ""), r);
    r.checklist = normalizeChecklist(r.checklist);
    res.json(r);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/pos/catering/new-event", async (req, res) => {
  const staffEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const staffPassword = String(req.body?.cashier_password ?? "");
  if (!staffEmail || !staffPassword) {
    res.status(400).json({ error: "cashier_email and cashier_password are required" });
    return;
  }
  const auth = await verifyPosStaff(staffEmail, staffPassword, ["manager", "supervisor"]);
  if (!auth.ok) {
    res.status(403).json({ error: "invalid manager/supervisor credentials" });
    return;
  }
  if (auth.role !== "manager") {
    res.status(403).json({ error: "supervisor cannot create new events" });
    return;
  }
  const orderKind = String(req.body?.order_kind ?? "event").trim().toLowerCase();
  const guestCount = Math.max(0, Number(req.body?.guest_count ?? 0));
  const paxBufferRaw = Number(req.body?.pax_buffer ?? 0);
  const paxBuffer = Number.isFinite(paxBufferRaw) ? Math.max(0, Math.floor(paxBufferRaw)) : 0;
  const paymentMethod = String(req.body?.payment_method ?? "cash").trim().toLowerCase();
  const costBreakdown = Array.isArray(req.body?.cost_breakdown) ? req.body.cost_breakdown : [];
  const laborMale = Math.max(0, toNum(req.body?.labor_male_count, 0));
  const laborFemale = Math.max(0, toNum(req.body?.labor_female_count, 0));
  const laborException = toNum(req.body?.labor_manual_exception, 0);
  const manualTotalCost = toNum(req.body?.manual_total_cost, NaN);
  const travelCost = Math.max(0, toNum(req.body?.travel_cost, 0));
  const baseCost = guestCount * 500;
  const laborCost = laborMale * 1000 + laborFemale * 500 + laborException;
  const totalCost = Number.isFinite(manualTotalCost) ? manualTotalCost : baseCost + laborCost + travelCost;
  const txNo = await nextTransactionNo(orderKind === "catering" ? "catering" : "event");
  const scheduleSlotsRaw = Array.isArray(req.body?.schedule_slots) ? (req.body.schedule_slots as unknown[]) : [];
  const scheduleSlots = scheduleSlotsRaw
    .map((entry) => {
      let obj: Record<string, unknown> | null = null;
      if (entry && typeof entry === "object" && !Array.isArray(entry)) {
        obj = entry as Record<string, unknown>;
      } else if (typeof entry === "string") {
        const t = entry.trim();
        if (t.startsWith("{") && t.endsWith("}")) {
          try {
            const parsed = JSON.parse(t);
            if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
              obj = parsed as Record<string, unknown>;
            }
          } catch {
            obj = null;
          }
        }
      }
      if (!obj) return null;
      const date = String(obj.date ?? "").trim();
      const from = String(obj.from ?? "").trim();
      const to = String(obj.to ?? "").trim();
      const labelRaw = String(obj.label ?? "").trim();
      const label = labelRaw || [date, from && to ? `from ${from} to ${to}` : ""].filter(Boolean).join(" ");
      return { date, from, to, label };
    })
    .filter((x): x is { date: string; from: string; to: string; label: string } => x != null);
  const menuArr = Array.isArray(req.body?.menu) ? req.body.menu : [];
  const themeDesign =
    req.body?.theme_design != null && typeof req.body.theme_design === "object" ? req.body.theme_design : {};
  const seatingPlanRaw = req.body?.seating_plan;
  const seatingPlanJson =
    seatingPlanRaw != null && typeof seatingPlanRaw === "object" && !Array.isArray(seatingPlanRaw)
      ? JSON.stringify(normalizeSeatingPlan(seatingPlanRaw))
      : null;
  const payload = {
    source: "new_event",
    status: "new_event",
    order_type: orderKind === "catering" ? "catering" : "catering_event",
    customer_name: String(req.body?.customer_name ?? "").trim(),
    contact_person: String(req.body?.contact_person ?? "").trim(),
    contact_number: String(req.body?.contact_number ?? "").trim(),
    email_address: String(req.body?.email_address ?? "").trim(),
    schedule_slots: scheduleSlots,
    address: String(req.body?.address ?? "").trim(),
    guest_count: guestCount,
    menu: menuArr,
    theme_design: themeDesign,
    event_title: String(req.body?.event_title ?? "").trim(),
    event_type: String(req.body?.event_type ?? "").trim(),
    formality_level: String(req.body?.formality_level ?? "").trim(),
    total_cost: totalCost,
    created_by: staffEmail,
    customer_id: String(req.body?.customer_id ?? "").trim(),
  };
  try {
    await ensureNewEventSchemaOnce();
    const autoChecklist = await generateChecklistFromMenu(menuArr);
    const checklistPacked = packChecklistWithPost(autoChecklist, { pax_buffer: paxBuffer }, null);
    const scheduleJson = JSON.stringify(payload.schedule_slots ?? []);
    const menuJson = JSON.stringify(menuArr);
    const themeJson = JSON.stringify(themeDesign ?? {});
    const sql =
      orderKind === "catering"
        ? `INSERT INTO catering_orders
           (source, status, order_type, customer_name, contact_person, contact_number, email_address,
            schedule_slots, address, guest_count, pax_buffer, menu, event_setting, formality_level, checklist,
            total_cost, created_by, updated_by, customer_id, catering_id, payment_method, cost_breakdown, labor_cost, travel_cost, full_payment_due_at)
           VALUES
           ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11, $12::jsonb, $13::jsonb, $14, $15::jsonb, $16, $17, $17, NULLIF($18, ''), $19, $20, $21::jsonb, $22, $23, $24)
           RETURNING id::text`
        : `INSERT INTO event_orders
           (source, status, order_type, customer_name, contact_person, contact_number, email_address,
            schedule_slots, address, guest_count, pax_buffer, menu, theme_design, seating_plan, event_title, event_type, formality_level, checklist,
            total_cost, created_by, updated_by, customer_id, event_id, payment_method, cost_breakdown, labor_cost, travel_cost, full_payment_due_at)
           VALUES
           ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11, $12::jsonb, $13::jsonb, COALESCE($14::jsonb, '{}'::jsonb), $15, $16, $17, $18::jsonb, $19, $20, $21, NULLIF($22, ''), $23, $24, $25::jsonb, $26, $27, $28)
           RETURNING id::text`;
    const params =
      orderKind === "catering"
        ? [
            payload.source,
            payload.status,
            payload.order_type,
            payload.customer_name,
            payload.contact_person,
            payload.contact_number,
            payload.email_address,
            scheduleJson,
            payload.address,
            payload.guest_count,
            paxBuffer,
            menuJson,
            String((themeDesign as Record<string, unknown>)?.event_setting ?? "").trim(),
            payload.formality_level,
            JSON.stringify(
              packChecklistWithPost(
                autoChecklist,
                mergeThemeDesignIntoPostAnalysis({ pax_buffer: paxBuffer }, themeDesign),
                null,
              ) ?? { items: autoChecklist },
            ),
            payload.total_cost,
            payload.created_by,
            payload.customer_id,
            txNo,
            paymentMethod,
            JSON.stringify(costBreakdown),
            laborCost,
            travelCost,
            new Date().toISOString(),
          ]
        : [
            payload.source,
            payload.status,
            payload.order_type,
            payload.customer_name,
            payload.contact_person,
            payload.contact_number,
            payload.email_address,
            scheduleJson,
            payload.address,
            payload.guest_count,
            paxBuffer,
            menuJson,
            themeJson,
            seatingPlanJson,
            payload.event_title,
            payload.event_type,
            payload.formality_level,
            JSON.stringify(checklistPacked ?? { items: autoChecklist }),
            payload.total_cost,
            payload.created_by,
            payload.created_by,
            payload.customer_id,
            txNo,
            paymentMethod,
            JSON.stringify(costBreakdown),
            laborCost,
            travelCost,
            new Date().toISOString(),
          ];
    const { rows } = await getPool().query(sql, params);
    res.status(201).json({ id: rows[0].id, total_cost: totalCost, transaction_no: txNo });
  } catch (err) {
    console.error(err);
    const msg = err instanceof Error ? err.message : "database error";
    res.status(500).json({ error: msg || "database error" });
  }
});

app.patch("/api/mobile/pos/catering/:id/stage", async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const staffEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const staffPassword = String(req.body?.cashier_password ?? "");
  const nextStatus = String(req.body?.status ?? "").trim().toLowerCase();
  const orderKind = String(req.body?.order_kind ?? "event").trim().toLowerCase();
  if (!id || !staffEmail || !staffPassword || !nextStatus) {
    res.status(400).json({ error: "id, status, cashier_email and cashier_password are required" });
    return;
  }
  const auth = await verifyPosStaff(staffEmail, staffPassword, ["manager", "supervisor"]);
  if (!auth.ok) {
    res.status(403).json({ error: "invalid manager/supervisor credentials" });
    return;
  }
  const dbNextStatus = mapManagerCateringStageToDb(nextStatus);
  const allowed = [
    "for_down_payment",
    "for_ongoing",
    "for_full_payment",
    "completed",
    "cancelled",
  ];
  if (!allowed.includes(dbNextStatus)) {
    res.status(400).json({ error: "invalid next status" });
    return;
  }
  if (auth.role === "supervisor" && nextStatus === "completed") {
    res.status(403).json({ error: "supervisor cannot complete orders" });
    return;
  }
  const downPaymentAmount = Number(req.body?.down_payment_amount ?? NaN);
  const fullPaymentAmount = Number(req.body?.full_payment_amount ?? NaN);
  const laborCost = Number(req.body?.labor_cost ?? NaN);
  const travelCost = Number(req.body?.travel_cost ?? NaN);
  const totalCost = Number(req.body?.total_cost ?? NaN);
  const postAnalysis = req.body?.post_analysis ?? null;
  const checklist = req.body?.checklist ?? null;
  const additionalCosts = Array.isArray(req.body?.additional_costs) ? req.body.additional_costs : null;
  const costBreakdown = Array.isArray(req.body?.cost_breakdown) ? req.body.cost_breakdown : null;
  const themeDesign = req.body?.theme_design ?? null;
  const menu = Array.isArray(req.body?.menu) ? req.body.menu : null;
  const actualEventImages = Array.isArray(req.body?.actual_event_images) ? req.body.actual_event_images : null;
  try {
    await ensureNewEventSchemaOnce();
    const table = orderKind === "catering" ? "catering_orders" : "event_orders";
    const txSelect = orderKind === "catering" ? CATERING_TRANSACTION_ID : EVENT_TRANSACTION_ID;
    const { rows: beforeRows } = await getPool().query(
      `SELECT checklist, ${POST_ANALYSIS_JSON} AS post_analysis, menu, email_address, ${txSelect} AS transaction_no, total_cost, customer_id, schedule_slots, status FROM ${table} WHERE id::text = $1`,
      [id],
    );
    const before = beforeRows[0] as
      | {
          checklist: unknown;
          post_analysis: unknown;
          menu: unknown;
          email_address: string;
          transaction_no: string | null;
          total_cost: string | number;
          customer_id: string | null;
          schedule_slots: unknown;
          status: string;
        }
      | undefined;
    if (!before) {
      res.status(404).json({ error: "event order not found" });
      return;
    }
    if (nextStatus === "cancelled") {
      const curSt = String(before.status ?? "").trim().toLowerCase();
      if (curSt !== "new_event" && curSt !== "online_inquiries") {
        res.status(400).json({ error: "can only cancel inquiries still in New Event or Online Inquiries" });
        return;
      }
    }
    const beforeSt = normalizeCateringStatusForApi(String(before.status ?? ""), before as Record<string, unknown>);
    const nextSt = normalizeCateringStatusForApi(dbNextStatus);
    if (nextSt === "for_full_payment" && beforeSt !== "for_ongoing") {
      if (beforeSt === "for_down_payment") {
        res.status(400).json({
          error: "move this order to On Going before advancing to For Full Payment",
        });
        return;
      }
    }
    const existingChecklist = normalizeChecklist(before.checklist);
    const incomingChecklist = checklist != null ? normalizeChecklist(checklist) : null;
    if (auth.role === "supervisor" && incomingChecklist != null) {
      const a = existingChecklist.map((x) => x.item).sort().join("|");
      const b = incomingChecklist.map((x) => x.item).sort().join("|");
      if (a !== b || existingChecklist.length !== incomingChecklist.length) {
        res.status(403).json({ error: "supervisor can only update checklist status" });
        return;
      }
    }
    let checklistToSave = incomingChecklist;
    const incomingChecklistEmpty = incomingChecklist != null && incomingChecklist.length === 0;
    if ((checklistToSave == null || incomingChecklistEmpty) && existingChecklist.length === 0) {
      checklistToSave = await generateChecklistFromMenu(before.menu);
    }
    const existingPost = before.post_analysis && typeof before.post_analysis === "object"
      ? (before.post_analysis as Record<string, unknown>)
      : {};
    const incomingPost = postAnalysis && typeof postAnalysis === "object"
      ? (postAnalysis as Record<string, unknown>)
      : null;
    const mergedPost: Record<string, unknown> | null = incomingPost != null ? { ...existingPost, ...incomingPost } : null;
    const postToSave =
      nextSt === "for_down_payment" || nextSt === "for_ongoing"
        ? (() => {
            const base = mergedPost ?? { ...existingPost };
            base.processing_phase = nextSt === "for_ongoing" ? "ongoing" : "down_payment";
            const taskRowsRaw = base.task_assignment_rows;
            if (!Array.isArray(taskRowsRaw) || taskRowsRaw.length === 0) {
              base.task_assignment_rows = defaultTaskAssignmentRows();
            }
            if (!base.task_assignment) base.task_assignment = "";
            return base;
          })()
        : mergedPost;
    const bumpStageEnteredAt = String(before.status ?? "").trim().toLowerCase() !== dbNextStatus;
    const checklistPayload = packChecklistWithPost(checklistToSave, postToSave, before.checklist);
    const addlCol = additionalCostsDbColumnForStatus(String(before.status ?? ""));
    const menuParam = orderKind === "event" ? 12 : 11;
    const stageParam = orderKind === "event" ? 13 : 12;
    const themeClause =
      orderKind === "event" ? "theme_design = COALESCE($11::jsonb, theme_design)," : "";
    const { rows } = await getPool().query(
      `UPDATE ${table}
       SET status = $2,
           updated_by = $3,
           down_payment_amount = COALESCE($4, down_payment_amount),
           down_payment_status = CASE WHEN $4 IS NULL THEN down_payment_status ELSE 'paid' END,
           full_payment_amount = COALESCE($5, full_payment_amount),
           full_payment_status = CASE WHEN $5 IS NULL THEN full_payment_status ELSE 'paid' END,
           checklist = COALESCE($6::jsonb, checklist),
           ${addlCol} = COALESCE($7::jsonb, ${addlCol}),
           labor_cost = COALESCE($8, labor_cost),
           travel_cost = COALESCE($9, travel_cost),
           total_cost = COALESCE($10, total_cost),
           ${themeClause}
           menu = COALESCE($${menuParam}::jsonb, menu),
           stage_entered_at = CASE WHEN $${stageParam}::boolean THEN NOW() ELSE stage_entered_at END
       WHERE id::text = $1
       RETURNING id::text, email_address, ${txSelect} AS transaction_no, total_cost`,
      [
        id,
        dbNextStatus,
        staffEmail,
        Number.isFinite(downPaymentAmount) ? downPaymentAmount : null,
        Number.isFinite(fullPaymentAmount) ? fullPaymentAmount : null,
        checklistPayload ? JSON.stringify(checklistPayload) : null,
        additionalCosts ? JSON.stringify(additionalCosts) : null,
        Number.isFinite(laborCost) ? laborCost : null,
        Number.isFinite(travelCost) ? travelCost : null,
        Number.isFinite(totalCost) ? totalCost : null,
        ...(orderKind === "event" ? [themeDesign ? JSON.stringify(themeDesign) : null] : []),
        menu ? JSON.stringify(menu) : null,
        bumpStageEnteredAt,
      ],
    );
    if (!rows[0]) {
      res.status(404).json({ error: "event order not found" });
      return;
    }
    if (actualEventImages && orderKind !== "catering") {
      const tdMerge = mergeThemeDesignIntoPostAnalysis(
        postAnalysisFromChecklistRaw(before.checklist),
        { actual_event_images: actualEventImages },
      );
      if (tdMerge) {
        await getPool().query(
          `UPDATE event_orders SET checklist = jsonb_set(
             COALESCE(checklist, '{}'::jsonb),
             '{post_analysis}',
             COALESCE($2::jsonb, COALESCE(checklist->'post_analysis', '{}'::jsonb))
           ) WHERE id::text = $1`,
          [id, JSON.stringify(tdMerge)],
        );
      }
    }
    const orderRef = String(rows[0].transaction_no ?? id);
    const orderTotal = toNum(rows[0].total_cost ?? before.total_cost, 0);
    const dueMsg =
      nextSt === "for_down_payment"
        ? `Your inquiry ${orderRef} is now For Down Payment. Please pay the down payment to continue.`
        : dbNextStatus === "for_full_payment"
          ? `Down payment confirmed for ${orderRef}. Remaining balance is now due. Current total: ₱${orderTotal.toFixed(2)}.`
          : dbNextStatus === "completed"
            ? `Order ${orderRef} is completed. Final total: ₱${orderTotal.toFixed(2)}.`
            : "";
    if (dueMsg) {
      // In-app notifications are keyed by the customer's login email, not internal customer_id.
      const notifyEmail = String(rows[0].email_address ?? before.email_address ?? "")
        .trim()
        .toLowerCase();
      if (notifyEmail) {
        await getPool().query(`INSERT INTO notifications (user_id, message) VALUES ($1, $2)`, [notifyEmail, dueMsg]);
      }
      void sendMailSafe(
        String(rows[0].email_address ?? before.email_address),
        `Order update ${orderRef}`,
        dueMsg,
      );
    }
    // Award catering loyalty when the order reaches For Full Payment, not on completed.
    if (dbNextStatus === "for_full_payment") {
      const loyaltyEmail = String(rows[0].email_address ?? before.email_address ?? "").trim().toLowerCase();
      const loyaltyPoints = loyaltyPointsFor("catering_event", orderTotal);
      await applyLoyaltyRewardsBestEffort(
        loyaltyEmail,
        String(rows[0].transaction_no ?? before.transaction_no ?? id),
        orderTotal,
        "catering_event",
      );
      await getPool().query(
        `UPDATE ${table} SET loyalty_points_catering_obtained = $2 WHERE id::text = $1`,
        [id, loyaltyPoints],
      );
    }
    res.json({ ok: true, id: rows[0].id, status: dbNextStatus });
  } catch (err) {
    console.error(err);
    const msg = err instanceof Error ? err.message : "database error";
    res.status(500).json({ error: msg || "database error" });
  }
});

app.patch("/api/mobile/pos/catering/:id/post-analysis-patch", async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const staffEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const staffPassword = String(req.body?.cashier_password ?? "");
  const orderKind = String(req.body?.order_kind ?? "event").trim().toLowerCase();
  const patch = req.body?.patch;
  if (!id || !staffEmail || !staffPassword || patch == null || typeof patch !== "object" || Array.isArray(patch)) {
    res.status(400).json({ error: "id, credentials, and patch object are required" });
    return;
  }
  const auth = await verifyPosStaff(staffEmail, staffPassword, ["manager", "supervisor"]);
  if (!auth.ok) {
    res.status(403).json({ error: "invalid manager/supervisor credentials" });
    return;
  }
  const paymentKeys = [
    "manager_down_payment_confirmed",
    "manager_full_payment_confirmed",
    "additional_costs_payment_confirmed",
  ];
  const patchKeys = Object.keys(patch as Record<string, unknown>);
  if (patchKeys.some((k) => paymentKeys.includes(k)) && auth.role !== "manager") {
    res.status(403).json({ error: "only a manager can update payment confirmation flags" });
    return;
  }
  const table = orderKind === "catering" ? "catering_orders" : "event_orders";
  try {
    const { rows: exist } = await getPool().query(
      `SELECT ${POST_ANALYSIS_JSON} AS post_analysis FROM ${table} WHERE id::text = $1`,
      [id],
    );
    if (exist.length === 0) {
      res.status(404).json({ error: "not found" });
      return;
    }
    const row0 = exist[0] as { post_analysis: unknown };
    const existing =
      row0.post_analysis && typeof row0.post_analysis === "object" ? (row0.post_analysis as Record<string, unknown>) : {};
    const merged = { ...existing, ...(patch as Record<string, unknown>) };
    const { rows: cur } = await getPool().query(`SELECT checklist FROM ${table} WHERE id::text = $1`, [id]);
    const checklistPayload = packChecklistWithPost(null, merged, (cur[0] as { checklist?: unknown })?.checklist);
    await getPool().query(
      `UPDATE ${table} SET checklist = COALESCE($2::jsonb, checklist), ${CATERING_ORDER_TOUCH_SET}, updated_by = $3 WHERE id::text = $1`,
      [id, checklistPayload ? JSON.stringify(checklistPayload) : JSON.stringify({ post_analysis: merged }), staffEmail],
    );
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/pos/catering/:id/draft", async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const staffEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const staffPassword = String(req.body?.cashier_password ?? "");
  const orderKind = String(req.body?.order_kind ?? "event").trim().toLowerCase();
  if (!id || !staffEmail || !staffPassword) {
    res.status(400).json({ error: "id and staff credentials are required" });
    return;
  }
  if (!(await verifyPosStaff(staffEmail, staffPassword, ["manager", "supervisor"])).ok) {
    res.status(403).json({ error: "invalid manager/supervisor credentials" });
    return;
  }
  const table = orderKind === "catering" ? "catering_orders" : "event_orders";
  const postAnalysis = req.body?.post_analysis ?? null;
  const checklist = req.body?.checklist ?? null;
  const menu = req.body?.menu ?? null;
  const themeDesign = req.body?.theme_design ?? null;
  const additionalCosts = req.body?.additional_costs ?? null;
  const laborCost = Number(req.body?.labor_cost ?? NaN);
  const travelCost = Number(req.body?.travel_cost ?? NaN);
  const totalCost = Number(req.body?.total_cost ?? NaN);
  const costBreakdown = Array.isArray(req.body?.cost_breakdown) ? req.body.cost_breakdown : null;
  const downPaymentAmount = Number(req.body?.down_payment_amount ?? NaN);
  const guestCount = Number(req.body?.guest_count ?? NaN);
  const paxBufferRaw = Number(req.body?.pax_buffer ?? NaN);
  const paxBuffer = Number.isFinite(paxBufferRaw) ? Math.max(0, Math.floor(paxBufferRaw)) : null;
  const address = req.body?.address != null ? String(req.body.address) : null;
  const scheduleSlots = req.body?.schedule_slots ?? null;
  const eventTitle = req.body?.event_title != null ? String(req.body.event_title) : null;
  const eventType = req.body?.event_type != null ? String(req.body.event_type) : null;
  const formalityLevel = req.body?.formality_level != null ? String(req.body.formality_level) : null;
  const customerName = req.body?.customer_name != null ? String(req.body.customer_name).trim() : null;
  const contactPerson = req.body?.contact_person != null ? String(req.body.contact_person).trim() : null;
  const contactNumber = req.body?.contact_number != null ? String(req.body.contact_number).trim() : null;
  const emailAddress = req.body?.email_address != null ? String(req.body.email_address).trim() : null;
  try {
    await ensureNewEventSchemaOnce();
    const { rows: curRows } = await getPool().query(`SELECT checklist FROM ${table} WHERE id::text = $1`, [id]);
    const existingChecklistRaw = (curRows[0] as { checklist?: unknown } | undefined)?.checklist;
    const incomingPostRaw =
      postAnalysis && typeof postAnalysis === "object" ? (postAnalysis as Record<string, unknown>) : null;
    const incomingPost = mergeThemeDesignIntoPostAnalysis(incomingPostRaw, themeDesign);
    const incomingItems = checklist != null ? normalizeChecklist(checklist) : null;
    const checklistPayload = packChecklistWithPost(incomingItems, incomingPost, existingChecklistRaw);
    const td =
      themeDesign != null && typeof themeDesign === "object" && !Array.isArray(themeDesign)
        ? (themeDesign as Record<string, unknown>)
        : {};
    const eventSettingVal = td.event_setting != null ? String(td.event_setting).trim() : null;
    if (orderKind === "catering") {
      await getPool().query(
        `UPDATE catering_orders SET
          updated_by = $2,
          ${CATERING_ORDER_TOUCH_SET},
          checklist = COALESCE($3::jsonb, checklist),
          menu = COALESCE($4::jsonb, menu),
          inquiry_additional_costs = COALESCE($5::jsonb, inquiry_additional_costs),
          labor_cost = COALESCE($6, labor_cost),
          travel_cost = COALESCE($7, travel_cost),
          total_cost = COALESCE($8, total_cost),
          cost_breakdown = COALESCE($9::jsonb, cost_breakdown),
          down_payment_amount = COALESCE($10, down_payment_amount),
          guest_count = COALESCE($11, guest_count),
          pax_buffer = COALESCE($12, pax_buffer),
          address = COALESCE($13, address),
          schedule_slots = COALESCE($14::jsonb, schedule_slots),
          customer_name = COALESCE($15, customer_name),
          contact_person = COALESCE($16, contact_person),
          contact_number = COALESCE($17, contact_number),
          email_address = COALESCE($18, email_address),
          event_title = COALESCE($19, event_title),
          event_type = COALESCE($20, event_type),
          formality_level = COALESCE($21, formality_level),
          event_setting = COALESCE($22, event_setting)
        WHERE id::text = $1 AND status IN ('new_event', 'online_inquiries')`,
        [
          id,
          staffEmail,
          checklistPayload ? JSON.stringify(checklistPayload) : null,
          menu ? JSON.stringify(menu) : null,
          additionalCosts ? JSON.stringify(additionalCosts) : null,
          Number.isFinite(laborCost) ? laborCost : null,
          Number.isFinite(travelCost) ? travelCost : null,
          Number.isFinite(totalCost) ? totalCost : null,
          costBreakdown ? JSON.stringify(costBreakdown) : null,
          Number.isFinite(downPaymentAmount) ? downPaymentAmount : null,
          Number.isFinite(guestCount) ? Math.max(0, Math.floor(guestCount)) : null,
          paxBuffer,
          address,
          scheduleSlots ? JSON.stringify(scheduleSlots) : null,
          customerName || null,
          contactPerson || null,
          contactNumber || null,
          emailAddress || null,
          eventTitle,
          eventType,
          formalityLevel,
          eventSettingVal,
        ],
      );
    } else {
      await getPool().query(
        `UPDATE event_orders SET
          updated_by = $2,
          ${CATERING_ORDER_TOUCH_SET},
          checklist = COALESCE($3::jsonb, checklist),
          menu = COALESCE($4::jsonb, menu),
          theme_design = COALESCE($5::jsonb, theme_design),
          inquiry_additional_costs = COALESCE($6::jsonb, inquiry_additional_costs),
          labor_cost = COALESCE($7, labor_cost),
          travel_cost = COALESCE($8, travel_cost),
          total_cost = COALESCE($9, total_cost),
          cost_breakdown = COALESCE($10::jsonb, cost_breakdown),
          down_payment_amount = COALESCE($11, down_payment_amount),
          guest_count = COALESCE($12, guest_count),
          pax_buffer = COALESCE($13, pax_buffer),
          address = COALESCE($14, address),
          schedule_slots = COALESCE($15::jsonb, schedule_slots),
          event_title = COALESCE($16, event_title),
          event_type = COALESCE($17, event_type),
          formality_level = COALESCE($18, formality_level),
          customer_name = COALESCE($19, customer_name),
          contact_person = COALESCE($20, contact_person),
          contact_number = COALESCE($21, contact_number),
          email_address = COALESCE($22, email_address)
        WHERE id::text = $1 AND status IN ('new_event', 'online_inquiries')`,
        [
          id,
          staffEmail,
          checklistPayload ? JSON.stringify(checklistPayload) : null,
          menu ? JSON.stringify(menu) : null,
          themeDesign ? JSON.stringify(themeDesign) : null,
          additionalCosts ? JSON.stringify(additionalCosts) : null,
          Number.isFinite(laborCost) ? laborCost : null,
          Number.isFinite(travelCost) ? travelCost : null,
          Number.isFinite(totalCost) ? totalCost : null,
          costBreakdown ? JSON.stringify(costBreakdown) : null,
          Number.isFinite(downPaymentAmount) ? downPaymentAmount : null,
          Number.isFinite(guestCount) ? Math.max(0, Math.floor(guestCount)) : null,
          paxBuffer,
          address,
          scheduleSlots ? JSON.stringify(scheduleSlots) : null,
          eventTitle,
          eventType,
          formalityLevel,
          customerName || null,
          contactPerson || null,
          contactNumber || null,
          emailAddress || null,
        ],
      );
    }
    const n = await getPool().query(`SELECT id FROM ${table} WHERE id::text = $1`, [id]);
    if (n.rows.length === 0) {
      res.status(404).json({ error: "order not found" });
      return;
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

/** Move a draft-stage row between `catering_orders` and `event_orders` so inquiry type can change (same id). */
app.post("/api/mobile/pos/catering/:id/switch-order-kind", async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const staffEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const staffPassword = String(req.body?.cashier_password ?? "");
  const fromKind = String(req.body?.from_order_kind ?? "").trim().toLowerCase();
  const toKind = String(req.body?.to_order_kind ?? "").trim().toLowerCase();
  if (!id || !staffEmail || !staffPassword) {
    res.status(400).json({ error: "id and staff credentials are required" });
    return;
  }
  if (!(await verifyPosStaff(staffEmail, staffPassword, ["manager", "supervisor"])).ok) {
    res.status(403).json({ error: "invalid manager/supervisor credentials" });
    return;
  }
  if (
    (fromKind !== "catering" && fromKind !== "event") ||
    (toKind !== "catering" && toKind !== "event") ||
    fromKind === toKind
  ) {
    res.status(400).json({ error: "from_order_kind and to_order_kind must be catering and event (distinct)" });
    return;
  }
  const client = await getPool().connect();
  try {
    await client.query("BEGIN");
    if (fromKind === "catering" && toKind === "event") {
      const lock = await client.query(
        `SELECT 1 FROM catering_orders WHERE id::text = $1 AND status IN ('new_event', 'online_inquiries') FOR UPDATE`,
        [id],
      );
      if (lock.rows.length === 0) {
        await client.query("ROLLBACK");
        res.status(404).json({ error: "catering order not found or not editable in this stage" });
        return;
      }
      await client.query(
        `INSERT INTO event_orders (
          id, source, status, order_type, customer_name, contact_person, contact_number, email_address,
          schedule_slots, address, guest_count, menu, theme_design, checklist,
          down_payment_amount, down_payment_status, full_payment_amount, full_payment_status,
          total_cost, created_at, updated_at, stage_entered_at,
          event_title, event_type, formality_level, actual_event_images,
          event_id, payment_method, cost_breakdown, labor_cost, travel_cost, additional_costs, full_payment_due_at,
          created_by, updated_by, customer_id
        )
        SELECT
          c.id, c.source, c.status, c.order_type, c.customer_name, c.contact_person, c.contact_number, c.email_address,
          c.schedule_slots, c.address, c.guest_count, c.menu, jsonb_build_object(
            'event_setting', COALESCE(NULLIF(TRIM(c.event_setting), ''), ''),
            'service_included', COALESCE(NULLIF(TRIM(c.event_setting), ''), '')
          ), c.checklist,
          c.down_payment_amount, c.down_payment_status, c.full_payment_amount, c.full_payment_status,
          c.total_cost,
          COALESCE(c.submitted_order_dt_stamp, c.created_at, c.stage_entered_at, NOW()),
          COALESCE(c.last_updated_order_status_dt_stamp, c.submitted_order_dt_stamp, c.created_at, c.stage_entered_at, NOW()),
          c.stage_entered_at,
          COALESCE(NULLIF(TRIM(c.event_title), ''), NULLIF(TRIM(c.customer_name), ''), 'Untitled'),
          COALESCE(NULLIF(TRIM(c.event_type), ''), 'General'),
          COALESCE(NULLIF(TRIM(c.formality_level), ''), 'casual'),
          '[]'::jsonb,
          c.catering_id, c.payment_method, c.cost_breakdown, c.labor_cost, c.travel_cost, c.additional_costs, c.full_payment_due_at,
          c.created_by, c.updated_by, c.customer_id
        FROM catering_orders c
        WHERE c.id::text = $1`,
        [id],
      );
      await client.query(`DELETE FROM catering_orders WHERE id::text = $1`, [id]);
    } else {
      const lock = await client.query(
        `SELECT 1 FROM event_orders WHERE id::text = $1 AND status IN ('new_event', 'online_inquiries') FOR UPDATE`,
        [id],
      );
      if (lock.rows.length === 0) {
        await client.query("ROLLBACK");
        res.status(404).json({ error: "event order not found or not editable in this stage" });
        return;
      }
      await client.query(
        `INSERT INTO catering_orders (
          id, source, status, order_type, customer_name, contact_person, contact_number, email_address,
          schedule_slots, address, guest_count, menu, event_title, event_type, formality_level, event_setting, checklist,
          down_payment_amount, down_payment_status, full_payment_amount, full_payment_status,
          total_cost, created_at, updated_at, stage_entered_at,
          catering_id, payment_method, cost_breakdown, labor_cost, travel_cost, additional_costs, full_payment_due_at,
          created_by, updated_by, customer_id
        )
        SELECT
          e.id, e.source, e.status, e.order_type, e.customer_name, e.contact_person, e.contact_number, e.email_address,
          e.schedule_slots, e.address, e.guest_count, e.menu,
          COALESCE(NULLIF(TRIM(e.event_title), ''), ''),
          COALESCE(NULLIF(TRIM(e.event_type), ''), ''),
          COALESCE(NULLIF(TRIM(e.formality_level), ''), 'casual'),
          COALESCE(NULLIF(TRIM(e.theme_design->>'event_setting'), ''), ''),
          e.checklist,
          e.down_payment_amount, e.down_payment_status, e.full_payment_amount, e.full_payment_status,
          e.total_cost,
          COALESCE(e.submitted_order_dt_stamp, e.created_at, e.stage_entered_at, NOW()),
          COALESCE(e.last_updated_order_status_dt_stamp, e.submitted_order_dt_stamp, e.created_at, e.stage_entered_at, NOW()),
          e.stage_entered_at,
          e.event_id, e.payment_method, e.cost_breakdown, e.labor_cost, e.travel_cost, e.additional_costs, e.full_payment_due_at,
          e.created_by, e.updated_by, e.customer_id
        FROM event_orders e
        WHERE e.id::text = $1`,
        [id],
      );
      await client.query(`DELETE FROM event_orders WHERE id::text = $1`, [id]);
    }
    await client.query("COMMIT");
    res.json({ ok: true, order_kind: toKind });
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    console.error(err);
    res.status(500).json({
      error: err instanceof Error ? err.message : "could not switch order kind — check database columns",
    });
  } finally {
    client.release();
  }
});

app.post("/api/mobile/pos/catering/send-order-summary-email", async (req, res) => {
  const cashierEmail = String(req.body?.cashier_email ?? "").trim().toLowerCase();
  const cashierPassword = String(req.body?.cashier_password ?? "");
  const orderKind = String(req.body?.order_kind ?? "").trim().toLowerCase();
  const id = String(req.body?.id ?? "").trim();
  const pdfBase64 = String(req.body?.pdf_base64 ?? "");
  const toEmail = String(req.body?.customer_email ?? "").trim().toLowerCase();
  if (!cashierEmail || !cashierPassword || !orderKind || !id || !pdfBase64 || !toEmail) {
    res.status(400).json({ error: "cashier credentials, order_kind, id, customer_email, and pdf_base64 are required" });
    return;
  }
  if (!(await verifyPosStaff(cashierEmail, cashierPassword, ["manager", "supervisor"])).ok) {
    res.status(403).json({ error: "invalid manager credentials" });
    return;
  }
  if (!toEmail.includes("@")) {
    res.status(400).json({ error: "valid customer_email is required" });
    return;
  }
  if (!isMailConfigured()) {
    res.status(503).json({
      error:
        "SMTP not configured — set TRANSPORTER_EMAIL and TRANSPORTER_PASSWORD (or GMAIL_USER + GMAIL_APP_PASSWORD)",
    });
    return;
  }
  try {
    const buf = Buffer.from(pdfBase64, "base64");
    if (buf.length < 64) {
      res.status(400).json({ error: "invalid pdf payload" });
      return;
    }
    const table = orderKind === "catering" ? "catering_orders" : "event_orders";
    const { rows } = await getPool().query(
      `SELECT LOWER(TRIM(email_address)) AS em FROM ${table} WHERE id::text = $1 LIMIT 1`,
      [id],
    );
    const rowEm = String((rows[0] as { em?: string } | undefined)?.em ?? "").trim().toLowerCase();
    if (!rowEm || rowEm !== toEmail) {
      res.status(400).json({ error: "customer_email does not match this order" });
      return;
    }
    const safeName = `order_summary_${id.replace(/[^a-zA-Z0-9_-]+/g, "_").slice(0, 24)}.pdf`;
    await sendMailWithPdfRequired(
      toEmail,
      "Your catering order summary",
      "Thank you for choosing Macrina's Kitchen. Please find your order summary attached.\n\n"
        + "If you have questions, reply to this email or contact us through the app.",
      safeName,
      buf,
    );
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    const msg = err instanceof Error ? err.message : "could not send email";
    res.status(500).json({ error: msg });
  }
});

app.get("/api/mobile/pos/catering/:id/invoice-preview", async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const orderKind = String(req.query.order_kind ?? "event").trim().toLowerCase();
  const table = orderKind === "catering" ? "catering_orders" : "event_orders";
  const txSelect = orderKind === "catering" ? CATERING_TRANSACTION_ID : EVENT_TRANSACTION_ID;
  try {
    const { rows } = await getPool().query(
      `SELECT id::text, ${txSelect} AS transaction_no, customer_name, event_title, guest_count, total_cost, down_payment_amount, full_payment_amount,
              cost_breakdown, labor_cost, travel_cost, additional_costs, menu, checklist, payment_method
       FROM ${table}
       WHERE id::text = $1`,
      [id],
    );
    if (!rows[0]) {
      res.status(404).json({ error: "order not found" });
      return;
    }
    const row = rows[0] as Record<string, unknown>;
    res.json({
      ...row,
      printable_summary: {
        transaction_no: row.transaction_no,
        customer: row.customer_name,
        event_title: row.event_title,
        menu: row.menu,
        checklist: row.checklist,
        totals: {
          subtotal: toNum(row.total_cost, 0),
          downpayment: toNum(row.down_payment_amount, 0),
          fullpayment: toNum(row.full_payment_amount, 0),
        },
      },
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/notifications", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const { rows } = await getPool().query(
      `SELECT id::text AS id, message, is_read, created_at FROM notifications WHERE user_id = $1 ORDER BY created_at DESC LIMIT 100`,
      [userEmail],
    );
    const unread = rows.filter((r: { is_read?: boolean }) => r.is_read !== true).length;
    res.json({ unread_count: unread, notifications: rows });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/customer/tray-draft", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "")
    .trim()
    .toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    await ensureCustomerTrayDraftsSchemaOnce();
    const pool = getPool();
    const trayCols = await getTrayDraftColumns(pool);
    const { rows } = await pool.query(
      `SELECT ${trayCols.linesCol} AS tray_lines, updated_at
       FROM customer_tray_drafts
       WHERE LOWER(TRIM(${trayCols.emailCol})) = $1
       LIMIT 1`,
      [userEmail],
    );
    const row = (rows[0] ?? null) as { tray_lines?: unknown; updated_at?: string } | null;
    res.json({
      tray_lines: Array.isArray(row?.tray_lines) ? row?.tray_lines : [],
      updated_at: row?.updated_at ?? "",
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.put("/api/mobile/customer/tray-draft", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "")
    .trim()
    .toLowerCase();
  const trayLines = Array.isArray(req.body?.tray_lines) ? req.body.tray_lines : null;
  if (!userEmail || trayLines == null) {
    res.status(400).json({ error: "user_email and tray_lines are required" });
    return;
  }
  try {
    await ensureCustomerTrayDraftsSchemaOnce();
    const pool = getPool();
    const trayCols = await getTrayDraftColumns(pool);
    const { rows } = await pool.query(
      `INSERT INTO customer_tray_drafts (${trayCols.emailCol}, ${trayCols.linesCol}, updated_at)
       VALUES ($1, $2::jsonb, NOW())
       ON CONFLICT (${trayCols.emailCol})
       DO UPDATE SET ${trayCols.linesCol} = EXCLUDED.${trayCols.linesCol}, updated_at = NOW()
       RETURNING updated_at`,
      [userEmail, JSON.stringify(trayLines)],
    );
    res.json({
      ok: true,
      updated_at: String(rows[0]?.updated_at ?? ""),
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/realtime/sync-stamps", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "")
    .trim()
    .toLowerCase();
  const role = String(req.query.role ?? "customer")
    .trim()
    .toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    const pool = getPool();
    const menuStampExpr = await menuDishesMaxStampExpr(pool);
    const roChangedSince = await getRestaurantOrderChangedSinceSql(pool);
    let trayStampExpr = `''::text`;
    try {
      await ensureCustomerTrayDraftsSchemaOnce();
      const trayCols = await getTrayDraftColumns(pool);
      trayStampExpr = `COALESCE((SELECT MAX(updated_at)::text FROM customer_tray_drafts WHERE LOWER(TRIM(${trayCols.emailCol})) = $1), '')`;
    } catch (trayErr) {
      console.warn("[sync-stamps] customer_tray_drafts unavailable", trayErr);
    }
    const { rows } = await pool.query(
      `SELECT
         ${menuStampExpr} AS menu_stamp,
         COALESCE((SELECT MAX(${roChangedSince})::text FROM restaurant_orders), '') AS restaurant_orders_stamp,
         COALESCE((SELECT MAX(${CUSTOMER_ACCOUNT_STAMP_SQL})::text FROM customer_accounts), '') AS profile_stamp,
         COALESCE((SELECT MAX(created_at)::text FROM notifications WHERE user_id = $1), '') AS notifications_stamp,
         COALESCE((SELECT MAX((${CATERING_ORDER_UPDATED_AT_SQL}))::text FROM catering_orders WHERE LOWER(email_address) = $1), '') AS catering_inquiries_stamp,
         COALESCE((SELECT MAX((${CATERING_ORDER_UPDATED_AT_SQL}))::text FROM event_orders WHERE LOWER(email_address) = $1), '') AS event_inquiries_stamp,
         COALESCE((SELECT MAX((${CATERING_ORDER_UPDATED_AT_SQL}))::text FROM catering_orders), '') AS manager_catering_stamp,
         COALESCE((SELECT MAX((${CATERING_ORDER_UPDATED_AT_SQL}))::text FROM event_orders), '') AS manager_event_stamp,
         COALESCE((SELECT MAX(${CUSTOMER_ACCOUNT_STAMP_SQL})::text FROM customer_accounts), '') AS loyalty_stamp,
         ${trayStampExpr} AS tray_stamp`,
      [userEmail],
    );
    const row = (rows[0] ?? {}) as Record<string, unknown>;
    res.json({
      role,
      server_time: new Date().toISOString(),
      menu: String(row.menu_stamp ?? ""),
      restaurant_orders: String(row.restaurant_orders_stamp ?? ""),
      profile: String(row.profile_stamp ?? ""),
      notifications: String(row.notifications_stamp ?? ""),
      inquiries: `${String(row.catering_inquiries_stamp ?? "")}|${String(row.event_inquiries_stamp ?? "")}`,
      manager_catering: `${String(row.manager_catering_stamp ?? "")}|${String(row.manager_event_stamp ?? "")}`,
      loyalty: String(row.loyalty_stamp ?? ""),
      tray: String(row.tray_stamp ?? ""),
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.get("/api/mobile/realtime/deltas", async (req, res) => {
  const userEmail = String(req.query.user_email ?? "")
    .trim()
    .toLowerCase();
  const role = String(req.query.role ?? "customer")
    .trim()
    .toLowerCase();
  const sinceRaw = String(req.query.since ?? "").trim();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  const parsed = sinceRaw ? new Date(sinceRaw) : null;
  const since = parsed && !Number.isNaN(parsed.getTime()) ? parsed : new Date(Date.now() - 5 * 60 * 1000);
  try {
    const pool = getPool();
    const menuChangedSql = await menuDishesChangedSinceSql(pool);
    const menuChanged =
      ((await pool.query(menuChangedSql, [since.toISOString()])).rowCount ?? 0) > 0;

    const profileChanged = ((
      await pool.query(
        `SELECT 1
         FROM customer_accounts
         WHERE LOWER(TRIM(email)) = $1
           AND ${CUSTOMER_ACCOUNT_STAMP_SQL} > $2
         LIMIT 1`,
        [userEmail, since.toISOString()],
      )
    ).rowCount ?? 0) > 0;

    const loyaltyChanged = ((
      await pool.query(
        `SELECT 1
         FROM customer_accounts
         WHERE LOWER(TRIM(email)) = $1
           AND ${CUSTOMER_ACCOUNT_STAMP_SQL} > $2
         LIMIT 1`,
        [userEmail, since.toISOString()],
      )
    ).rowCount ?? 0) > 0;

    const roChangedSince = await getRestaurantOrderChangedSinceSql(pool);
    const roMatch = await restaurantOrderMatchesEmailWhere(pool, "", "$1");
    const orderRows = await pool.query(
      role === "customer"
        ? `SELECT mobile_id::text AS id
           FROM restaurant_orders
           WHERE ${roMatch}
             AND ${roChangedSince} > $2
           ORDER BY ${roChangedSince} DESC
           LIMIT 200`
        : `SELECT mobile_id::text AS id
           FROM restaurant_orders
           WHERE ${roChangedSince} > $1
           ORDER BY ${roChangedSince} DESC
           LIMIT 200`,
      role === "customer" ? [userEmail, since.toISOString()] : [since.toISOString()],
    );

    const inquiryRows = await getPool().query(
      role === "customer"
        ? `SELECT id::text AS id
           FROM (
             SELECT id, ${CATERING_ORDER_UPDATED_AT_SQL} AS ts
             FROM catering_orders
             WHERE LOWER(TRIM(email_address)) = $1
             UNION ALL
             SELECT id, ${CATERING_ORDER_UPDATED_AT_SQL} AS ts
             FROM event_orders
             WHERE LOWER(TRIM(email_address)) = $1
           ) t
           WHERE t.ts > $2
           ORDER BY t.ts DESC
           LIMIT 200`
        : `SELECT id::text AS id
           FROM (
             SELECT id, ${CATERING_ORDER_UPDATED_AT_SQL} AS ts FROM catering_orders
             UNION ALL
             SELECT id, ${CATERING_ORDER_UPDATED_AT_SQL} AS ts FROM event_orders
           ) t
           WHERE t.ts > $1
           ORDER BY t.ts DESC
           LIMIT 200`,
      role === "customer" ? [userEmail, since.toISOString()] : [since.toISOString()],
    );
    const cateringInquiryRows = await getPool().query(
      role === "customer"
        ? `SELECT id::text AS id
           FROM catering_orders
           WHERE LOWER(TRIM(email_address)) = $1
             AND ${CATERING_ORDER_UPDATED_AT_SQL} > $2
           ORDER BY ${CATERING_ORDER_UPDATED_AT_SQL} DESC
           LIMIT 200`
        : `SELECT id::text AS id
           FROM catering_orders
           WHERE ${CATERING_ORDER_UPDATED_AT_SQL} > $1
           ORDER BY ${CATERING_ORDER_UPDATED_AT_SQL} DESC
           LIMIT 200`,
      role === "customer" ? [userEmail, since.toISOString()] : [since.toISOString()],
    );
    const eventInquiryRows = await getPool().query(
      role === "customer"
        ? `SELECT id::text AS id
           FROM event_orders
           WHERE LOWER(TRIM(email_address)) = $1
             AND ${CATERING_ORDER_UPDATED_AT_SQL} > $2
           ORDER BY ${CATERING_ORDER_UPDATED_AT_SQL} DESC
           LIMIT 200`
        : `SELECT id::text AS id
           FROM event_orders
           WHERE ${CATERING_ORDER_UPDATED_AT_SQL} > $1
           ORDER BY ${CATERING_ORDER_UPDATED_AT_SQL} DESC
           LIMIT 200`,
      role === "customer" ? [userEmail, since.toISOString()] : [since.toISOString()],
    );

    const notificationRows = await getPool().query(
      `SELECT id::text AS id
       FROM notifications
       WHERE user_id = $1
         AND created_at > $2
       ORDER BY created_at DESC
       LIMIT 200`,
      [userEmail, since.toISOString()],
    );

    res.json({
      role,
      since: since.toISOString(),
      server_time: new Date().toISOString(),
      menu_changed: menuChanged,
      profile_changed: profileChanged,
      loyalty_changed: loyaltyChanged,
      restaurant_order_ids: orderRows.rows.map((r: { id: string }) => String(r.id)),
      inquiry_ids: inquiryRows.rows.map((r: { id: string }) => String(r.id)),
      catering_inquiry_ids: cateringInquiryRows.rows.map((r: { id: string }) => String(r.id)),
      event_inquiry_ids: eventInquiryRows.rows.map((r: { id: string }) => String(r.id)),
      notification_ids: notificationRows.rows.map((r: { id: string }) => String(r.id)),
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.patch("/api/mobile/notifications/read-all", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  if (!userEmail) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  try {
    await getPool().query(`UPDATE notifications SET is_read = TRUE WHERE user_id = $1 AND is_read = FALSE`, [userEmail]);
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/order-feedback", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const kind = String(req.body?.kind ?? "").trim().toLowerCase();
  const reference = String(req.body?.reference ?? "").trim();
  const ratingRaw = Number(req.body?.rating ?? 5);
  const rating = Number.isFinite(ratingRaw) ? Math.min(5, Math.max(1, Math.floor(ratingRaw))) : 5;
  const comment = String(req.body?.comment ?? "").trim();
  if (!userEmail || userEmail.endsWith("@guest.curatering.internal")) {
    res.status(400).json({ error: "user_email is required" });
    return;
  }
  if (!reference || (kind !== "restaurant_order" && kind !== "catering_inquiry")) {
    res.status(400).json({ error: "kind must be restaurant_order or catering_inquiry, and reference is required" });
    return;
  }
  try {
    if (kind === "restaurant_order") {
      const pool = getPool();
      const roMatch = await restaurantOrderMatchesEmailWhere(pool, "ro", "$1");
      const { rows } = await pool.query(
        `SELECT 1 FROM restaurant_orders ro
         WHERE ${roMatch}
           AND ${RESTAURANT_ORDER_BUSINESS_ID_SQL} = $2
           AND (
             UPPER(COALESCE(ro.fulfillment_stage, '')) = 'DELIVERED'
             OR UPPER(ro.status) LIKE '%COMPLETE%'
             OR UPPER(ro.status) LIKE '%DELIVERED%'
             OR UPPER(ro.status) LIKE '%DONE%'
             OR UPPER(ro.status) LIKE '%CLOSED%'
           )
         LIMIT 1`,
        [userEmail, reference],
      );
      if (!rows[0]) {
        res.status(400).json({ error: "order not found or not completed" });
        return;
      }
    } else {
      const { rows } = await getPool().query(
        `SELECT 1 FROM event_orders
         WHERE id::text = $2 AND LOWER(TRIM(email_address)) = $1 AND LOWER(TRIM(status)) = 'completed'
         UNION ALL
         SELECT 1 FROM catering_orders
         WHERE id::text = $2 AND LOWER(TRIM(email_address)) = $1 AND LOWER(TRIM(status)) = 'completed'
         LIMIT 1`,
        [userEmail, reference],
      );
      if (!rows[0]) {
        res.status(400).json({ error: "inquiry not found or not completed" });
        return;
      }
    }
    await getPool().query(
      `INSERT INTO customer_order_feedback (user_email, kind, reference, rating, comment)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (user_email, kind, reference)
       DO UPDATE SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, created_at = NOW()`,
      [userEmail, kind, reference, rating, comment],
    );
    const msg = `Customer order feedback\nFrom: ${userEmail}\nKind: ${kind}\nRef: ${reference}\nRating: ${rating}/5\n${comment || "(no remarks)"}`;
    await getPool().query(
      `INSERT INTO notifications (user_id, message)
       SELECT email, $1
       FROM users
       WHERE role IN ('manager', 'supervisor')`,
      [msg],
    );
    res.status(201).json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

app.post("/api/mobile/help", async (req, res) => {
  const userEmail = String(req.body?.user_email ?? "").trim().toLowerCase();
  const area = String(req.body?.area ?? "").trim();
  const problem = String(req.body?.problem ?? "").trim();
  const desiredOutcome = String(req.body?.desired_outcome ?? "").trim();
  if (!userEmail || !area || !problem || !desiredOutcome) {
    res.status(400).json({ error: "user_email, area, problem, and desired_outcome are required" });
    return;
  }
  try {
    await getPool().query(
      `INSERT INTO help_requests (user_email, area, problem, desired_outcome)
       VALUES ($1, $2, $3, $4)`,
      [userEmail, area, problem, desiredOutcome],
    );
  } catch (first) {
    try {
      await getPool().query(
        `INSERT INTO help_requests (user_id, feature, problem, request)
         VALUES ($1, $2, $3, $4)`,
        [userEmail, area, problem, desiredOutcome],
      );
    } catch (second) {
      console.error(first);
      console.error(second);
      res.status(500).json({ error: "database error" });
      return;
    }
  }
  try {
    const managerNotice = `Follow-up requires attention\nFrom: ${userEmail}\nArea: ${area}\nProblem: ${problem}`;
    await getPool().query(
      `INSERT INTO notifications (user_id, message)
       SELECT email, $1
       FROM users
       WHERE role IN ('manager', 'supervisor')`,
      [managerNotice],
    );
    void sendMailSafe(
      userEmail,
      "Help request received",
      `We recorded your help request.\nArea: ${area}\nProblem: ${problem}\nWhat you'd like: ${desiredOutcome}`,
    );
    res.status(201).json({ ok: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "database error" });
  }
});

async function seedCashierAccount(): Promise<void> {
  const email = "rhannahdrex@yahoo.com";
  const displayName = "Drexyll Calibara";
  const hash = await bcrypt.hash("hannah24", 10);
  try {
    const pool = getPool();
    const { rows } = await pool.query(`SELECT id FROM users WHERE email = $1`, [email]);
    if (!rows[0]) {
      await pool.query(
        `INSERT INTO users (id, staff_id, email, password_hash, role, pos_role, full_name)
         VALUES (gen_random_uuid()::text, 'USR-0001', $1, $2, 'cashier', 'cashier', $3)
         ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash, full_name = EXCLUDED.full_name, role = 'cashier', pos_role = 'cashier', staff_id = COALESCE(users.staff_id, EXCLUDED.staff_id)`,
        [email, hash, displayName],
      );
      console.log("[db] seeded cashier (users):", email);
    } else {
      await pool.query(`UPDATE users SET full_name = $2, password_hash = $3, role = 'cashier', pos_role = 'cashier' WHERE email = $1`, [
        email,
        displayName,
        hash,
      ]);
      console.log("[db] cashier users row updated:", email);
    }
  } catch (e) {
    console.warn("[db] cashier seed skipped:", e);
  }
}

async function seedManagerSupervisorAccounts(): Promise<void> {
  const pool = getPool();
  const managerHash = await bcrypt.hash("manager123", 10);
  const supervisorHash = await bcrypt.hash("supervisor321", 10);
  await pool.query(
    `INSERT INTO users (id, staff_id, email, password_hash, role, full_name, pos_role)
     VALUES (gen_random_uuid()::text, 'USR-0002', 'manager@curatering.com', $1, 'manager', 'Manager Sample', 'manager')
     ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash,
       full_name = EXCLUDED.full_name,
       role = EXCLUDED.role,
       pos_role = EXCLUDED.pos_role,
       staff_id = COALESCE(users.staff_id, EXCLUDED.staff_id)`,
    [managerHash],
  );
  await pool.query(
    `INSERT INTO users (id, staff_id, email, password_hash, role, full_name, pos_role)
     VALUES (gen_random_uuid()::text, 'USR-0003', 'supervisor@curatering.com', $1, 'supervisor', 'Supervisor Sample', 'supervisor')
     ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash,
       full_name = EXCLUDED.full_name,
       role = EXCLUDED.role,
       pos_role = EXCLUDED.pos_role,
       staff_id = COALESCE(users.staff_id, EXCLUDED.staff_id)`,
    [supervisorHash],
  );
}

async function seedCustomerSeedRow(): Promise<void> {
  const email = "cus0001@curatering.local";
  const hash = await bcrypt.hash("Customer123!", 10);
  try {
    const pool = getPool();
    await pool.query(
      `INSERT INTO customer_accounts (
         email, password_hash, full_name, is_verified, customer_id, contact_number, primary_delivery_address
       )
       VALUES ($1, $2, 'Sample Customer', TRUE, 'CUS-0001', '', '')
       ON CONFLICT (email) DO NOTHING`,
      [email, hash],
    );
  } catch (e) {
    console.warn("[db] customer_accounts seed skipped:", e);
  }
}

registerEventDesignSeatingRoutes(app, {
  getPool,
  verifyPosStaff: (email, password, roles) =>
    verifyPosStaff(
      email,
      password,
      (roles ?? ["manager", "supervisor", "cashier"]) as PosStaffRole[],
    ),
});

async function main() {
  await initDb();
  await backfillLoyaltyForConfirmedMobileOrders();
  await recomputeHistoricalLoyaltyPoints();
  await seedCashierAccount();
  await seedManagerSupervisorAccounts();
  await seedCustomerSeedRow();
  app.listen(port, () => {
    console.log(`curatering-backend listening on http://localhost:${port}`);
  });
}

main().catch((err) => {
  console.error(err);
  const hint = formatDbStartupError(err);
  if (hint) console.error(`\n${hint}`);
  process.exit(1);
});
