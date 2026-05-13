import pg from "pg";

const { Pool } = pg;

/** Extra stderr lines when startup fails (e.g. DNS); empty string if no tailored hint. */
export function formatDbStartupError(err: unknown): string {
  const e = err as NodeJS.ErrnoException & { hostname?: string };
  if (e?.code !== "ENOTFOUND" || !e.hostname) return "";
  return [
    `[db] Cannot resolve database host "${e.hostname}" (DNS lookup failed).`,
    "Update DATABASE_URL in packages/backend/.env using Supabase → Project Settings → Database → Connection string (URI).",
    "If the pooler host keeps failing on your network, try the Direct connection (host db.<project-ref>.supabase.co, port 5432).",
    "On Windows you can run: ipconfig /flushdns   or temporarily set DNS to 1.1.1.1 / 8.8.8.8.",
  ].join("\n");
}

let pool: pg.Pool | null = null;

function rawDatabaseUrl(): string {
  const url = process.env.DATABASE_URL?.trim();
  if (!url) {
    throw new Error("DATABASE_URL is missing. Copy .env.example to .env and set your Postgres URL.");
  }
  return url;
}

/** Remove libpq TLS query params so Pool `ssl` options are not overridden by URI parsing. */
function stripTlsQueryParams(connectionString: string): string {
  const qIdx = connectionString.indexOf("?");
  if (qIdx === -1) return connectionString;
  const base = connectionString.slice(0, qIdx);
  const qs = connectionString.slice(qIdx + 1);
  const params = new URLSearchParams(qs);
  for (const k of ["sslmode", "sslrootcert", "sslcert", "sslkey", "sslcrl"]) {
    params.delete(k);
  }
  const rest = params.toString();
  return rest ? `${base}?${rest}` : base;
}

function connectionStringForVerify(): string {
  const url = rawDatabaseUrl();
  return url.includes("sslmode=") ? url : `${url}${url.includes("?") ? "&" : "?"}sslmode=require`;
}

/**
 * When true (default), TLS must validate the server cert chain.
 * Set DATABASE_SSL_REJECT_UNAUTHORIZED=false in .env only if you hit
 * SELF_SIGNED_CERT_IN_CHAIN with your host (e.g. corporate proxy); never in production unless you trust the network.
 *
 * Important: when false, we strip `sslmode` / SSL file params from the URL. Otherwise `pg`
 * treats `sslmode=require` as verify-full and still fails with SELF_SIGNED_CERT_IN_CHAIN
 * even if we pass `ssl: { rejectUnauthorized: false }`.
 */
function tlsRejectUnauthorized(): boolean {
  const v = process.env.DATABASE_SSL_REJECT_UNAUTHORIZED?.trim().toLowerCase();
  if (v === "false" || v === "0") {
    return false;
  }
  return true;
}

const poolCommon = {
  max: 10,
  /** Recycle pooled sockets so Supabase pooler / idle disconnects (XX000 / EDBHANDLEREXITED) are less likely. */
  idleTimeoutMillis: 20_000,
  connectionTimeoutMillis: 15_000,
  // @types/pg includes maxUses on PoolConfig for pg 8+ pooler recycling.
  maxUses: 200,
} as const;

export function getPool(): pg.Pool {
  if (!pool) {
    const verify = tlsRejectUnauthorized();
    if (verify) {
      pool = new Pool({
        connectionString: connectionStringForVerify(),
        ...poolCommon,
      });
    } else {
      pool = new Pool({
        connectionString: stripTlsQueryParams(rawDatabaseUrl()),
        ...poolCommon,
        ssl: { rejectUnauthorized: false },
      });
    }
  }
  return pool;
}

