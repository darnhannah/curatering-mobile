import type pg from "pg";

async function safeExec(pool: pg.Pool, sql: string): Promise<void> {
  try {
    await pool.query(sql);
  } catch {
    /* optional migration step */
  }
}

/** Creates new tables and migrates data off legacy names; safe to run every startup. */
export async function runExtendedMigrations(pool: pg.Pool): Promise<void> {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'cashier',
      display_name TEXT NOT NULL DEFAULT '',
      full_name TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
  await safeExec(pool, `ALTER TABLE users ADD COLUMN IF NOT EXISTS full_name TEXT NOT NULL DEFAULT ''`);
  await safeExec(pool, `ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name TEXT NOT NULL DEFAULT ''`);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS customer_profiles (
      id TEXT PRIMARY KEY,
      user_email TEXT NOT NULL UNIQUE,
      full_name TEXT NOT NULL DEFAULT '',
      contact_number TEXT NOT NULL DEFAULT '',
      delivery_address TEXT NOT NULL DEFAULT '',
      delivery_map_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
      delivery_lat DOUBLE PRECISION,
      delivery_lng DOUBLE PRECISION,
      loyalty_points INTEGER NOT NULL DEFAULT 0,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);

  await safeExec(
    pool,
    `ALTER TABLE mobile_users ADD COLUMN IF NOT EXISTS signup_otp_code TEXT`,
  );
  await safeExec(
    pool,
    `ALTER TABLE mobile_users ADD COLUMN IF NOT EXISTS signup_otp_expires_at TIMESTAMPTZ`,
  );
  await safeExec(
    pool,
    `ALTER TABLE mobile_users ADD COLUMN IF NOT EXISTS password_reset_token TEXT`,
  );
  await safeExec(
    pool,
    `ALTER TABLE mobile_users ADD COLUMN IF NOT EXISTS password_reset_expires_at TIMESTAMPTZ`,
  );

  await pool.query(`
    CREATE TABLE IF NOT EXISTS help_requests (
      id BIGSERIAL PRIMARY KEY,
      user_email TEXT NOT NULL,
      area TEXT NOT NULL DEFAULT '',
      problem TEXT NOT NULL DEFAULT '',
      desired_outcome TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS event_orders (
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
      guest_count INTEGER NOT NULL DEFAULT 0,
      menu_suggestion_note TEXT NOT NULL DEFAULT '',
      theme_suggestion_note TEXT NOT NULL DEFAULT '',
      estimated_total NUMERIC(12,2) NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'SUBMITTED',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      event_city TEXT NOT NULL DEFAULT '',
      event_setting TEXT NOT NULL DEFAULT '',
      service_included TEXT NOT NULL DEFAULT '',
      formality_level TEXT NOT NULL DEFAULT '',
      food_tasting_requested BOOLEAN NOT NULL DEFAULT FALSE
    );
  `);

  await safeExec(
    pool,
    `
    INSERT INTO customer_profiles (id, user_email, full_name, contact_number, delivery_address,
      delivery_map_confirmed, delivery_lat, delivery_lng, created_at, updated_at)
    SELECT
      'CUS-' || LPAD((ROW_NUMBER() OVER (ORDER BY mp.id))::TEXT, 4, '0'),
      mp.user_email,
      mp.full_name,
      mp.contact_number,
      mp.delivery_address,
      mp.delivery_map_confirmed,
      mp.delivery_lat,
      mp.delivery_lng,
      mp.created_at,
      mp.updated_at
    FROM mobile_profiles mp
    ON CONFLICT (user_email) DO NOTHING
    `,
  );

  await safeExec(
    pool,
    `
    INSERT INTO event_orders (
      user_email, inquiry_no, inquiry_type, event_title, event_type, customer, contact_person, contact_number,
      inquiry_email, date_of_event, note, curate_own_menu, selected_set_menu, selected_dishes, include_event_theme,
      guest_count, menu_suggestion_note, theme_suggestion_note, estimated_total, status, created_at,
      event_city, event_setting, service_included, formality_level, food_tasting_requested)
    SELECT
      user_email, inquiry_no, inquiry_type, event_title, event_type, customer, contact_person, contact_number,
      inquiry_email, date_of_event, note, curate_own_menu, selected_set_menu, selected_dishes, include_event_theme,
      guest_count, menu_suggestion_note, theme_suggestion_note, estimated_total, status, created_at,
      event_city, event_setting, service_included, formality_level, food_tasting_requested
    FROM mobile_inquiries mi
    WHERE NOT EXISTS (SELECT 1 FROM event_orders eo WHERE eo.inquiry_no = mi.inquiry_no)
    `,
  );

  await safeExec(
    pool,
    `
    INSERT INTO help_requests (user_email, area, problem, desired_outcome, created_at)
    SELECT m.user_email, m.area, m.problem, m.desired_outcome, m.created_at
    FROM mobile_help_requests m
    WHERE NOT EXISTS (
      SELECT 1 FROM help_requests hr
      WHERE hr.user_email = m.user_email AND hr.created_at = m.created_at AND hr.problem = m.problem
    )
    `,
  );

  await safeExec(
    pool,
    `
    UPDATE mobile_users mu
    SET signup_otp_code = o.code, signup_otp_expires_at = o.expires_at
    FROM mobile_otp_codes o
    WHERE LOWER(o.email) = LOWER(mu.email)
    `,
  );

  try {
    const { rows } = await pool.query(
      `SELECT email, password_hash, COALESCE(display_name, '') AS display_name FROM mobile_users WHERE LOWER(TRIM(role)) = 'cashier'`,
    );
    let seq = 1;
    const idRows = await pool.query(`SELECT id FROM users WHERE id ~ '^USR-[0-9]+$'`);
    const nums = (idRows.rows as Array<{ id: string }>)
      .map((r) => Number(String(r.id).replace(/^USR-0*/, "") || "0"))
      .filter((n) => Number.isFinite(n) && n > 0);
    seq = nums.length > 0 ? Math.max(...nums) + 1 : 1;
    for (const r of rows as Array<{ email: string; password_hash: string; display_name: string }>) {
      const id = `USR-${String(seq).padStart(4, "0")}`;
      seq += 1;
      await pool.query(
        `INSERT INTO users (id, email, password_hash, role, display_name)
         VALUES ($1, $2, $3, 'cashier', $4)
         ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash, display_name = EXCLUDED.display_name`,
        [id, r.email.trim().toLowerCase(), r.password_hash, r.display_name ?? ""],
      );
    }
  } catch {
    /* optional */
  }

  await safeExec(
    pool,
    `DELETE FROM mobile_users mu USING users u WHERE LOWER(mu.email) = LOWER(u.email) AND LOWER(TRIM(mu.role)) = 'cashier'`,
  );

  // Drop legacy customer auth tables; the app uses customer_accounts/customer_profiles for customers.
  await safeExec(pool, `DROP TABLE IF EXISTS mobile_users`);
}
