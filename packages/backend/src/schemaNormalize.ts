import type pg from "pg";
import { formatCusId, setIdCounterLastNumber, syncCusCounterFromAccounts } from "./idCounters.js";

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

async function columnDataType(pool: pg.Pool, table: string, column: string): Promise<string> {
  const { rows } = await pool.query<{ data_type: string }>(
    `SELECT data_type
     FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
     LIMIT 1`,
    [table, column],
  );
  return String(rows[0]?.data_type ?? "text").toLowerCase();
}

function castExpressionForTarget(sourceCol: string, targetType: string): string {
  const t = targetType.toLowerCase();
  if (t.includes("timestamp")) return `${sourceCol}::timestamptz`;
  if (t === "integer") return `${sourceCol}::integer`;
  if (t === "bigint") return `${sourceCol}::bigint`;
  if (t === "numeric" || t === "double precision" || t === "real") return `${sourceCol}::numeric`;
  if (t === "boolean") return `${sourceCol}::boolean`;
  if (t === "jsonb") return `${sourceCol}::jsonb`;
  if (t === "uuid") return `${sourceCol}::uuid`;
  return `${sourceCol}::text`;
}

async function copyColumnIfBothExist(
  pool: pg.Pool,
  table: string,
  target: string,
  source: string,
): Promise<void> {
  if (!(await columnExists(pool, table, target))) return;
  if (!(await columnExists(pool, table, source))) return;
  const targetType = await columnDataType(pool, table, target);
  const sourceExpr = castExpressionForTarget(source, targetType);
  const emptyCheck =
    targetType.includes("timestamp") || targetType === "boolean" || targetType === "jsonb"
      ? `${target} IS NULL`
      : `${target} IS NULL OR TRIM(${target}::text) = ''`;
  await pool.query(
    `UPDATE ${table}
     SET ${target} = COALESCE(${target}, ${sourceExpr})
     WHERE ${emptyCheck}`,
  );
}

async function forceDropColumn(pool: pg.Pool, table: string, column: string): Promise<void> {
  if (!(await columnExists(pool, table, column))) return;
  try {
    await pool.query(`ALTER TABLE ${table} DROP COLUMN IF EXISTS ${column} CASCADE`);
  } catch (err) {
    console.warn(
      `[schema] drop column ${table}.${column} failed:`,
      err instanceof Error ? err.message : err,
    );
  }
}

async function pruneTableColumns(pool: pg.Pool, table: string, keep: ReadonlySet<string>): Promise<void> {
  if (!(await tableExists(pool, table))) return;
  const { rows } = await pool.query<{ column_name: string }>(
    `SELECT column_name FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = $1`,
    [table],
  );
  const extras = rows.map((r) => r.column_name).filter((c) => !keep.has(c));
  for (const column_name of extras) {
    await forceDropColumn(pool, table, column_name);
  }
  if (extras.length > 0) {
    console.info(`[schema] pruned ${extras.length} column(s) from ${table}: ${extras.join(", ")}`);
  }
}

const CUSTOMER_ACCOUNTS_COLUMNS = new Set([
  "id",
  "customer_id",
  "email",
  "password_hash",
  "full_name",
  "contact_number",
  "is_verified",
  "signup_otp_code",
  "signup_otp_code_expiry",
  "forgot_password_otp_code",
  "forgot_password_otp_code_expiry",
  "restaurant_loyalty_points",
  "catering_loyalty_points",
  "primary_delivery_address",
  "other_delivery_addresses",
  "delivery_map_confirmed",
  "delivery_lat",
  "delivery_lng",
  "created_account_dt_stamp",
  "updated_pw_dt_stamp",
]);

const RESTAURANT_ORDERS_COLUMNS = new Set([
  "id",
  "mobile_id",
  "order_id",
  "customer_id",
  "full_name",
  "contact_number",
  "delivery_address",
  "delivery_lat",
  "delivery_lng",
  "tray_items",
  "total_cost",
  "delivery_notes",
  "delivery_time",
  "payment_reference_initial",
  "payment_reference_balance",
  "payment_proof_initial",
  "payment_proof_balance",
  "payment_uploaded_initial",
  "payment_uploaded_balance",
  "payment_confirmed_initial",
  "payment_confirmed_balance",
  "order_status",
  "loyalty_points_restaurant_obtained",
  "loyalty_reward_restaurant_obtained",
  "delivery_tracking_url",
  "submitted_order_dt_stamp",
  "last_updated_order_status_dt_stamp",
  "order_source",
  "cashier_amount_received_initial",
  "cashier_amount_received_balance",
  "user_email",
  "guest_contact_email",
  "payment_mode",
  "created_at",
  "updated_at",
]);

