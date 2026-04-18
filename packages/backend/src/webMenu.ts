/**
 * Reads dish / set-menu data from your existing web-app tables.
 *
 * Configure either full SQL via WEB_MENU_SQL / WEB_SET_MENUS_SQL,
 * or table+column mapping via WEB_MENU_TABLE / WEB_SET_MENU_TABLE / …
 *
 * If none of those are set, we use the Curatering public schema defaults:
 *   public.menu_dishes + public.set_menus (see DEFAULT_PUBLIC_* below).
 *
 * Expected column aliases from menu query:
 *   id (text uuid ok), name, description, price, dips (JSON text array)
 *
 * Set menus query expected columns:
 *   name, description, dishes (JSON text array of dish names)
 */

/** Matches `public.menu_dishes`: sauces → dips, price text → numeric. */
export const DEFAULT_PUBLIC_MENU_SQL = `
  SELECT
    md.id::text AS id,
    md.name::text AS name,
    TRIM(CONCAT_WS(' • ', NULLIF(TRIM(md.type), ''), NULLIF(TRIM(md.category), ''))) AS description,
    COALESCE(NULLIF(TRIM(md.price), '')::numeric, 0) AS price,
    COALESCE(md.sauces::text, '[]') AS dips,
    COALESCE(TRIM(md.category), '')::text AS category,
    md.image_base64::text AS image_base64
  FROM public.menu_dishes md
  WHERE NOT md.archived
  ORDER BY md.name
`.trim();

/** Resolves `set_menus.dish_ids` (text[]) to dish names via `menu_dishes`. */
export const DEFAULT_PUBLIC_SET_MENUS_SQL = `
  SELECT
    sm.name::text AS name,
    ''::text AS description,
    COALESCE(
      (
        SELECT json_agg(md.name ORDER BY u.ord)::text
        FROM unnest(sm.dish_ids) WITH ORDINALITY AS u(dish_id, ord)
        INNER JOIN public.menu_dishes md ON md.id::text = TRIM(BOTH FROM u.dish_id::text)
      ),
      '[]'
    ) AS dishes
  FROM public.set_menus sm
  WHERE NOT sm.archived
  ORDER BY sm.name
`.trim();

function escapeIdent(raw: string): string {
  const s = raw.trim();
  if (!/^[\w.]+$/.test(s)) {
    throw new Error(`Unsafe SQL identifier in menu config: ${raw}`);
  }
  return s.split(".").map((part) => `"${part.replace(/"/g, '""')}"`).join(".");
}

/** Full custom SQL for dishes (must select id, name, description, price, dips). */
export function resolveMenuSql(): string | null {
  const sql = process.env.WEB_MENU_SQL?.trim();
  if (sql) return sql;

  const table = process.env.WEB_MENU_TABLE?.trim();
  if (!table) {
    if (process.env.DISABLE_DEFAULT_PUBLIC_MENU === "true") {
      return null;
    }
    return DEFAULT_PUBLIC_MENU_SQL;
  }

  const schema = process.env.WEB_MENU_SCHEMA?.trim();
  const qualified = schema ? `${escapeIdent(schema)}.${escapeIdent(table)}` : escapeIdent(table);

  const idCol = process.env.WEB_MENU_ID_COL?.trim() || "id";
  const nameCol = process.env.WEB_MENU_NAME_COL?.trim() || "name";
  const descCol = process.env.WEB_MENU_DESC_COL?.trim() || "description";
  const priceCol = process.env.WEB_MENU_PRICE_COL?.trim() || "price";
  const dipsCol = process.env.WEB_MENU_DIPS_COL?.trim();

  const dipsExpr = dipsCol
    ? `COALESCE(${escapeIdent(dipsCol)}::text, '[]')`
    : `'[]'::text`;

  const categoryCol = process.env.WEB_MENU_CATEGORY_COL?.trim();
  const imageCol = process.env.WEB_MENU_IMAGE_COL?.trim();
  const categoryExpr = categoryCol
    ? `COALESCE(${escapeIdent(categoryCol)}::text, '')`
    : `''::text`;
  const imageExpr = imageCol ? `${escapeIdent(imageCol)}::text` : `NULL::text`;

  const where = process.env.WEB_MENU_WHERE?.trim();

  return `
    SELECT
      ${escapeIdent(idCol)}::text AS id,
      ${escapeIdent(nameCol)}::text AS name,
      COALESCE(${escapeIdent(descCol)}::text, '') AS description,
      ${escapeIdent(priceCol)}::numeric AS price,
      ${dipsExpr} AS dips,
      ${categoryExpr} AS category,
      ${imageExpr} AS image_base64
    FROM ${qualified}
    ${where ? `WHERE ${where}` : ""}
    ORDER BY ${escapeIdent(idCol)}
  `.trim();
}

export function resolveSetMenusSql(): string | null {
  const sql = process.env.WEB_SET_MENUS_SQL?.trim();
  if (sql) return sql;

  const table = process.env.WEB_SET_MENU_TABLE?.trim();
  if (!table) {
    if (process.env.DISABLE_DEFAULT_PUBLIC_MENU === "true") {
      return null;
    }
    return DEFAULT_PUBLIC_SET_MENUS_SQL;
  }

  const schema = process.env.WEB_SET_MENU_SCHEMA?.trim();
  const qualified = schema ? `${escapeIdent(schema)}.${escapeIdent(table)}` : escapeIdent(table);

  const nameCol = process.env.WEB_SET_MENU_NAME_COL?.trim() || "name";
  const descCol = process.env.WEB_SET_MENU_DESC_COL?.trim() || "description";
  const dishesCol = process.env.WEB_SET_MENU_DISHES_COL?.trim() || "dishes";

  const where = process.env.WEB_SET_MENU_WHERE?.trim();

  return `
    SELECT
      ${escapeIdent(nameCol)}::text AS name,
      COALESCE(${escapeIdent(descCol)}::text, '') AS description,
      COALESCE(${escapeIdent(dishesCol)}::text, '[]') AS dishes
    FROM ${qualified}
    ${where ? `WHERE ${where}` : ""}
    ORDER BY ${escapeIdent(nameCol)}
  `.trim();
}
