import type pg from "pg";

async function columnExists(
  pool: pg.Pool,
  table: string,
  column: string,
): Promise<boolean> {
  const { rows } = await pool.query<{ exists: boolean }>(
    `SELECT EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
     ) AS exists`,
    [table, column],
  );
  return rows[0]?.exists === true;
}

async function tableExists(pool: pg.Pool, table: string): Promise<boolean> {
  const { rows } = await pool.query<{ exists: boolean }>(
    `SELECT EXISTS (
       SELECT 1 FROM information_schema.tables
       WHERE table_schema = 'public' AND table_name = $1
     ) AS exists`,
    [table],
  );
  return rows[0]?.exists === true;
}

async function safeExec(pool: pg.Pool, sql: string): Promise<void> {
  try {
    await pool.query(sql);
  } catch (err) {
    console.warn("[schema] migration step skipped:", err instanceof Error ? err.message : err);
  }
}

async function renameColumnIfExists(
  pool: pg.Pool,
  table: string,
  from: string,
  to: string,
): Promise<void> {
  if (from === to) return;
  if (!(await columnExists(pool, table, from))) return;
  if (await columnExists(pool, table, to)) return;
  await safeExec(pool, `ALTER TABLE ${table} RENAME COLUMN ${from} TO ${to}`);
}

async function copyColumnIfBothExist(
  pool: pg.Pool,
  table: string,
  target: string,
  source: string,
): Promise<void> {
  if (!(await columnExists(pool, table, target))) return;
  if (!(await columnExists(pool, table, source))) return;
  await pool.query(
    `UPDATE ${table}
     SET ${target} = COALESCE(NULLIF(TRIM(${target}::text), ''), ${source}::text)
     WHERE ${target} IS NULL OR TRIM(${target}::text) = ''`,
  );
}

/** Idempotent schema alignment: merge duplicates, preserve row data. */
export async function runSchemaNormalize(pool: pg.Pool): Promise<void> {
  await normalizeAiGenerations(pool);
  await normalizeCustomerAccountsAndMergeProfiles(pool);
  await normalizeRestaurantOrders(pool);
  await syncRestaurantOrdersDualWrite(pool);
  await normalizeCateringOrders(pool);
  await normalizeEventOrders(pool);
  await normalizeIdCounter(pool);
  await normalizeMenuDishes(pool);
  await dropLegacyTables(pool);
}

/** Keep legacy and canonical restaurant_orders columns aligned after deploys. */
async function syncRestaurantOrdersDualWrite(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "restaurant_orders"))) return;
  await safeExec(
    pool,
    `UPDATE restaurant_orders SET
       order_id = COALESCE(NULLIF(TRIM(order_id), ''), NULLIF(TRIM(order_no), '')),
       order_no = COALESCE(NULLIF(TRIM(order_no), ''), NULLIF(TRIM(order_id), ''))
     WHERE order_id IS DISTINCT FROM order_no
       OR order_id IS NULL OR order_no IS NULL`,
  );
  await safeExec(
    pool,
    `UPDATE restaurant_orders SET
       total_cost = COALESCE(total_cost, total, total_amount),
       total = COALESCE(total, total_cost, total_amount),
       total_amount = COALESCE(total_amount, total_cost, total)
     WHERE total IS DISTINCT FROM total_cost
        OR total_cost IS DISTINCT FROM total_amount
        OR total IS NULL OR total_cost IS NULL`,
  );
  await safeExec(
    pool,
    `UPDATE restaurant_orders SET
       delivery_notes = COALESCE(NULLIF(TRIM(delivery_notes), ''), NULLIF(TRIM(note), '')),
       note = COALESCE(NULLIF(TRIM(note), ''), NULLIF(TRIM(delivery_notes), ''))
     WHERE delivery_notes IS DISTINCT FROM note`,
  );
  await safeExec(
    pool,
    `UPDATE restaurant_orders SET
       order_status = COALESCE(NULLIF(TRIM(order_status), ''), NULLIF(TRIM(fulfillment_stage), ''), NULLIF(TRIM(status), '')),
       fulfillment_stage = COALESCE(NULLIF(TRIM(fulfillment_stage), ''), NULLIF(TRIM(order_status), ''), NULLIF(TRIM(status), '')),
       status = COALESCE(NULLIF(TRIM(status), ''), NULLIF(TRIM(order_status), ''), NULLIF(TRIM(fulfillment_stage), ''))
     WHERE order_status IS DISTINCT FROM status OR fulfillment_stage IS DISTINCT FROM order_status`,
  );
  if (await columnExists(pool, "restaurant_orders", "tray_items")) {
    await safeExec(
      pool,
      `UPDATE restaurant_orders SET
         tray_items = COALESCE(NULLIF(tray_items, '[]'::jsonb), order_lines_snapshot, items, '[]'::jsonb),
         order_lines_snapshot = COALESCE(NULLIF(order_lines_snapshot, '[]'::jsonb), tray_items, items, '[]'::jsonb),
         items = COALESCE(NULLIF(items, '[]'::jsonb), tray_items, order_lines_snapshot, '[]'::jsonb)
       WHERE tray_items IS DISTINCT FROM order_lines_snapshot`,
    );
  }
}