const CATERING_ORDERS_COLUMNS = new Set([
  "id",
  "catering_id",
  "customer_id",
  "source",
  "status",
  "order_type",
  "event_title",
  "event_type",
  "formality_level",
  "event_setting",
  "customer_name",
  "contact_person",
  "contact_number",
  "email_address",
  "address",
  "schedule_slots",
  "guest_count",
  "pax_buffer",
  "menu",
  "created_at",
  "updated_at",
  "stage_entered_at",
  "down_payment_amount",
  "down_payment_status",
  "down_payment_proof",
  "full_payment_amount",
  "full_payment_status",
  "full_payment_proof",
  "additional_costs",
  "inquiry_additional_costs",
  "stage_additional_costs",
  "total_cost",
  "estimated_cost",
  "labor_cost",
  "travel_cost",
  "cost_breakdown",
  "loyalty_points_catering_obtained",
  "loyalty_reward_catering_obtained",
  "payment_method",
  "checklist",
  "full_payment_due_at",
  "created_by",
  "updated_by",
]);

const EVENT_ORDERS_COLUMNS = new Set([
  ...[...CATERING_ORDERS_COLUMNS].filter((c) => c !== "catering_id"),
  "event_id",
  "theme_design",
  "seating_plan",
  "actual_event_images",
]);

/** Idempotent schema alignment: merge duplicates, preserve row data. */
export async function runSchemaNormalize(pool: pg.Pool): Promise<void> {
  await normalizeAiGenerations(pool);
  await normalizeCustomerAccountsAndMergeProfiles(pool);
  await repairRestaurantOrdersIdentity(pool);
  await normalizeRestaurantOrders(pool);
  await normalizeCateringOrders(pool);
  await normalizeEventOrders(pool);
  await normalizeIdCounters(pool);
  await normalizeMenuDishes(pool);
  await migratePostAnalysisIntoChecklistAndDrop(pool);
  await normalizeUsersStaffIds(pool);

  await normalizeCanonicalBusinessIds(pool);
  await dedupeCustomerAccountIds(pool);
  await pruneCanonicalColumns(pool);
  await dropLegacyTables(pool);
  console.info("[schema] normalize complete");
}

async function dropColumnIfExists(pool: pg.Pool, table: string, column: string): Promise<void> {
  if (!(await columnExists(pool, table, column))) return;
  await safeExec(pool, `ALTER TABLE ${table} DROP COLUMN IF EXISTS ${column}`);
}

