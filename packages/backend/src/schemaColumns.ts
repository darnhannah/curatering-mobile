/**
 * Cached information_schema lookups for production DBs with mixed column sets.
 */
import type pg from "pg";

const existsCache = new Map<string, boolean>();
const udtCache = new Map<string, string | null>();

export async function columnExists(pool: pg.Pool, table: string, column: string): Promise<boolean> {
  const key = `${table}.${column}`;
  if (existsCache.has(key)) return existsCache.get(key)!;
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2 LIMIT 1`,
    [table, column],
  );
  const ok = rows.length > 0;
  existsCache.set(key, ok);
  return ok;
}

export async function columnUdtName(pool: pg.Pool, table: string, column: string): Promise<string | null> {
  const key = `${table}.${column}.udt`;
  if (udtCache.has(key)) return udtCache.get(key)!;
  const { rows } = await pool.query(
    `SELECT udt_name FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2 LIMIT 1`,
    [table, column],
  );
  const udt = rows[0] ? String((rows[0] as { udt_name: string }).udt_name ?? "") : "";
  const val = udt || null;
  udtCache.set(key, val);
  return val;
}

/** MAX timestamp expression for menu_dishes realtime stamps (no bare updated_at). */
export async function menuDishesMaxStampExpr(pool: pg.Pool): Promise<string> {
  const hasUpdated = await columnExists(pool, "menu_dishes", "updated_at");
  const hasCreated = await columnExists(pool, "menu_dishes", "created_at");
  if (hasUpdated && hasCreated) {
    return `COALESCE((SELECT MAX(COALESCE(updated_at, created_at))::text FROM menu_dishes), '')`;
  }
  if (hasUpdated) {
    return `COALESCE((SELECT MAX(updated_at)::text FROM menu_dishes), '')`;
  }
  if (hasCreated) {
    return `COALESCE((SELECT MAX(created_at)::text FROM menu_dishes), '')`;
  }
  return `COALESCE((SELECT MAX(id::text) FROM menu_dishes), '')`;
}

/** Predicate: menu_dishes changed since $1 (parameter index 1). */
export async function menuDishesChangedSinceSql(pool: pg.Pool): Promise<string> {
  const hasUpdated = await columnExists(pool, "menu_dishes", "updated_at");
  const hasCreated = await columnExists(pool, "menu_dishes", "created_at");
  if (hasUpdated && hasCreated) {
    return `SELECT 1 FROM menu_dishes WHERE COALESCE(updated_at, created_at) > $1 LIMIT 1`;
  }
  if (hasUpdated) {
    return `SELECT 1 FROM menu_dishes WHERE updated_at > $1 LIMIT 1`;
  }
  if (hasCreated) {
    return `SELECT 1 FROM menu_dishes WHERE created_at > $1 LIMIT 1`;
  }
  return `SELECT 1 WHERE FALSE`;
}

/** Restaurant order change detection (canonical timestamps only). */
export const RESTAURANT_ORDER_CHANGED_SINCE_SQL = `COALESCE(
  last_updated_order_status_dt_stamp,
  submitted_order_dt_stamp,
  created_at
)`;

/** Loyalty/profile stamp on customer_accounts (no bare updated_at). */
export const CUSTOMER_ACCOUNT_STAMP_SQL = `COALESCE(updated_pw_dt_stamp, created_account_dt_stamp)`;

export async function tableExists(pool: pg.Pool, table: string): Promise<boolean> {
  const key = `table:${table}`;
  if (existsCache.has(key)) return existsCache.get(key)!;
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.tables
     WHERE table_schema = 'public' AND table_name = $1 LIMIT 1`,
    [table],
  );
  const ok = rows.length > 0;
  existsCache.set(key, ok);
  return ok;
}
