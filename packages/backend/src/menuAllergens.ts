/**
 * Allergen SQL helpers for menu_dishes (BIGINT[] allergen_id → menu_dishes_allergens.allergen_name).
 */
import type pg from "pg";
import { columnExists, tableExists } from "./schemaColumns.js";

/** Load allergen catalog for manager/menu editors. */
export async function queryAllergensCatalog(
  pool: pg.Pool,
): Promise<Array<{ id: string; name: string }>> {
  if (!(await tableExists(pool, "menu_dishes_allergens"))) return [];
  if (await columnExists(pool, "menu_dishes_allergens", "allergen_id")) {
    const { rows } = await pool.query(
      `SELECT allergen_id::text AS id, allergen_name AS name
       FROM menu_dishes_allergens
       ORDER BY allergen_name`,
    );
    return rows.map((r) => ({
      id: String((r as { id: string }).id ?? ""),
      name: String((r as { name: string }).name ?? "").trim(),
    }));
  }
  if (await columnExists(pool, "menu_dishes_allergens", "id")) {
    const nameCol = (await columnExists(pool, "menu_dishes_allergens", "allergen_name"))
      ? "allergen_name"
      : "name";
    const { rows } = await pool.query(
      `SELECT id::text AS id, ${nameCol} AS name
       FROM menu_dishes_allergens
       ORDER BY ${nameCol}`,
    );
    return rows.map((r) => ({
      id: String((r as { id: string }).id ?? ""),
      name: String((r as { name: string }).name ?? "").trim(),
    }));
  }
  return [];
}

/** Subquery expression: JSON text array of allergen names for a menu_dishes row alias `md`. */
export const MENU_DISH_ALLERGEN_NAMES_JSON_SQL = `
  COALESCE(
    (
      SELECT json_agg(ma.allergen_name ORDER BY ord)::text
      FROM unnest(COALESCE(md.allergens, '{}'::bigint[])) WITH ORDINALITY AS t(allergen_id, ord)
      INNER JOIN public.menu_dishes_allergens ma ON ma.allergen_id = t.allergen_id
    ),
    '[]'
  )
`.trim();

export function parseAllergenNamesFromRow(row: Record<string, unknown>): string[] {
  const raw = row.allergens ?? row.allergen_names ?? row.allergen_name_list;
  if (Array.isArray(raw)) {
    return raw.map((x) => String(x ?? "").trim()).filter((s) => s.length > 0);
  }
  if (typeof raw === "string" && raw.trim().startsWith("[")) {
    try {
      const arr = JSON.parse(raw) as unknown;
      if (Array.isArray(arr)) {
        return arr.map((x) => String(x ?? "").trim()).filter((s) => s.length > 0);
      }
    } catch {
      /* ignore */
    }
  }
  return [];
}