/** Internal PK on users.id; USR-**** lives in staff_id. */
async function normalizeUsersStaffIds(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "users"))) return;

  await pool.query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS staff_id TEXT`);

  await safeExec(
    pool,
    `UPDATE users
     SET staff_id = id::text
     WHERE (staff_id IS NULL OR TRIM(staff_id) = '')
       AND id::text ~ '^USR-'`,
  );

  await safeExec(
    pool,
    `UPDATE users
     SET id = gen_random_uuid()::text
     WHERE id::text ~ '^USR-'`,
  );

  await safeExec(
    pool,
    `WITH numbered AS (
       SELECT email,
              'USR-' || LPAD(
                ROW_NUMBER() OVER (ORDER BY COALESCE(created_at, NOW()), email))::text,
                4,
                '0'
              ) AS new_staff_id
       FROM users
       WHERE staff_id IS NULL OR TRIM(staff_id) = ''
     )
     UPDATE users u
     SET staff_id = n.new_staff_id
     FROM numbered n
     WHERE u.email = n.email`,
  );

  await safeExec(
    pool,
    `WITH dups AS (
       SELECT staff_id, MIN(email) AS keep_email
       FROM users
       WHERE staff_id IS NOT NULL AND TRIM(staff_id) <> ''
       GROUP BY staff_id
       HAVING COUNT(*) > 1
     )
     UPDATE users u
     SET staff_id = NULL
     FROM dups d
     WHERE u.staff_id = d.staff_id AND u.email <> d.keep_email`,
  );

  await safeExec(
    pool,
    `WITH numbered AS (
       SELECT email,
              'USR-' || LPAD(
                (10000 + ROW_NUMBER() OVER (ORDER BY email))::text,
                4,
                '0'
              ) AS new_staff_id
       FROM users
       WHERE staff_id IS NULL OR TRIM(staff_id) = ''
     )
     UPDATE users u
     SET staff_id = n.new_staff_id
     FROM numbered n
     WHERE u.email = n.email`,
  );

  await safeExec(
    pool,
    `CREATE UNIQUE INDEX IF NOT EXISTS users_staff_id_uq ON users (staff_id) WHERE staff_id IS NOT NULL`,
  );
}

/** Sort key for customer renumber — only references columns that still exist (created_at may be pruned). */
async function customerAccountSortKeySql(pool: pg.Pool): Promise<string> {
  const hasStamp = await columnExists(pool, "customer_accounts", "created_account_dt_stamp");
  const hasCreatedAt = await columnExists(pool, "customer_accounts", "created_at");
  if (hasStamp && hasCreatedAt) {
    return "COALESCE(created_account_dt_stamp, created_at, NOW())";
  }
  if (hasStamp) {
    return "COALESCE(created_account_dt_stamp, NOW())";
  }
  if (hasCreatedAt) {
    return "COALESCE(created_at, NOW())";
  }
  return "NOW()";
}

/** Assign unique CUS-0001… sequentially by created_account_dt_stamp (earliest first). */
export async function dedupeCustomerAccountIds(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "customer_accounts"))) return;
  if (!(await columnExists(pool, "customer_accounts", "customer_id"))) return;

  const sortKey = await customerAccountSortKeySql(pool);

  const { rows: dupBefore } = await pool.query<{ customer_id: string; n: string }>(
    `SELECT customer_id::text AS customer_id, COUNT(*)::text AS n
     FROM customer_accounts
     WHERE customer_id IS NOT NULL AND TRIM(customer_id::text) <> ''
     GROUP BY customer_id
     HAVING COUNT(*) > 1`,
  );
  if (dupBefore.length === 0) {
    await pool.query(
      `CREATE UNIQUE INDEX IF NOT EXISTS customer_accounts_customer_id_uq ON customer_accounts (customer_id)`,
    );
    return;
  }

  console.info(
    `[schema] customer_id duplicates before renumber: ${dupBefore.map((r) => `${r.customer_id}×${r.n}`).join(", ")}`,
  );

  await pool.query(`DROP INDEX IF EXISTS customer_accounts_customer_id_uq`);

  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    // Pooled connections reuse sessions; drop leftover temp table from a prior pass on this connection.
    await client.query(`DROP TABLE IF EXISTS customer_id_remap`);

    await client.query(`
      CREATE TEMP TABLE customer_id_remap AS
      SELECT
        LOWER(TRIM(email)) AS email_key,
        NULLIF(TRIM(customer_id::text), '') AS old_customer_id,
        'CUS-' || LPAD(
          ROW_NUMBER() OVER (
            ORDER BY ${sortKey}, LOWER(TRIM(email))
          )::text,
          4,
          '0'
        ) AS new_customer_id
      FROM customer_accounts
      WHERE email IS NOT NULL AND TRIM(email) <> ''
    `);

    if (await tableExists(pool, "restaurant_orders")) {
      if (await columnExists(pool, "restaurant_orders", "customer_id")) {
        await client.query(`
          UPDATE restaurant_orders ro
          SET customer_id = m.new_customer_id
          FROM customer_id_remap m
          WHERE ro.customer_id IS NOT NULL
            AND TRIM(ro.customer_id::text) <> ''
            AND ro.customer_id::text = m.old_customer_id
        `);
      }
      if (await columnExists(pool, "restaurant_orders", "user_email")) {
        await client.query(`
          UPDATE restaurant_orders ro
          SET customer_id = m.new_customer_id
          FROM customer_id_remap m
          WHERE LOWER(TRIM(COALESCE(ro.user_email, ''))) = m.email_key
        `);
      }
    }

    for (const table of ["catering_orders", "event_orders"] as const) {
      if (!(await tableExists(pool, table))) continue;
      if (!(await columnExists(pool, table, "customer_id"))) continue;
      await client.query(`
        UPDATE ${table} o
        SET customer_id = m.new_customer_id
        FROM customer_id_remap m
        WHERE o.customer_id IS NOT NULL
          AND TRIM(o.customer_id::text) <> ''
          AND o.customer_id::text = m.old_customer_id
      `);
      if (await columnExists(pool, table, "email_address")) {
        await client.query(`
          UPDATE ${table} o
          SET customer_id = m.new_customer_id
          FROM customer_id_remap m
          WHERE LOWER(TRIM(COALESCE(o.email_address, ''))) = m.email_key
        `);
      }
    }

    const { rows: updated } = await client.query<{ n: string }>(`
      UPDATE customer_accounts ca
      SET customer_id = m.new_customer_id
      FROM customer_id_remap m
      WHERE LOWER(TRIM(ca.email)) = m.email_key
      RETURNING 1 AS n
    `);

    const accountCount = Number(updated.length) || 0;
    if (await tableExists(pool, "id_counters")) {
      await setIdCounterLastNumber(client, "CUS", accountCount);
    }

    await client.query("COMMIT");
    console.info(
      `[schema] customer_id renumbered: ${accountCount} account(s) → CUS-0001 … ${formatCusId(accountCount)} by created_account_dt_stamp`,
    );
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    console.error("[schema] customer_id renumber rolled back:", err instanceof Error ? err.message : err);
    throw err;
  } finally {
    await client.query(`DROP TABLE IF EXISTS customer_id_remap`).catch(() => {});
    client.release();
  }

  const { rows: dupAfter } = await pool.query<{ customer_id: string; n: string }>(
    `SELECT customer_id::text AS customer_id, COUNT(*)::text AS n
     FROM customer_accounts
     WHERE customer_id IS NOT NULL AND TRIM(customer_id::text) <> ''
     GROUP BY customer_id
     HAVING COUNT(*) > 1`,
  );
  if (dupAfter.length > 0) {
    console.error(
      `[schema] customer_id still duplicated after renumber: ${dupAfter.map((r) => `${r.customer_id}×${r.n}`).join(", ")}`,
    );
    throw new Error("customer_id renumber did not remove all duplicates");
  }

  await pool.query(
    `CREATE UNIQUE INDEX IF NOT EXISTS customer_accounts_customer_id_uq ON customer_accounts (customer_id)`,
  );
}

/** Enforce unique business ids and align FKs to customer_accounts.customer_id. */
async function normalizeCanonicalBusinessIds(pool: pg.Pool): Promise<void> {
  if (await tableExists(pool, "customer_accounts")) {
    await pool.query(`ALTER TABLE customer_accounts ADD COLUMN IF NOT EXISTS id BIGSERIAL`);
    await safeExec(
      pool,
      `UPDATE customer_accounts SET id = nextval(pg_get_serial_sequence('customer_accounts', 'id'))
       WHERE id IS NULL`,
    );
    await safeExec(pool, `ALTER TABLE customer_accounts DROP CONSTRAINT IF EXISTS customer_accounts_pkey`);
    await safeExec(pool, `ALTER TABLE customer_accounts ADD PRIMARY KEY (id)`);
    await safeExec(
      pool,
      `CREATE UNIQUE INDEX IF NOT EXISTS customer_accounts_email_uq ON customer_accounts (email)`,
    );
  }

  if (await tableExists(pool, "restaurant_orders")) {
    await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_id TEXT`);

    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET order_id = COALESCE(NULLIF(TRIM(order_id::text), ''), NULLIF(TRIM(order_no::text), ''))
       WHERE order_id IS NULL OR TRIM(order_id::text) = '' OR order_id::text !~ '^ORD-'`,
    );

    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET order_id = 'ORD-' || LPAD(mobile_id::text, 6, '0')
       WHERE (order_id IS NULL OR TRIM(order_id::text) = '' OR order_id::text !~ '^ORD-')
         AND mobile_id IS NOT NULL`,
    );

    await safeExec(
      pool,
      `WITH dups AS (
         SELECT order_id, MAX(mobile_id) AS keep_mobile_id
         FROM restaurant_orders
         WHERE order_id IS NOT NULL AND TRIM(order_id::text) <> ''
         GROUP BY order_id
         HAVING COUNT(*) > 1
       )
       UPDATE restaurant_orders ro
       SET order_id = 'ORD-' || LPAD(ro.mobile_id::text, 6, '0')
       FROM dups d
       WHERE ro.order_id = d.order_id AND ro.mobile_id <> d.keep_mobile_id`,
    );

    await safeExec(
      pool,
      `CREATE UNIQUE INDEX IF NOT EXISTS restaurant_orders_order_id_uq
       ON restaurant_orders (order_id) WHERE order_id IS NOT NULL AND TRIM(order_id::text) <> ''`,
    );

    if (await tableExists(pool, "customer_accounts")) {
      await safeExec(
        pool,
        `UPDATE restaurant_orders ro
         SET customer_id = ca.customer_id
         FROM customer_accounts ca
         WHERE ca.customer_id IS NOT NULL
           AND ca.customer_id ~ '^CUS-'
           AND ro.user_email IS NOT NULL
           AND LOWER(TRIM(ro.user_email)) = LOWER(TRIM(ca.email))
           AND (
             ro.customer_id IS NULL
             OR TRIM(ro.customer_id::text) = ''
             OR ro.customer_id::text !~ '^CUS-'
           )`,
      );
    }
  }

  for (const table of ["catering_orders", "event_orders"] as const) {
    if (!(await tableExists(pool, table))) continue;
    const bizCol = table === "catering_orders" ? "catering_id" : "event_id";
    await pool.query(`ALTER TABLE ${table} ADD COLUMN IF NOT EXISTS ${bizCol} TEXT`);

    if (await columnExists(pool, table, "transaction_no")) {
      await safeExec(
        pool,
        `UPDATE ${table}
         SET ${bizCol} = COALESCE(NULLIF(TRIM(${bizCol}::text), ''), NULLIF(TRIM(transaction_no::text), ''))
         WHERE ${bizCol} IS NULL OR TRIM(${bizCol}::text) = ''`,
      );
    }
    if (await columnExists(pool, table, "inquiry_id")) {
      await safeExec(
        pool,
        `UPDATE ${table}
         SET ${bizCol} = COALESCE(NULLIF(TRIM(${bizCol}::text), ''), NULLIF(TRIM(inquiry_id::text), ''))
         WHERE ${bizCol} IS NULL OR TRIM(${bizCol}::text) = ''`,
      );
    }

    await safeExec(
      pool,
      `UPDATE ${table}
       SET ${bizCol} = 'TR-' || LPAD(
         COALESCE(NULLIF(REGEXP_REPLACE(${bizCol}::text, '\\D', '', 'g'), ''), id::text),
         6,
         '0'
       )
       WHERE ${bizCol} IS NULL OR TRIM(${bizCol}::text) = '' OR ${bizCol}::text !~ '^TR-'`,
    );
  }

  await safeExec(
    pool,
    `WITH all_tx AS (
       SELECT 'catering_orders'::text AS tbl, id::text AS row_id, catering_id::text AS biz_id
       FROM catering_orders
       WHERE catering_id IS NOT NULL AND TRIM(catering_id::text) <> ''
       UNION ALL
       SELECT 'event_orders', id::text, event_id::text
       FROM event_orders
       WHERE event_id IS NOT NULL AND TRIM(event_id::text) <> ''
     ),
     ranked AS (
       SELECT tbl, row_id, biz_id,
              ROW_NUMBER() OVER (PARTITION BY biz_id ORDER BY tbl, row_id) AS rn
       FROM all_tx
     )
     UPDATE catering_orders c
     SET catering_id = 'TR-' || LPAD(c.id::text, 6, '0')
     FROM ranked r
     WHERE r.tbl = 'catering_orders' AND c.id::text = r.row_id AND r.rn > 1`,
  );
  await safeExec(
    pool,
    `WITH all_tx AS (
       SELECT 'catering_orders'::text AS tbl, id::text AS row_id, catering_id::text AS biz_id
       FROM catering_orders
       WHERE catering_id IS NOT NULL AND TRIM(catering_id::text) <> ''
       UNION ALL
       SELECT 'event_orders', id::text, event_id::text
       FROM event_orders
       WHERE event_id IS NOT NULL AND TRIM(event_id::text) <> ''
     ),
     ranked AS (
       SELECT tbl, row_id, biz_id,
              ROW_NUMBER() OVER (PARTITION BY biz_id ORDER BY tbl, row_id) AS rn
       FROM all_tx
     )
     UPDATE event_orders e
     SET event_id = 'TR-' || LPAD(e.id::text, 6, '0')
     FROM ranked r
     WHERE r.tbl = 'event_orders' AND e.id::text = r.row_id AND r.rn > 1`,
  );

  await safeExec(
    pool,
    `CREATE UNIQUE INDEX IF NOT EXISTS catering_orders_catering_id_uq
     ON catering_orders (catering_id) WHERE catering_id IS NOT NULL AND TRIM(catering_id::text) <> ''`,
  );
  await safeExec(
    pool,
    `CREATE UNIQUE INDEX IF NOT EXISTS event_orders_event_id_uq
     ON event_orders (event_id) WHERE event_id IS NOT NULL AND TRIM(event_id::text) <> ''`,
  );
}

