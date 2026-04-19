import pg from "pg";

const { Pool } = pg;

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

export function getPool(): pg.Pool {
  if (!pool) {
    const verify = tlsRejectUnauthorized();
    if (verify) {
      pool = new Pool({
        connectionString: connectionStringForVerify(),
        max: 10,
      });
    } else {
      pool = new Pool({
        connectionString: stripTlsQueryParams(rawDatabaseUrl()),
        max: 10,
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
    CREATE TABLE IF NOT EXISTS mobile_profiles (
      id BIGSERIAL PRIMARY KEY,
      user_email TEXT NOT NULL UNIQUE,
      full_name TEXT NOT NULL DEFAULT '',
      contact_number TEXT NOT NULL DEFAULT '',
      delivery_address TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
    CREATE TABLE IF NOT EXISTS mobile_order_items (
      id BIGSERIAL PRIMARY KEY,
      order_id BIGINT NOT NULL REFERENCES mobile_orders(id) ON DELETE CASCADE,
      item_name TEXT NOT NULL,
      dip TEXT NOT NULL DEFAULT '',
      qty INTEGER NOT NULL,
      price NUMERIC(12,2) NOT NULL
    );
  `);
  await p.query(`
    CREATE TABLE IF NOT EXISTS mobile_inquiries (
      id BIGSERIAL PRIMARY KEY,
      user_email TEXT NOT NULL,
      inquiry_no TEXT NOT NULL UNIQUE,
      inquiry_type TEXT NOT NULL,
      event_title TEXT NOT NULL DEFAULT '',
      event_type TEXT NOT NULL DEFAULT '',
      customer TEXT NOT NULL DEFAULT '',
      contact_person TEXT NOT NULL DEFAULT '',
      contact_number TEXT NOT NULL DEFAULT '',
      inquiry_email TEXT NOT NULL DEFAULT '',
      date_of_event TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL DEFAULT '',
      curate_own_menu BOOLEAN NOT NULL DEFAULT FALSE,
      selected_set_menu TEXT NOT NULL DEFAULT '',
      selected_dishes TEXT NOT NULL DEFAULT '[]',
      include_event_theme BOOLEAN NOT NULL DEFAULT FALSE,
      status TEXT NOT NULL DEFAULT 'SUBMITTED',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
    CREATE TABLE IF NOT EXISTS mobile_otp_codes (
      email TEXT PRIMARY KEY,
      code TEXT NOT NULL,
      expires_at TIMESTAMPTZ NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await p.query(`
    CREATE TABLE IF NOT EXISTS mobile_help_requests (
      id BIGSERIAL PRIMARY KEY,
      user_email TEXT NOT NULL,
      area TEXT NOT NULL DEFAULT '',
      problem TEXT NOT NULL DEFAULT '',
      desired_outcome TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS guest_count INTEGER NOT NULL DEFAULT 0`,
  );
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS menu_suggestion_note TEXT NOT NULL DEFAULT ''`,
  );
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS theme_suggestion_note TEXT NOT NULL DEFAULT ''`,
  );
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS estimated_total NUMERIC(12,2) NOT NULL DEFAULT 0`,
  );
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS event_city TEXT NOT NULL DEFAULT ''`,
  );
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS event_setting TEXT NOT NULL DEFAULT ''`,
  );
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS service_included TEXT NOT NULL DEFAULT ''`,
  );
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS formality_level TEXT NOT NULL DEFAULT ''`,
  );
  await p.query(
    `ALTER TABLE mobile_inquiries ADD COLUMN IF NOT EXISTS food_tasting_requested BOOLEAN NOT NULL DEFAULT FALSE`,
  );

  await p.query(`ALTER TABLE mobile_users ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'customer'`);
  await p.query(`ALTER TABLE mobile_users ADD COLUMN IF NOT EXISTS display_name TEXT NOT NULL DEFAULT ''`);

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
    `ALTER TABLE mobile_profiles ADD COLUMN IF NOT EXISTS delivery_map_confirmed BOOLEAN NOT NULL DEFAULT FALSE`,
  );
  await p.query(`ALTER TABLE mobile_profiles ADD COLUMN IF NOT EXISTS delivery_lat DOUBLE PRECISION`);
  await p.query(`ALTER TABLE mobile_profiles ADD COLUMN IF NOT EXISTS delivery_lng DOUBLE PRECISION`);

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
}