async function normalizeAiGenerations(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "ai_generations"))) return;
  for (const col of ["event_type", "theme", "formality", "final_prompt", "original_prompt"]) {
    await safeExec(pool, `ALTER TABLE ai_generations DROP COLUMN IF EXISTS ${col}`);
  }
}

async function normalizeCustomerAccountsAndMergeProfiles(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "customer_accounts"))) return;

  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS customer_id TEXT`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS contact_number TEXT NOT NULL DEFAULT ''`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS signup_otp_code TEXT`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS signup_otp_code_expiry TIMESTAMPTZ`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS forgot_password_otp_code TEXT`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS forgot_password_otp_code_expiry TIMESTAMPTZ`);
  await pool.query(
    `ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS restaurant_loyalty_points INTEGER NOT NULL DEFAULT 0`,
  );
  await pool.query(
    `ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS catering_loyalty_points INTEGER NOT NULL DEFAULT 0`,
  );
  await pool.query(
    `ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS primary_delivery_address TEXT NOT NULL DEFAULT ''`,
  );
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS other_delivery_addresses JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS delivery_map_confirmed BOOLEAN NOT NULL DEFAULT FALSE`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS delivery_lat DOUBLE PRECISION`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS delivery_lng DOUBLE PRECISION`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS created_account_dt_stamp TIMESTAMPTZ`);
  await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS updated_pw_dt_stamp TIMESTAMPTZ`);

  await copyColumnIfBothExist(pool, "customer_accounts", "contact_number", "phone_number");
  await copyColumnIfBothExist(pool, "customer_accounts", "signup_otp_code_expiry", "signup_otp_expires_at");
  await copyColumnIfBothExist(pool, "customer_accounts", "forgot_password_otp_code", "password_reset_otp");
  await copyColumnIfBothExist(
    pool,
    "customer_accounts",
    "forgot_password_otp_code_expiry",
    "password_reset_expires_at",
  );
  await copyColumnIfBothExist(pool, "customer_accounts", "restaurant_loyalty_points", "loyalty_points_restaurant");
  await copyColumnIfBothExist(pool, "customer_accounts", "catering_loyalty_points", "loyalty_points_catering");
  await copyColumnIfBothExist(pool, "customer_accounts", "primary_delivery_address", "delivery_address");
  await copyColumnIfBothExist(pool, "customer_accounts", "other_delivery_addresses", "delivery_addresses");
  await copyColumnIfBothExist(pool, "customer_accounts", "created_account_dt_stamp", "created_at");
  await copyColumnIfBothExist(pool, "customer_accounts", "updated_pw_dt_stamp", "updated_at");

  if (await columnExists(pool, "customer_accounts", "loyalty_points")) {
    await safeExec(
      pool,
      `UPDATE customer_accounts
       SET restaurant_loyalty_points = GREATEST(
             restaurant_loyalty_points,
             COALESCE(loyalty_points, 0) - COALESCE(catering_loyalty_points, 0),
             0
           ),
           catering_loyalty_points = GREATEST(catering_loyalty_points, COALESCE(loyalty_points_catering, 0), 0)
       WHERE loyalty_points IS NOT NULL`,
    );
  }

  if (await tableExists(pool, "customer_profiles")) {
    await pool.query(`
      UPDATE customer_accounts ca
      SET
        customer_id = COALESCE(NULLIF(TRIM(ca.customer_id), ''), NULLIF(TRIM(cp.id), '')),
        email = COALESCE(NULLIF(TRIM(ca.email), ''), LOWER(TRIM(cp.user_email))),
        full_name = COALESCE(NULLIF(TRIM(ca.full_name), ''), NULLIF(TRIM(cp.full_name), ''), ''),
        contact_number = COALESCE(NULLIF(TRIM(ca.contact_number), ''), NULLIF(TRIM(cp.contact_number), ''), ''),
        primary_delivery_address = COALESCE(
          NULLIF(TRIM(ca.primary_delivery_address), ''),
          NULLIF(TRIM(cp.delivery_address), ''),
          ''
        ),
        delivery_map_confirmed = COALESCE(ca.delivery_map_confirmed, cp.delivery_map_confirmed, FALSE),
        delivery_lat = COALESCE(ca.delivery_lat, cp.delivery_lat),
        delivery_lng = COALESCE(ca.delivery_lng, cp.delivery_lng),
        other_delivery_addresses = COALESCE(
          NULLIF(ca.other_delivery_addresses, '[]'::jsonb),
          cp.delivery_addresses,
          '[]'::jsonb
        ),
        restaurant_loyalty_points = GREATEST(
          COALESCE(ca.restaurant_loyalty_points, 0),
          COALESCE(cp.loyalty_points_restaurant, cp.loyalty_points, 0)
        ),
        catering_loyalty_points = GREATEST(
          COALESCE(ca.catering_loyalty_points, 0),
          COALESCE(cp.loyalty_points_catering, 0)
        ),
        created_account_dt_stamp = COALESCE(ca.created_account_dt_stamp, cp.created_at, ca.created_at),
        updated_pw_dt_stamp = COALESCE(ca.updated_pw_dt_stamp, cp.updated_at, ca.updated_at)
      FROM customer_profiles cp
      WHERE LOWER(TRIM(cp.user_email)) = LOWER(TRIM(COALESCE(ca.email, '')))
    `);

    await pool.query(`
      INSERT INTO customer_accounts (
        email, password_hash, full_name, contact_number, is_verified,
        customer_id, primary_delivery_address, delivery_map_confirmed, delivery_lat, delivery_lng,
        other_delivery_addresses, restaurant_loyalty_points, catering_loyalty_points,
        created_account_dt_stamp, updated_pw_dt_stamp
      )
      SELECT
        LOWER(TRIM(cp.user_email)),
        '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy',
        COALESCE(NULLIF(TRIM(cp.full_name), ''), ''),
        COALESCE(NULLIF(TRIM(cp.contact_number), ''), ''),
        TRUE,
        NULLIF(TRIM(cp.id), ''),
        COALESCE(NULLIF(TRIM(cp.delivery_address), ''), ''),
        COALESCE(cp.delivery_map_confirmed, FALSE),
        cp.delivery_lat,
        cp.delivery_lng,
        COALESCE(cp.delivery_addresses, '[]'::jsonb),
        COALESCE(cp.loyalty_points_restaurant, cp.loyalty_points, 0),
        COALESCE(cp.loyalty_points_catering, 0),
        COALESCE(cp.created_at, NOW()),
        COALESCE(cp.updated_at, NOW())
      FROM customer_profiles cp
      WHERE TRIM(cp.user_email) <> ''
        AND NOT EXISTS (
          SELECT 1 FROM customer_accounts ca
          WHERE LOWER(TRIM(ca.email)) = LOWER(TRIM(cp.user_email))
        )
      ON CONFLICT (email) DO NOTHING
    `);
  }

  if (await tableExists(pool, "customer_signup_otp_challenges")) {
    await pool.query(`
      UPDATE customer_accounts ca
      SET
        signup_otp_code = COALESCE(ca.signup_otp_code, c.otp_code),
        signup_otp_code_expiry = COALESCE(ca.signup_otp_code_expiry, c.otp_expires_at)
      FROM customer_signup_otp_challenges c
      WHERE LOWER(TRIM(ca.email)) = LOWER(TRIM(c.email))
    `);
    await safeExec(pool, `DROP TABLE IF EXISTS customer_signup_otp_challenges CASCADE`);
  }

  await pool.query(`
    WITH numbered AS (
      SELECT
        email,
        'CUS-' || LPAD(
          ROW_NUMBER() OVER (ORDER BY COALESCE(created_account_dt_stamp, created_at, NOW()), email)::text,
          4,
          '0'
        ) AS new_customer_id
      FROM customer_accounts
      WHERE customer_id IS NULL OR TRIM(customer_id) = ''
    )
    UPDATE customer_accounts ca
    SET customer_id = n.new_customer_id
    FROM numbered n
    WHERE ca.email = n.email
  `);

  await safeExec(
    pool,
    `CREATE UNIQUE INDEX IF NOT EXISTS customer_accounts_customer_id_uq ON customer_accounts (customer_id) WHERE customer_id IS NOT NULL`,
  );
  await renameColumnIfExists(pool, "customer_accounts", "phone_number", "contact_number_legacy");
}

async function normalizeRestaurantOrders(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "restaurant_orders"))) return;

  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_id TEXT`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS total_cost NUMERIC(12,2)`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_notes TEXT NOT NULL DEFAULT ''`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS tray_items JSONB NOT NULL DEFAULT '[]'::jsonb`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_reference_initial TEXT`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_reference_balance TEXT`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_proof_initial TEXT`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_proof_balance TEXT`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_uploaded_initial BOOLEAN NOT NULL DEFAULT FALSE`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_uploaded_balance BOOLEAN NOT NULL DEFAULT FALSE`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_confirmed_initial BOOLEAN NOT NULL DEFAULT FALSE`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS payment_confirmed_balance BOOLEAN NOT NULL DEFAULT FALSE`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_status TEXT`);
  await pool.query(
    `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS loyalty_points_restaurant_obtained INTEGER NOT NULL DEFAULT 0`,
  );
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS loyalty_reward_restaurant_obtained TEXT`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS submitted_order_dt_stamp TIMESTAMPTZ`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS last_updated_order_status_dt_stamp TIMESTAMPTZ`);

  await copyColumnIfBothExist(pool, "restaurant_orders", "order_id", "order_no");
  await copyColumnIfBothExist(pool, "restaurant_orders", "total_cost", "total_amount");
  await copyColumnIfBothExist(pool, "restaurant_orders", "total_cost", "total");
  await copyColumnIfBothExist(pool, "restaurant_orders", "delivery_notes", "note");
  await copyColumnIfBothExist(pool, "restaurant_orders", "payment_proof_initial", "payment_proof");
  await copyColumnIfBothExist(pool, "restaurant_orders", "payment_proof_balance", "supplemental_payment_proof");
  await copyColumnIfBothExist(pool, "restaurant_orders", "payment_uploaded_initial", "payment_uploaded");
  await copyColumnIfBothExist(pool, "restaurant_orders", "loyalty_points_restaurant_obtained", "points_earned");
  await copyColumnIfBothExist(pool, "restaurant_orders", "submitted_order_dt_stamp", "created_at");
  await copyColumnIfBothExist(pool, "restaurant_orders", "last_updated_order_status_dt_stamp", "updated_at");

  if (await columnExists(pool, "restaurant_orders", "order_lines_snapshot")) {
    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET tray_items = COALESCE(NULLIF(tray_items, '[]'::jsonb), order_lines_snapshot, items, '[]'::jsonb)
       WHERE tray_items IS NULL OR tray_items = '[]'::jsonb`,
    );
  }

  if (await columnExists(pool, "restaurant_orders", "fulfillment_stage")) {
    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET order_status = COALESCE(NULLIF(TRIM(order_status), ''), fulfillment_stage, status)
       WHERE order_status IS NULL OR TRIM(order_status) = ''`,
    );
  } else if (await columnExists(pool, "restaurant_orders", "status")) {
    await safeExec(
      pool,
      `UPDATE restaurant_orders SET order_status = COALESCE(NULLIF(TRIM(order_status), ''), status)
       WHERE order_status IS NULL OR TRIM(order_status) = ''`,
    );
  }

  if (await columnExists(pool, "restaurant_orders", "cashier_amount_received")) {
    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET cashier_amount_received_initial = COALESCE(cashier_amount_received_initial, cashier_amount_received)
       WHERE cashier_amount_received_initial IS NULL`,
    );
  }
  if (await columnExists(pool, "restaurant_orders", "cashier_secondary_amount_received")) {
    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET cashier_amount_received_balance = COALESCE(
         cashier_amount_received_balance, cashier_secondary_amount_received
       )
       WHERE cashier_amount_received_balance IS NULL`,
    );
  }

  await pool.query(`
    UPDATE restaurant_orders ro
    SET customer_id = ca.customer_id
    FROM customer_accounts ca
    WHERE ca.customer_id IS NOT NULL
      AND (
        (ro.user_email IS NOT NULL AND LOWER(TRIM(ro.user_email)) = LOWER(TRIM(ca.email)))
        OR (ro.customer_id IS NOT NULL AND ro.customer_id::text = ca.id::text)
      )
      AND (ro.customer_id IS NULL OR ro.customer_id::text !~ '^CUS-')
  `);

  await pool.query(`
    UPDATE restaurant_orders
    SET order_id = CASE
      WHEN order_id IS NOT NULL AND TRIM(order_id) ~ '^ORD-' THEN order_id
      WHEN order_no IS NOT NULL AND TRIM(order_no) ~ '^ORD-' THEN order_no
      WHEN mobile_id IS NOT NULL THEN 'ORD-' || LPAD(mobile_id::text, 6, '0')
      ELSE order_id
    END
    WHERE order_id IS NULL OR TRIM(order_id) = '' OR order_id !~ '^ORD-'
  `);
}

async function normalizeCateringOrders(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "catering_orders"))) return;
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS catering_id TEXT`);
  await copyColumnIfBothExist(pool, "catering_orders", "catering_id", "transaction_no");
  await pool.query(`
    UPDATE catering_orders
    SET catering_id = 'TR-' || LPAD(
      COALESCE(NULLIF(REGEXP_REPLACE(catering_id, '\\D', '', 'g'), ''), id::text),
      6, '0'
    )
    WHERE catering_id IS NULL OR TRIM(catering_id) = '' OR catering_id !~ '^TR-'
  `);
}