async function pruneCanonicalColumns(pool: pg.Pool): Promise<void> {
  await pruneTableColumns(pool, "customer_accounts", CUSTOMER_ACCOUNTS_COLUMNS);
  await pruneTableColumns(pool, "restaurant_orders", RESTAURANT_ORDERS_COLUMNS);
  await pruneTableColumns(pool, "catering_orders", CATERING_ORDERS_COLUMNS);
  await pruneTableColumns(pool, "event_orders", EVENT_ORDERS_COLUMNS);
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
  await copyColumnIfBothExist(pool, "customer_accounts", "contact_number", "phone");
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
    // Do not copy cp.id into customer_id — legacy profiles often share duplicate CUS-* values.
    // dedupeCustomerAccountIds() assigns unique CUS-0001…

    const createdStampExpr = (await columnExists(pool, "customer_accounts", "created_at"))
      ? "COALESCE(ca.created_account_dt_stamp, cp.created_at, ca.created_at)"
      : "COALESCE(ca.created_account_dt_stamp, cp.created_at)";
    const updatedStampExpr = (await columnExists(pool, "customer_accounts", "updated_at"))
      ? "COALESCE(ca.updated_pw_dt_stamp, cp.updated_at, ca.updated_at)"
      : "COALESCE(ca.updated_pw_dt_stamp, cp.updated_at)";

    await pool.query(`
      UPDATE customer_accounts ca
      SET
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
        created_account_dt_stamp = ${createdStampExpr},
        updated_pw_dt_stamp = ${updatedStampExpr}
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
        NULL,
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
      ON CONFLICT (email) DO UPDATE SET
        full_name = COALESCE(NULLIF(TRIM(customer_accounts.full_name), ''), EXCLUDED.full_name),
        contact_number = COALESCE(NULLIF(TRIM(customer_accounts.contact_number), ''), EXCLUDED.contact_number),
        primary_delivery_address = COALESCE(
          NULLIF(TRIM(customer_accounts.primary_delivery_address), ''),
          EXCLUDED.primary_delivery_address
        ),
        restaurant_loyalty_points = GREATEST(
          COALESCE(customer_accounts.restaurant_loyalty_points, 0),
          COALESCE(EXCLUDED.restaurant_loyalty_points, 0)
        ),
        catering_loyalty_points = GREATEST(
          COALESCE(customer_accounts.catering_loyalty_points, 0),
          COALESCE(EXCLUDED.catering_loyalty_points, 0)
        )
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

}

/** Restore table PK `id`, business `order_id` (ORD-*), and FK `customer_id` (CUS-*). */
async function repairRestaurantOrdersIdentity(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "restaurant_orders"))) return;
  try {
    await repairRestaurantOrdersIdentityInner(pool);
  } catch (err) {
    console.warn(
      "[schema] repairRestaurantOrdersIdentity skipped:",
      err instanceof Error ? err.message : err,
    );
  }
}

async function repairRestaurantOrdersIdentityInner(pool: pg.Pool): Promise<void> {

  const hasId = await columnExists(pool, "restaurant_orders", "id");
  const hasOrderIdCol = await columnExists(pool, "restaurant_orders", "order_id");
  const orderIdType = hasOrderIdCol ? await columnDataType(pool, "restaurant_orders", "order_id") : "";

  // Undo mistaken rename of UUID primary key `id` → `order_id`.
  if (hasOrderIdCol && orderIdType === "uuid" && !hasId) {
    await safeExec(pool, `ALTER TABLE restaurant_orders RENAME COLUMN order_id TO id`);
  }

  const hasIdAfter = await columnExists(pool, "restaurant_orders", "id");
  const hasOrderIdAfter = await columnExists(pool, "restaurant_orders", "order_id");

  if (hasOrderIdAfter && !hasIdAfter) {
    const orderIdDt = await columnDataType(pool, "restaurant_orders", "order_id");
    if (orderIdDt === "uuid" || orderIdDt === "text") {
      await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS id UUID`);
      await safeExec(
        pool,
        `UPDATE restaurant_orders
         SET id = order_id::uuid
         WHERE id IS NULL AND order_id IS NOT NULL AND order_id::text ~ '^[0-9a-f]{8}-'`,
      );
    }
  }

  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS id UUID`);
  await safeExec(
    pool,
    `UPDATE restaurant_orders SET id = gen_random_uuid() WHERE id IS NULL`,
  );

  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_id TEXT`);

  if (await columnExists(pool, "restaurant_orders", "order_id")) {
    const orderIdDtNow = await columnDataType(pool, "restaurant_orders", "order_id");
    if (orderIdDtNow === "uuid") {
      // Move UUIDs into `id` before converting order_id to business TEXT (ORD-*).
      await safeExec(
        pool,
        `UPDATE restaurant_orders
         SET id = COALESCE(id, order_id)
         WHERE id IS NULL AND order_id IS NOT NULL`,
      );
      await safeExec(
        pool,
        `ALTER TABLE restaurant_orders ALTER COLUMN order_id TYPE TEXT USING order_id::text`,
      );
    }
  }

  // If order_id still holds UUID strings from a bad migration, move them to `id` and clear.
  if (await columnExists(pool, "restaurant_orders", "order_id")) {
    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET id = COALESCE(id, order_id::uuid)
       WHERE id IS NULL
         AND order_id IS NOT NULL
         AND TRIM(order_id::text) ~ '^[0-9a-f]{8}-'`,
    );
    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET order_id = NULL
       WHERE order_id IS NOT NULL AND TRIM(order_id::text) ~ '^[0-9a-f]{8}-'`,
    );
  }

  await safeExec(
    pool,
    `UPDATE restaurant_orders
     SET order_id = CASE
       WHEN order_id IS NOT NULL AND TRIM(order_id::text) ~ '^ORD-' THEN order_id::text
       WHEN order_no IS NOT NULL AND TRIM(order_no::text) ~ '^ORD-' THEN order_no::text
       WHEN mobile_id IS NOT NULL THEN 'ORD-' || LPAD(mobile_id::text, 6, '0')
       ELSE order_id::text
     END
     WHERE order_id IS NULL
        OR TRIM(order_id::text) = ''
        OR order_id::text !~ '^ORD-'`,
  );

  await safeExec(
    pool,
    `UPDATE restaurant_orders
     SET order_no = COALESCE(NULLIF(TRIM(order_no::text), ''), order_id::text)
     WHERE order_id IS NOT NULL
       AND (
         order_no IS NULL
         OR TRIM(order_no::text) = ''
         OR order_no::text !~ '^ORD-'
       )`,
  );

  // Ensure customer_id on orders is CUS-* from customer_accounts, not account UUID.
  if (await columnExists(pool, "restaurant_orders", "customer_id")) {
    const custType = await columnDataType(pool, "restaurant_orders", "customer_id");
    if (custType === "uuid") {
      await safeExec(pool, `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS customer_id_text TEXT`);
      await safeExec(
        pool,
        `UPDATE restaurant_orders ro
         SET customer_id_text = ca.customer_id
         FROM customer_accounts ca
         WHERE ca.customer_id IS NOT NULL
           AND ro.user_email IS NOT NULL
           AND LOWER(TRIM(ro.user_email)) = LOWER(TRIM(ca.email))`,
      );
      await safeExec(pool, `ALTER TABLE restaurant_orders DROP COLUMN IF EXISTS customer_id`);
      await safeExec(pool, `ALTER TABLE restaurant_orders RENAME COLUMN customer_id_text TO customer_id`);
    } else {
      await safeExec(
        pool,
        `UPDATE restaurant_orders ro
         SET customer_id = ca.customer_id
         FROM customer_accounts ca
         WHERE ca.customer_id IS NOT NULL
           AND ca.customer_id ~ '^CUS-'
           AND ro.user_email IS NOT NULL
           AND LOWER(TRIM(ro.user_email)) = LOWER(TRIM(ca.email))
           AND (
             ro.customer_id IS NULL
             OR TRIM(ro.customer_id::text) = ''
             OR ro.customer_id::text !~ '^CUS-'
           )`,
      );
    }
  }
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
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS full_name TEXT NOT NULL DEFAULT ''`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS contact_number TEXT NOT NULL DEFAULT ''`);
  await pool.query(`ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS delivery_address TEXT NOT NULL DEFAULT ''`);
  await pool.query(
    `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS cashier_amount_received_initial NUMERIC(12,2)`,
  );
  await pool.query(
    `ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS cashier_amount_received_balance NUMERIC(12,2)`,
  );
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
  if (await columnExists(pool, "restaurant_orders", "payment_reference")) {
    await safeExec(
      pool,
      `UPDATE restaurant_orders
       SET payment_reference_initial = COALESCE(NULLIF(TRIM(payment_reference_initial), ''), payment_reference)
       WHERE (payment_reference_initial IS NULL OR TRIM(payment_reference_initial) = '')
         AND payment_reference IS NOT NULL
         AND TRIM(payment_reference) <> ''
         AND payment_reference NOT LIKE 'curatering-mobile:%'`,
    );
  }
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
      AND ca.customer_id ~ '^CUS-'
      AND ro.user_email IS NOT NULL
      AND LOWER(TRIM(ro.user_email)) = LOWER(TRIM(ca.email))
      AND (
        ro.customer_id IS NULL
        OR TRIM(ro.customer_id::text) = ''
        OR ro.customer_id::text !~ '^CUS-'
      )
  `);

  await copyColumnIfBothExist(pool, "restaurant_orders", "full_name", "delivery_name");
  await copyColumnIfBothExist(pool, "restaurant_orders", "contact_number", "delivery_contact");
}

/** Copy legacy post_analysis column into checklist.post_analysis, then drop the column. */
async function migratePostAnalysisIntoChecklistAndDrop(pool: pg.Pool): Promise<void> {
  for (const table of ["catering_orders", "event_orders"] as const) {
    if (!(await tableExists(pool, table))) continue;
    if (!(await columnExists(pool, table, "post_analysis"))) continue;
    if (await columnExists(pool, table, "checklist")) {
      await safeExec(
        pool,
        `UPDATE ${table}
         SET checklist = CASE
           WHEN jsonb_typeof(COALESCE(checklist, '[]'::jsonb)) = 'array' THEN
             jsonb_build_object('items', COALESCE(checklist, '[]'::jsonb), 'post_analysis', post_analysis)
           ELSE
             COALESCE(checklist, '{}'::jsonb) || jsonb_build_object('post_analysis', post_analysis)
         END
         WHERE post_analysis IS NOT NULL
           AND post_analysis <> '{}'::jsonb`,
      );
    }
    await safeExec(pool, `ALTER TABLE ${table} DROP COLUMN IF EXISTS post_analysis`);
  }
}

async function normalizeCateringOrders(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "catering_orders"))) return;

  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS catering_id TEXT`);
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS event_title TEXT NOT NULL DEFAULT ''`);
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS event_type TEXT NOT NULL DEFAULT ''`);
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS formality_level TEXT NOT NULL DEFAULT ''`);
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS event_setting TEXT NOT NULL DEFAULT ''`);
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS pax_buffer INTEGER NOT NULL DEFAULT 0`);
  await pool.query(
    `ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS inquiry_additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`,
  );
  await pool.query(
    `ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS stage_additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`,
  );
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS estimated_cost NUMERIC(12,2)`);
  await pool.query(
    `ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS loyalty_points_catering_obtained INTEGER NOT NULL DEFAULT 0`,
  );
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS loyalty_reward_catering_obtained TEXT`);
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS down_payment_proof TEXT`);
  await pool.query(`ALTER TABLE catering_orders ADD COLUMN IF NOT EXISTS full_payment_proof TEXT`);

  await copyColumnIfBothExist(pool, "catering_orders", "catering_id", "transaction_no");
  await copyColumnIfBothExist(pool, "catering_orders", "catering_id", "inquiry_id");
  await copyColumnIfBothExist(pool, "catering_orders", "loyalty_points_catering_obtained", "points_earned");
  await copyColumnIfBothExist(pool, "catering_orders", "estimated_cost", "estimated_total");

  if (await columnExists(pool, "catering_orders", "theme_design")) {
    await safeExec(
      pool,
      `UPDATE catering_orders
       SET
         event_title = COALESCE(NULLIF(TRIM(event_title), ''), NULLIF(TRIM(theme_design->>'event_title'), ''), event_title),
         event_type = COALESCE(NULLIF(TRIM(event_type), ''), NULLIF(TRIM(theme_design->>'event_type'), ''), event_type),
         formality_level = COALESCE(
           NULLIF(TRIM(formality_level), ''),
           NULLIF(TRIM(theme_design->>'formality_level'), ''),
           formality_level
         ),
         event_setting = COALESCE(
           NULLIF(TRIM(event_setting), ''),
           NULLIF(TRIM(theme_design->>'event_setting'), ''),
           event_setting
         )
       WHERE theme_design IS NOT NULL AND theme_design <> '{}'::jsonb`,
    );
    await dropColumnIfExists(pool, "catering_orders", "theme_design");
  }
}