/** Ensure app tables exist (safe to call on every startup). */
export async function initDb(): Promise<void> {
  const p = getPool();
  await p.query(`
    CREATE TABLE IF NOT EXISTS items (
      id BIGSERIAL PRIMARY KEY,
      title TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await p.query(`
    CREATE TABLE IF NOT EXISTS mobile_orders (
      id BIGSERIAL PRIMARY KEY,
      user_email TEXT NOT NULL,
      order_no TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL DEFAULT 'WAITING FOR ORDER CONFIRMATION',
      note TEXT NOT NULL DEFAULT '',
      payment_mode TEXT NOT NULL DEFAULT 'GCASH ONLY',
      payment_uploaded BOOLEAN NOT NULL DEFAULT FALSE,
      payment_proof TEXT,
      delivery_name TEXT NOT NULL DEFAULT '',
      delivery_contact TEXT NOT NULL DEFAULT '',
      delivery_address TEXT NOT NULL DEFAULT '',
      delivery_time TEXT NOT NULL DEFAULT 'NOW',
      total NUMERIC(12,2) NOT NULL DEFAULT 0,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await p.query(`
    CREATE TABLE IF NOT EXISTS mobile_users (
      id BIGSERIAL PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await p.query(`
    CREATE TABLE IF NOT EXISTS customer_accounts (
      id BIGSERIAL PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      phone_number TEXT NOT NULL DEFAULT '',
      password_hash TEXT NOT NULL,
      full_name TEXT NOT NULL DEFAULT '',
      is_verified BOOLEAN NOT NULL DEFAULT FALSE,
      signup_otp_code TEXT,
      signup_otp_expires_at TIMESTAMPTZ,
      password_reset_otp TEXT,
      password_reset_expires_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await p.query(`
    CREATE TABLE IF NOT EXISTS action_logs (
      id BIGSERIAL PRIMARY KEY,
      actor_email TEXT NOT NULL DEFAULT '',
      action TEXT NOT NULL DEFAULT '',
      details TEXT NOT NULL DEFAULT '',
      metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await p.query(`ALTER TABLE mobile_users ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'customer'`);
  await p.query(`ALTER TABLE mobile_users ADD COLUMN IF NOT EXISTS display_name TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS phone_number TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS full_name TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS is_verified BOOLEAN NOT NULL DEFAULT FALSE`);
  await p.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS signup_otp_code TEXT`);
  await p.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS signup_otp_expires_at TIMESTAMPTZ`);
  await p.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS password_reset_otp TEXT`);
  await p.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS password_reset_expires_at TIMESTAMPTZ`);
  await p.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`);
  await p.query(`
    INSERT INTO customer_accounts (email, password_hash, full_name, is_verified)
    SELECT mu.email, mu.password_hash, COALESCE(NULLIF(mu.display_name, ''), ''), TRUE
    FROM mobile_users mu
    ON CONFLICT (email) DO NOTHING
  `);

  // Legacy `mobile_users` is no longer used for customer auth/profile.
  // Keep it around only long enough to backfill `customer_accounts`, then remove.
  await p.query(`DROP TABLE IF EXISTS mobile_users`);

  await p.query(`ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS order_source TEXT NOT NULL DEFAULT 'MOBILE_APP'`);
  await p.query(`ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS pos_customer_label TEXT NOT NULL DEFAULT ''`);
  await p.query(
    `ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS cashier_amount_received NUMERIC(12,2)`,
  );
  await p.query(`ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS cashier_change NUMERIC(12,2)`);

  await p.query(`ALTER TABLE mobile_orders ALTER COLUMN user_email DROP NOT NULL`);

  await p.query(
    `ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS fulfillment_stage TEXT NOT NULL DEFAULT 'PENDING_CASHIER'`,
  );
  await p.query(
    `ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS delivery_tracking_url TEXT NOT NULL DEFAULT ''`,
  );

  await p.query(
    `ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS order_lines_snapshot JSONB NOT NULL DEFAULT '[]'::jsonb`,
  );
  await p.query(
    `ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS pos_claimed BOOLEAN NOT NULL DEFAULT FALSE`,
  );

  await p.query(`ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS supplemental_payment_proof TEXT`);
  await p.query(`ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS cashier_secondary_amount_received NUMERIC(12,2)`);
  await p.query(
    `ALTER TABLE mobile_orders ADD COLUMN IF NOT EXISTS balance_proof_pending_review BOOLEAN NOT NULL DEFAULT FALSE`,
  );
  // Restaurant orders table now serves as the canonical table for mobile/POS restaurant flows.
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS mobile_id BIGINT`);
  await p.query(`CREATE SEQUENCE IF NOT EXISTS restaurant_orders_mobile_id_seq`);
  await p.query(`ALTER TABLE restaurant_orders ALTER COLUMN mobile_id SET DEFAULT nextval('restaurant_orders_mobile_id_seq')`);
  await p.query(`UPDATE restaurant_orders SET mobile_id = nextval('restaurant_orders_mobile_id_seq') WHERE mobile_id IS NULL`);
  // Keep sequence aligned with existing rows so inserts never reuse an existing mobile_id.
  await p.query(`
    SELECT setval(
      'restaurant_orders_mobile_id_seq',
      COALESCE((SELECT MAX(mobile_id) FROM restaurant_orders), 1),
      COALESCE((SELECT MAX(mobile_id) FROM restaurant_orders), 0) > 0
    )
  `);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS user_email TEXT`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_no TEXT`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS note TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_mode TEXT NOT NULL DEFAULT 'GCASH ONLY'`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_uploaded BOOLEAN NOT NULL DEFAULT FALSE`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_proof TEXT`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_name TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_contact TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_time TEXT NOT NULL DEFAULT 'NOW'`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS total NUMERIC(12,2) NOT NULL DEFAULT 0`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_source TEXT NOT NULL DEFAULT 'MOBILE_APP'`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS pos_customer_label TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS cashier_amount_received NUMERIC(12,2)`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS cashier_change NUMERIC(12,2)`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS fulfillment_stage TEXT NOT NULL DEFAULT 'PENDING_CASHIER'`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_tracking_url TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_lines_snapshot JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS pos_claimed BOOLEAN NOT NULL DEFAULT FALSE`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS supplemental_payment_proof TEXT`);
  await p.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS cashier_secondary_amount_received NUMERIC(12,2)`);
  await p.query(
    `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS balance_proof_pending_review BOOLEAN NOT NULL DEFAULT FALSE`,
  );
  try {
    await p.query(`ALTER TABLE restaurant_orders DROP CONSTRAINT IF EXISTS restaurant_orders_status_check`);
  } catch {
    // Constraint may not exist in all environments.
  }
  await p.query(`ALTER TABLE restaurant_orders ALTER COLUMN status SET DEFAULT 'WAITING FOR ORDER CONFIRMATION'`);
  // Some migrated datasets contain duplicate order numbers (ex: ORD-0001).
  // Keep the newest row's value and clear older duplicates so unique index creation succeeds.
  await p.query(`
    UPDATE restaurant_orders
    SET order_no = NULL
    WHERE order_no IS NOT NULL
      AND TRIM(order_no) = ''
  `);
  await p.query(`
    WITH ranked AS (
      SELECT
        id,
        ROW_NUMBER() OVER (
          PARTITION BY order_no
          ORDER BY COALESCE(updated_at, created_at) DESC, id DESC
        ) AS rn
      FROM restaurant_orders
      WHERE order_no IS NOT NULL
    )
    UPDATE restaurant_orders ro
    SET order_no = NULL
    FROM ranked r
    WHERE ro.id = r.id
      AND r.rn > 1
  `);
  await p.query(
    `CREATE UNIQUE INDEX IF NOT EXISTS restaurant_orders_mobile_id_uq ON restaurant_orders (mobile_id)`,
  );
  await p.query(
    `CREATE UNIQUE INDEX IF NOT EXISTS restaurant_orders_order_no_uq ON restaurant_orders (order_no) WHERE order_no IS NOT NULL`,
  );
  await p.query(`
    INSERT INTO restaurant_orders (
      mobile_id, user_email, order_no, status, note, payment_mode, payment_uploaded, payment_proof,
      delivery_name, delivery_contact, delivery_address, delivery_time, total, total_amount,
      order_source, pos_customer_label, cashier_amount_received, cashier_change, fulfillment_stage,
      delivery_tracking_url, order_lines_snapshot, pos_claimed, supplemental_payment_proof,
      cashier_secondary_amount_received, balance_proof_pending_review, created_at, updated_at, items
    )
    SELECT
      mo.id, mo.user_email, mo.order_no, mo.status, mo.note, mo.payment_mode, mo.payment_uploaded, mo.payment_proof,
      mo.delivery_name, mo.delivery_contact, mo.delivery_address, mo.delivery_time, COALESCE(mo.total, 0), COALESCE(mo.total, 0),
      mo.order_source, mo.pos_customer_label, mo.cashier_amount_received, mo.cashier_change, mo.fulfillment_stage,
      mo.delivery_tracking_url, COALESCE(mo.order_lines_snapshot, '[]'::jsonb), mo.pos_claimed, mo.supplemental_payment_proof,
      mo.cashier_secondary_amount_received, COALESCE(mo.balance_proof_pending_review, FALSE), mo.created_at, mo.updated_at,
      COALESCE(mo.order_lines_snapshot, '[]'::jsonb)
    FROM mobile_orders mo
    WHERE NOT EXISTS (
      SELECT 1 FROM restaurant_orders ro
      WHERE ro.mobile_id = mo.id OR (ro.order_no IS NOT NULL AND ro.order_no = mo.order_no)
    )
  `);
  await p.query(`
    CREATE OR REPLACE FUNCTION sync_mobile_orders_into_restaurant_orders() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        DELETE FROM restaurant_orders WHERE mobile_id = OLD.id;
        RETURN OLD;
      END IF;
      INSERT INTO restaurant_orders (
        mobile_id, user_email, order_no, status, note, payment_mode, payment_uploaded, payment_proof,
        delivery_name, delivery_contact, delivery_address, delivery_time, total, total_amount,
        order_source, pos_customer_label, cashier_amount_received, cashier_change, fulfillment_stage,
        delivery_tracking_url, order_lines_snapshot, pos_claimed, supplemental_payment_proof,
        cashier_secondary_amount_received, balance_proof_pending_review, created_at, updated_at, items
      )
      VALUES (
        NEW.id, NEW.user_email, NEW.order_no, NEW.status, NEW.note, NEW.payment_mode, NEW.payment_uploaded, NEW.payment_proof,
        NEW.delivery_name, NEW.delivery_contact, NEW.delivery_address, NEW.delivery_time, COALESCE(NEW.total, 0), COALESCE(NEW.total, 0),
        NEW.order_source, NEW.pos_customer_label, NEW.cashier_amount_received, NEW.cashier_change, NEW.fulfillment_stage,
        NEW.delivery_tracking_url, COALESCE(NEW.order_lines_snapshot, '[]'::jsonb), NEW.pos_claimed, NEW.supplemental_payment_proof,
        NEW.cashier_secondary_amount_received, COALESCE(NEW.balance_proof_pending_review, FALSE), NEW.created_at, NEW.updated_at,
        COALESCE(NEW.order_lines_snapshot, '[]'::jsonb)
      )
      ON CONFLICT (mobile_id) DO UPDATE SET
        user_email = EXCLUDED.user_email,
        order_no = EXCLUDED.order_no,
        status = EXCLUDED.status,
        note = EXCLUDED.note,
        payment_mode = EXCLUDED.payment_mode,
        payment_uploaded = EXCLUDED.payment_uploaded,
        payment_proof = EXCLUDED.payment_proof,
        delivery_name = EXCLUDED.delivery_name,
        delivery_contact = EXCLUDED.delivery_contact,
        delivery_address = EXCLUDED.delivery_address,
        delivery_time = EXCLUDED.delivery_time,
        total = EXCLUDED.total,
        total_amount = EXCLUDED.total_amount,
        order_source = EXCLUDED.order_source,
        pos_customer_label = EXCLUDED.pos_customer_label,
        cashier_amount_received = EXCLUDED.cashier_amount_received,
        cashier_change = EXCLUDED.cashier_change,
        fulfillment_stage = EXCLUDED.fulfillment_stage,
        delivery_tracking_url = EXCLUDED.delivery_tracking_url,
        order_lines_snapshot = EXCLUDED.order_lines_snapshot,
        pos_claimed = EXCLUDED.pos_claimed,
        supplemental_payment_proof = EXCLUDED.supplemental_payment_proof,
        cashier_secondary_amount_received = EXCLUDED.cashier_secondary_amount_received,
        balance_proof_pending_review = EXCLUDED.balance_proof_pending_review,
        created_at = EXCLUDED.created_at,
        updated_at = EXCLUDED.updated_at,
        items = EXCLUDED.items;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
  `);
  await p.query(`DROP TRIGGER IF EXISTS trg_sync_mobile_orders_into_restaurant_orders ON mobile_orders`);
  await p.query(`
    CREATE TRIGGER trg_sync_mobile_orders_into_restaurant_orders
    AFTER INSERT OR UPDATE OR DELETE ON mobile_orders
    FOR EACH ROW EXECUTE FUNCTION sync_mobile_orders_into_restaurant_orders()
  `);

  await p.query(`
    UPDATE mobile_orders
    SET fulfillment_stage = 'IN_PREPARATION'
    WHERE fulfillment_stage = 'PENDING_CASHIER'
      AND order_source = 'POS'
  `);
  await p.query(`
    UPDATE mobile_orders
    SET fulfillment_stage = 'IN_PREPARATION'
    WHERE fulfillment_stage = 'PENDING_CASHIER'
      AND order_source = 'MOBILE_APP'
      AND user_email IS NOT NULL
      AND (
        upper(status) LIKE '%ORDER CONFIRMED%'
        OR upper(status) LIKE '%OVERPAYMENT%'
      )
  `);

  await p.query(
    `ALTER TABLE customer_profiles ADD COLUMN IF NOT EXISTS delivery_map_confirmed BOOLEAN NOT NULL DEFAULT FALSE`,
  );
  await p.query(`ALTER TABLE customer_profiles ADD COLUMN IF NOT EXISTS delivery_lat DOUBLE PRECISION`);
  await p.query(`ALTER TABLE customer_profiles ADD COLUMN IF NOT EXISTS delivery_lng DOUBLE PRECISION`);
  await p.query(
    `ALTER TABLE customer_profiles ADD COLUMN IF NOT EXISTS loyalty_points INTEGER NOT NULL DEFAULT 0`,
  );
  await p.query(
    `ALTER TABLE customer_profiles ADD COLUMN IF NOT EXISTS loyalty_points_restaurant INTEGER`,
  );
  await p.query(
    `ALTER TABLE customer_profiles ADD COLUMN IF NOT EXISTS loyalty_points_catering INTEGER`,
  );
  await p.query(`ALTER TABLE customer_profiles ADD COLUMN IF NOT EXISTS delivery_addresses JSONB`);
  await p.query(`
    UPDATE customer_profiles
    SET loyalty_points_restaurant = COALESCE(loyalty_points_restaurant, loyalty_points),
        loyalty_points_catering = COALESCE(loyalty_points_catering, 0)
    WHERE loyalty_points_restaurant IS NULL OR loyalty_points_catering IS NULL
  `);
  await p.query(`
    UPDATE customer_profiles
    SET delivery_addresses = COALESCE(delivery_addresses, '[]'::jsonb)
    WHERE delivery_addresses IS NULL
  `);
  await p.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS pos_role TEXT NOT NULL DEFAULT ''`);
  await p.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS password_reset_otp TEXT`);
  await p.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS password_reset_expires_at TIMESTAMPTZ`);
  // Ensure legacy role constraint accepts cashier accounts used by POS login.
  try {
    await p.query(`ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check`);
    await p.query(`
      ALTER TABLE users
      ADD CONSTRAINT users_role_check
      CHECK (role IN ('admin', 'manager', 'supervisor', 'cashier', 'customer'))
    `);
  } catch {
    // Some environments may define role constraints differently; keep startup resilient.
  }
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS transaction_no TEXT`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS payment_method TEXT NOT NULL DEFAULT 'cash'`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS cost_breakdown JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS labor_cost NUMERIC NOT NULL DEFAULT 0`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS travel_cost NUMERIC NOT NULL DEFAULT 0`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS full_payment_due_at TIMESTAMPTZ`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS transaction_no TEXT`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS payment_method TEXT NOT NULL DEFAULT 'cash'`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS cost_breakdown JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS labor_cost NUMERIC NOT NULL DEFAULT 0`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS travel_cost NUMERIC NOT NULL DEFAULT 0`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS full_payment_due_at TIMESTAMPTZ`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS stage_entered_at TIMESTAMPTZ`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS checklist JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS checklist JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await p.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS points_earned INTEGER NOT NULL DEFAULT 0`);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS points_earned INTEGER NOT NULL DEFAULT 0`);
  await p.query(
    `ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS service_included TEXT NOT NULL DEFAULT ''`,
  );
  await p.query(`
    UPDATE event_orders
    SET service_included = COALESCE(
      NULLIF(TRIM(service_included), ''),
      NULLIF(TRIM(theme_design->>'service_included'), ''),
      ''
    )
    WHERE theme_design IS NOT NULL
      AND (service_included IS NULL OR TRIM(service_included) = '')
  `);
  await p.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS stage_entered_at TIMESTAMPTZ`);
  await p.query(
    `UPDATE event_orders SET stage_entered_at = updated_at WHERE stage_entered_at IS NULL`,
  );
  await p.query(
    `UPDATE catering_orders SET stage_entered_at = updated_at WHERE stage_entered_at IS NULL`,
  );
  await p.query(`ALTER TABLE event_orders ALTER COLUMN stage_entered_at SET DEFAULT NOW()`);
  await p.query(`ALTER TABLE catering_orders ALTER COLUMN stage_entered_at SET DEFAULT NOW()`);

  await p.query(`DROP TABLE IF EXISTS loyalty_point_history CASCADE`);

  try {
    await p.query(
      `UPDATE menu_dishes SET type = 'others' WHERE LOWER(TRIM(type)) IN ('other', 'special')`,
    );
  } catch {
    // Table/column may not exist in minimal dev DBs.
  }

  await p.query(`
    CREATE TABLE IF NOT EXISTS customer_signup_otp_challenges (
      email TEXT PRIMARY KEY,
      otp_code TEXT NOT NULL,
      otp_expires_at TIMESTAMPTZ NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);

  await p.query(`
    CREATE TABLE IF NOT EXISTS customer_tray_drafts (
      user_email TEXT PRIMARY KEY,
      tray_lines JSONB NOT NULL DEFAULT '[]'::jsonb,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);

  // Customer / manager cancellation requires `cancelled` on event inquiries too (older DBs may omit it from CHECK).
  try {
    await p.query(`ALTER TABLE event_orders DROP CONSTRAINT IF EXISTS event_orders_status_check`);
  } catch {
    // ignore
  }
  try {
    await p.query(`
      ALTER TABLE event_orders ADD CONSTRAINT event_orders_status_check
      CHECK (status = ANY (ARRAY[
        'new_event'::text, 'online_inquiries'::text, 'for_processing'::text,
        'for_post_analysis'::text, 'completed'::text, 'cancelled'::text
      ]))
    `);
  } catch {
    // Constraint may already be correct or renamed in some deployments.
  }

  await p.query(`
    CREATE TABLE IF NOT EXISTS customer_order_feedback (
      id BIGSERIAL PRIMARY KEY,
      user_email TEXT NOT NULL,
      kind TEXT NOT NULL,
      reference TEXT NOT NULL,
      rating INTEGER NOT NULL DEFAULT 5,
      comment TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await p.query(
    `CREATE UNIQUE INDEX IF NOT EXISTS customer_order_feedback_user_kind_ref_idx
     ON customer_order_feedback (user_email, kind, reference)`,
  );
}
