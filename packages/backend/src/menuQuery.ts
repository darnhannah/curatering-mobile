/**
 * menu_dishes SELECT builders — tolerate renamed/pruned columns in production.
 */
import type pg from "pg";
import { MENU_DISH_ALLERGEN_NAMES_JSON_SQL } from "./menuAllergens.js";
import { columnExists, columnUdtName, tableExists } from "./schemaColumns.js";

/** Allergen JSON text for menu row alias `md` — bigint[] ids, text[] names, or scalar text/json. */
export async function menuDishAllergensSelectExpr(pool: pg.Pool): Promise<string> {
  const hasAllergens = await columnExists(pool, "menu_dishes", "allergens");
  if (!hasAllergens) return `'[]'::text`;

  const udt = await columnUdtName(pool, "menu_dishes", "allergens");
  if (udt === "_int8") {
    const hasJoinTable =
      (await tableExists(pool, "menu_dishes_allergens")) &&
      (await columnExists(pool, "menu_dishes_allergens", "allergen_id"));
    if (hasJoinTable) return MENU_DISH_ALLERGEN_NAMES_JSON_SQL;
    return `'[]'::text`;
  }
  if (udt === "_text") {
    return `COALESCE(
      (
        SELECT json_agg(x ORDER BY ord)::text
        FROM unnest(COALESCE(md.allergens, '{}'::text[])) WITH ORDINALITY AS t(x, ord)
        WHERE NULLIF(TRIM(x), '') IS NOT NULL
      ),
      '[]'
    )`;
  }
  return `COALESCE(NULLIF(TRIM(md.allergens::text), ''), '[]')`;
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

/** Resolve dish image as text for API `image_base64`. */
export async function menuDishImageSelectExpr(pool: pg.Pool): Promise<string> {
  if (await columnExists(pool, "menu_dishes", "image_base64")) {
    return `NULLIF(TRIM(md.image_base64::text), '')`;
  }
  if (await columnExists(pool, "menu_dishes", "image")) {
    const udt = await columnUdtName(pool, "menu_dishes", "image");
    if (udt === "jsonb") {
      return `NULLIF(TRIM(COALESCE(md.image->>'base64', md.image->>'image_base64', '')), '')`;
    }
    return `NULLIF(TRIM(md.image::text), '')`;
  }
  return `NULL::text`;
}

/** Build menu SQL using only columns that exist on menu_dishes. */
export async function buildMenuSql(pool: pg.Pool, opts?: { skipAllergens?: boolean }): Promise<string> {
  const hasMealType = await columnExists(pool, "menu_dishes", "meal_type");
  const hasType = await columnExists(pool, "menu_dishes", "type");
  const mealCol = hasMealType ? "meal_type" : hasType ? "type" : null;
  const hasArchived = await columnExists(pool, "menu_dishes", "archived");
  const hasSauces = await columnExists(pool, "menu_dishes", "sauces");
  const hasDips = await columnExists(pool, "menu_dishes", "dips");
  const hasIngredients = await columnExists(pool, "menu_dishes", "ingredients");
  const hasAllergens = await columnExists(pool, "menu_dishes", "allergens");
  const imageExpr = await menuDishImageSelectExpr(pool);

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
  const dipsExpr = hasSauces
    ? `COALESCE(to_jsonb(md.sauces)::text, '[]')`
    : hasDips
      ? `COALESCE(to_jsonb(md.dips)::text, '[]')`
      : `'[]'::text`;
  const ingredientsExpr = hasIngredients ? `COALESCE(to_jsonb(md.ingredients)::text, '[]')` : `'[]'::text`;
  let allergensExpr = `'[]'::text`;
  if (hasAllergens && !opts?.skipAllergens) {
    try {
      allergensExpr = await menuDishAllergensSelectExpr(pool);
    } catch {
      allergensExpr = `'[]'::text`;
    }
  }
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

/** Build set-menus query from `public.set_menus` or aggregate `menu_dishes.set_menus`. */
export async function buildSetMenusSql(pool: pg.Pool): Promise<string | null> {
  if (await tableExists(pool, "set_menus")) {
    const hasDishIds = await columnExists(pool, "set_menus", "dish_ids");
    const hasDishesCol = await columnExists(pool, "set_menus", "dishes");
    const hasDesc = await columnExists(pool, "set_menus", "description");
    const hasArchived = await columnExists(pool, "set_menus", "archived");
    const descExpr = hasDesc ? `COALESCE(sm.description::text, '')` : `''::text`;
    const whereClause = hasArchived ? `WHERE NOT COALESCE(sm.archived, false)` : "";
    let dishesExpr: string;
    if (hasDishIds) {
      dishesExpr = `COALESCE(
        (
          SELECT json_agg(md.name ORDER BY u.ord)::text
          FROM unnest(sm.dish_ids) WITH ORDINALITY AS u(dish_id, ord)
          LEFT JOIN public.menu_dishes md ON md.id::text = TRIM(BOTH FROM u.dish_id::text)
          WHERE md.id IS NOT NULL
        ),
        '[]'
      )`;
    } else if (hasDishesCol) {
      dishesExpr = `COALESCE(sm.dishes::text, '[]')`;
    } else {
      dishesExpr = `'[]'::text`;
    }
    return `
      SELECT
        sm.name::text AS name,
        ${descExpr} AS description,
        ${dishesExpr} AS dishes
      FROM public.set_menus sm
      ${whereClause}
      ORDER BY sm.name
    `.trim();
  }

  if (!(await columnExists(pool, "menu_dishes", "set_menus"))) return null;

  const udt = await columnUdtName(pool, "menu_dishes", "set_menus");
  const hasArchived = await columnExists(pool, "menu_dishes", "archived");
  const whereMd = hasArchived ? `WHERE NOT COALESCE(md.archived, false)` : "";

  if (udt === "_text") {
    return `
      SELECT
        TRIM(sm_name)::text AS name,
        ''::text AS description,
        COALESCE(json_agg(md.name ORDER BY md.name)::text, '[]') AS dishes
      FROM public.menu_dishes md
      CROSS JOIN LATERAL unnest(COALESCE(md.set_menus, '{}'::text[])) AS sm_name
      ${whereMd}
        AND NULLIF(TRIM(sm_name), '') IS NOT NULL
      GROUP BY TRIM(sm_name)
      ORDER BY TRIM(sm_name)
    `.trim();
  }

  if (udt === "jsonb") {
    return `
      SELECT
        TRIM(sm_name)::text AS name,
        ''::text AS description,
        COALESCE(json_agg(md.name ORDER BY md.name)::text, '[]') AS dishes
      FROM public.menu_dishes md
      CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(md.set_menus, '[]'::jsonb)) AS sm_name
      ${whereMd}
        AND NULLIF(TRIM(sm_name), '') IS NOT NULL
      GROUP BY TRIM(sm_name)
      ORDER BY TRIM(sm_name)
    `.trim();
  }

  return null;
}
