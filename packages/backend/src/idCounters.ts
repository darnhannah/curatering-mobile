import type pg from "pg";

/** Production `id_counters` uses `prefix` + `last_number` (not counter_key/last_value). */

export function formatCusId(seq: number): string {
  return `CUS-${String(seq).padStart(4, "0")}`;
}

export function formatTrId(seq: number): string {
  return `TR-${String(seq).padStart(6, "0")}`;
}

export async function ensureIdCounterRow(
  client: pg.Pool | pg.PoolClient,
  prefix: string,
  initialMin = 0,
): Promise<void> {
  await client.query(
    `INSERT INTO id_counters (prefix, last_number) VALUES ($1, $2)
     ON CONFLICT (prefix) DO NOTHING`,
    [prefix, initialMin],
  );
}

/** Atomically increment `id_counters.last_number` and return the new value. */
export async function bumpIdCounter(
  client: pg.Pool | pg.PoolClient,
  prefix: string,
  steps = 1,
): Promise<number> {
  const { rows } = await client.query<{ last_number: string | number }>(
    `UPDATE id_counters
     SET last_number = last_number + $2,
         updated_at = NOW()
     WHERE prefix = $1
     RETURNING last_number`,
    [prefix, steps],
  );
  if (rows.length === 0) {
    throw new Error(`id_counters row missing for prefix "${prefix}"`);
  }
  return Number(rows[0].last_number);
}

export async function syncCusCounterFromAccounts(pool: pg.Pool): Promise<void> {
  await ensureIdCounterRow(pool, "CUS", 0);
  await pool.query(
    `UPDATE id_counters
     SET last_number = GREATEST(
       last_number,
       COALESCE((
         SELECT MAX(CAST(SUBSTRING(customer_id FROM 5) AS INT))
         FROM customer_accounts
         WHERE customer_id ~ '^CUS-[0-9]+$'
       ), 0)
     ),
     updated_at = NOW()
     WHERE prefix = 'CUS'`,
  );
}

/** Allocate the next CUS-**** using `id_counters` (run inside a transaction when possible). */
export async function nextCusIdFromCounter(client: pg.Pool | pg.PoolClient): Promise<string> {
  const seq = await bumpIdCounter(client, "CUS", 1);
  return formatCusId(seq);
}

/** Allocate the next TR-****** using `id_counters`. */
export async function nextTrIdFromCounter(client: pg.Pool | pg.PoolClient): Promise<string> {
  const seq = await bumpIdCounter(client, "TR", 1);
  return formatTrId(seq);
}