async function normalizeEventOrders(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "event_orders"))) return;
  await pool.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS event_id TEXT`);
  await copyColumnIfBothExist(pool, "event_orders", "event_id", "transaction_no");
  await pool.query(`
    UPDATE event_orders
    SET event_id = 'TR-' || LPAD(
      COALESCE(NULLIF(REGEXP_REPLACE(event_id, '\\D', '', 'g'), ''), id::text),
      6, '0'
    )
    WHERE event_id IS NULL OR TRIM(event_id) = '' OR event_id !~ '^TR-'
  `);
}

async function normalizeIdCounter(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "id_counter"))) {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS id_counter (
        counter_key TEXT PRIMARY KEY,
        last_value INTEGER NOT NULL DEFAULT 0
      )
    `);
  }
  await safeExec(pool, `DELETE FROM id_counter WHERE counter_key IN ('INQ', 'MINQ')`);
  await pool.query(`
    INSERT INTO id_counter (counter_key, last_value) VALUES ('TR', 0), ('USR', 0)
    ON CONFLICT (counter_key) DO NOTHING
  `);
  await safeExec(
    pool,
    `UPDATE id_counter SET last_value = GREATEST(
      last_value,
      COALESCE((
        SELECT MAX(CAST(SUBSTRING(catering_id FROM 4) AS INT))
        FROM catering_orders WHERE catering_id ~ '^TR-[0-9]+$'
      ), 0),
      COALESCE((
        SELECT MAX(CAST(SUBSTRING(event_id FROM 4) AS INT))
        FROM event_orders WHERE event_id ~ '^TR-[0-9]+$'
      ), 0),
      COALESCE((
        SELECT MAX(CAST(SUBSTRING(transaction_no FROM 4) AS INT))
        FROM catering_orders WHERE transaction_no ~ '^TR-[0-9]+$'
      ), 0),
      COALESCE((
        SELECT MAX(CAST(SUBSTRING(transaction_no FROM 4) AS INT))
        FROM event_orders WHERE transaction_no ~ '^TR-[0-9]+$'
      ), 0)
    ) WHERE counter_key = 'TR'`,
  );
  await safeExec(
    pool,
    `UPDATE id_counter SET last_value = GREATEST(
      last_value,
      COALESCE((SELECT MAX(CAST(SUBSTRING(id FROM 5) AS INT)) FROM users WHERE id ~ '^USR-[0-9]+$'), 0)
    ) WHERE counter_key = 'USR'`,
  );
}

async function normalizeMenuDishes(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "menu_dishes"))) return;
  await renameColumnIfExists(pool, "menu_dishes", "type", "meal_type");
  await pool.query(`
    CREATE TABLE IF NOT EXISTS menu_dishes_meal_types (
      meal_type_id BIGSERIAL PRIMARY KEY,
      meal_type_name TEXT NOT NULL UNIQUE
    )
  `);
  const mealCol = (await columnExists(pool, "menu_dishes", "meal_type")) ? "meal_type" : "type";
  await safeExec(
    pool,
    `INSERT INTO menu_dishes_meal_types (meal_type_name)
     SELECT DISTINCT TRIM(md.${mealCol})
     FROM menu_dishes md
     WHERE TRIM(COALESCE(md.${mealCol}, '')) <> ''
     ON CONFLICT (meal_type_name) DO NOTHING`,
  );
}

async function dropLegacyTables(pool: pg.Pool): Promise<void> {
  await safeExec(pool, `DROP TABLE IF EXISTS items CASCADE`);
  await safeExec(pool, `DROP TABLE IF EXISTS rewards CASCADE`);
  await safeExec(pool, `DROP TABLE IF EXISTS customer_profiles CASCADE`);
}
