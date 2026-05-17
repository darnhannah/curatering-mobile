import type pg from "pg";

export function formatCusId(seq: number): string {
  return `CUS-${String(seq).padStart(4, "0")}`;
}

/** Atomically increment `id_counters.last_value` and return the new value. */
export async function bumpIdCounter(
  client: pg.Pool | pg.PoolClient,
  counterKey: string,
  steps = 1,
): Promise<number> {
  const { rows } = await client.query<{ last_value: string | number }>(
    `UPDATE id_counters
     SET last_value = last_value + $2
     WHERE counter_key = $1
     RETURNING last_value`,
    [counterKey, steps],
  );
  if (rows.length === 0) {
    throw new Error(`id_counters row missing for key "${counterKey}"`);
  }
  return Number(rows[0].last_value);
}

export async function ensureIdCounterRow(
  pool: pg.Pool,
  counterKey: string,
  initialMin = 0,
): Promise<void> {
  await pool.query(
    `INSERT INTO id_counters (counter_key, last_value) VALUES ($1, $2)
     ON CONFLICT (counter_key) DO NOTHING`,
    [counterKey, initialMin],
  );
}

export async function syncCusCounterFromAccounts(pool: pg.Pool): Promise<void> {
  await ensureIdCounterRow(pool, "CUS", 0);
  await pool.query(
    `UPDATE id_counters
     SET last_value = GREATEST(
       last_value,
       COALESCE((
         SELECT MAX(CAST(SUBSTRING(customer_id FROM 5) AS INT))
         FROM customer_accounts
         WHERE customer_id ~ '^CUS-[0-9]+$'
       ), 0)
     )
     WHERE counter_key = 'CUS'`,
  );
}

/** Allocate the next CUS-**** using `id_counters` (must run inside a transaction for serial use). */
export async function nextCusIdFromCounter(client: pg.Pool | pg.PoolClient): Promise<string> {
  const seq = await bumpIdCounter(client, "CUS", 1);
  return formatCusId(seq);
}
