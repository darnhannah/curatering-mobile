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
}
