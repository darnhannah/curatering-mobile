/**
 * menu_dishes SELECT builders — tolerate renamed/pruned columns in production.
 */
import type pg from "pg";
import { MENU_DISH_ALLERGEN_NAMES_JSON_SQL } from "./menuAllergens.js";

async function columnExists(pool: pg.Pool, table: string, column: string): Promise<boolean> {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2 LIMIT 1`,
    [table, column],
  );
  return rows.length > 0;
}

/** Minimal menu query when full query hits missing columns. */
export const MINIMAL_PUBLIC_MENU_SQL = `
  SELECT
    md.id::text AS id,
    md.name::text AS name,
    COALESCE(NULLIF(TRIM(md.category), ''), '')::text AS description,
    COALESCE(NULLIF(TRIM(md.price), '')::numeric, 0) AS price,
    '[]'::text AS dips,
    '[]'::text AS ingredients,
    COALESCE(NULLIF(TRIM(md.category), ''), '')::text AS category,
    ''::text AS dish_type,
    NULL::text AS image_base64,
    '[]'::text AS allergens
  FROM public.menu_dishes md
  ORDER BY md.name
`.trim();

/** Build menu SQL using only columns that exist on menu_dishes. */
export async function buildMenuSql(pool: pg.Pool): Promise<string> {
  const hasMealType = await columnExists(pool, "menu_dishes", "meal_type");
  const hasType = await columnExists(pool, "menu_dishes", "type");
  const mealCol = hasMealType ? "meal_type" : hasType ? "type" : null;
  const hasArchived = await columnExists(pool, "menu_dishes", "archived");
  const hasSauces = await columnExists(pool, "menu_dishes", "sauces");
  const hasIngredients = await columnExists(pool, "menu_dishes", "ingredients");
  const hasAllergens = await columnExists(pool, "menu_dishes", "allergens");
  const hasImage = await columnExists(pool, "menu_dishes", "image_base64");

  const dishTypeExpr = mealCol
    ? `COALESCE(NULLIF(TRIM(md.${mealCol}), ''), '')::text`
    : `''::text`;
  const descExpr = mealCol
    ? `CASE
         WHEN LOWER(TRIM(COALESCE(md.${mealCol}, ''))) = 'restaurant'
           THEN NULLIF(TRIM(md.category), '')
         ELSE TRIM(CONCAT_WS(' • ', NULLIF(TRIM(COALESCE(md.${mealCol}, '')), ''), NULLIF(TRIM(md.category), '')))
       END`
    : `NULLIF(TRIM(md.category), '')`;
  const dipsExpr = hasSauces ? `COALESCE(md.sauces::text, '[]')` : `'[]'::text`;
  const ingredientsExpr = hasIngredients ? `COALESCE(md.ingredients::text, '[]')` : `'[]'::text`;
  const imageExpr = hasImage ? `md.image_base64::text` : `NULL::text`;
  const allergensExpr = hasAllergens ? MENU_DISH_ALLERGEN_NAMES_JSON_SQL : `'[]'::text`;
  const whereClause = hasArchived ? `WHERE NOT COALESCE(md.archived, false)` : "";

  return `
    SELECT
      md.id::text AS id,
      md.name::text AS name,
      ${descExpr} AS description,
      COALESCE(NULLIF(TRIM(md.price), '')::numeric, 0) AS price,
      ${dipsExpr} AS dips,
      ${ingredientsExpr} AS ingredients,
      COALESCE(NULLIF(TRIM(md.category), ''), '')::text AS category,
      ${dishTypeExpr} AS dish_type,
      ${imageExpr} AS image_base64,
      ${allergensExpr} AS allergens
    FROM public.menu_dishes md
    ${whereClause}
    ORDER BY md.name
  `.trim();
}