async function normalizeEventOrders(pool: pg.Pool): Promise<void> {
  if (!(await tableExists(pool, "event_orders"))) return;

  await pool.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS event_id TEXT`);
  await pool.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS seating_plan JSONB NOT NULL DEFAULT '{}'::jsonb`);
  await pool.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS pax_buffer INTEGER NOT NULL DEFAULT 0`);
  await pool.query(
    `ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS inquiry_additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`,
  );
  await pool.query(
    `ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS stage_additional_costs JSONB NOT NULL DEFAULT '[]'::jsonb`,
  );
  await pool.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS estimated_cost NUMERIC(12,2)`);
  await pool.query(
    `ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS loyalty_points_catering_obtained INTEGER NOT NULL DEFAULT 0`,
  );
  await pool.query(`ALTER TABLE event_orders ADD COLUMN IF NOT EXISTS loyalty_reward_catering_obtained TEXT`);

  await copyColumnIfBothExist(pool, "event_orders", "event_id", "transaction_no");
  await copyColumnIfBothExist(pool, "event_orders", "event_id", "inquiry_id");
  await copyColumnIfBothExist(pool, "event_orders", "loyalty_points_catering_obtained", "points_earned");
  await copyColumnIfBothExist(pool, "event_orders", "estimated_cost", "estimated_total");
}

/** `id_counters` in production: prefix (PK) + last_number + updated_at. */
async function normalizeIdCounters(pool: pg.Pool): Promise<void> {
  await safeExec(pool, `DROP TABLE IF EXISTS id_counter`);

  if (!(await tableExists(pool, "id_counters"))) {
    await pool.query(`
      CREATE TABLE id_counters (
        prefix text NOT NULL,
        last_number integer NOT NULL DEFAULT 0,
        updated_at timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT id_counters_pkey PRIMARY KEY (prefix)
      )
    `);
  } else if (!(await columnExists(pool, "id_counters", "prefix"))) {
    console.warn("[schema] id_counters exists but has no prefix column; skipping counter normalize");
    return;
  }

  const deleted = await pool.query(`DELETE FROM id_counters WHERE prefix IN ('INQ', 'MINQ')`);
  console.info(`[schema] id_counters: removed ${deleted.rowCount ?? 0} legacy INQ/MINQ row(s)`);

  await pool.query(`
    INSERT INTO id_counters (prefix, last_number) VALUES ('TR', 0), ('USR', 0), ('CUS', 0)
    ON CONFLICT (prefix) DO NOTHING
  `);

  await syncCusCounterFromAccounts(pool);

  const trParts: string[] = [];
  if (await tableExists(pool, "catering_orders")) {
    if (await columnExists(pool, "catering_orders", "catering_id")) {
      trParts.push(
        `COALESCE((SELECT MAX(CAST(SUBSTRING(catering_id FROM 4) AS INT)) FROM catering_orders WHERE catering_id ~ '^TR-[0-9]+$'), 0)`,
      );
    }
    if (await columnExists(pool, "catering_orders", "transaction_no")) {
      trParts.push(
        `COALESCE((SELECT MAX(CAST(SUBSTRING(transaction_no FROM 4) AS INT)) FROM catering_orders WHERE transaction_no ~ '^TR-[0-9]+$'), 0)`,
      );
    }
  }
  if (await tableExists(pool, "event_orders")) {
    if (await columnExists(pool, "event_orders", "event_id")) {
      trParts.push(
        `COALESCE((SELECT MAX(CAST(SUBSTRING(event_id FROM 4) AS INT)) FROM event_orders WHERE event_id ~ '^TR-[0-9]+$'), 0)`,
      );
    }
    if (await columnExists(pool, "event_orders", "transaction_no")) {
      trParts.push(
        `COALESCE((SELECT MAX(CAST(SUBSTRING(transaction_no FROM 4) AS INT)) FROM event_orders WHERE transaction_no ~ '^TR-[0-9]+$'), 0)`,
      );
    }
  }
  if (trParts.length > 0) {
    await pool.query(
      `UPDATE id_counters
       SET last_number = GREATEST(last_number, ${trParts.join(", ")}),
           updated_at = NOW()
       WHERE prefix = 'TR'`,
    );
  }

  if (await tableExists(pool, "users")) {
    const usrParts: string[] = [];
    if (await columnExists(pool, "users", "staff_id")) {
      usrParts.push(
        `COALESCE((SELECT MAX(CAST(SUBSTRING(staff_id FROM 5) AS INT)) FROM users WHERE staff_id ~ '^USR-[0-9]+$'), 0)`,
      );
    }
    if (await columnExists(pool, "users", "id")) {
      usrParts.push(
        `COALESCE((SELECT MAX(CAST(SUBSTRING(id::text FROM 5) AS INT)) FROM users WHERE id::text ~ '^USR-[0-9]+$'), 0)`,
      );
    }
    if (usrParts.length > 0) {
      await pool.query(
        `UPDATE id_counters
         SET last_number = GREATEST(last_number, ${usrParts.join(", ")}),
             updated_at = NOW()
         WHERE prefix = 'USR'`,
      );
    }
  }

  const { rows } = await pool.query<{ prefix: string; last_number: number }>(
    `SELECT prefix, last_number FROM id_counters ORDER BY prefix`,
  );
  console.info(
    `[schema] id_counters: ${rows.map((r) => `${r.prefix}=${r.last_number}`).join(", ") || "(empty)"}`,
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
