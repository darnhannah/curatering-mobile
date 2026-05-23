/**
 * Canonical event_orders column usage (catering + event inquiries/orders).
 */

/** Workflow metadata lives in checklist.post_analysis (no post_analysis column on event_orders). */
export const EVENT_POST_ANALYSIS_JSON = `COALESCE(
  CASE
    WHEN jsonb_typeof(COALESCE(checklist, '[]'::jsonb)) = 'object'
      THEN NULLIF(checklist->'post_analysis', 'null'::jsonb)
    ELSE NULL
  END,
  '{}'::jsonb
)`;

export const EVENT_TRANSACTION_ID = `COALESCE(NULLIF(TRIM(event_id::text), ''), '')`;

export const CATERING_TRANSACTION_ID = `COALESCE(NULLIF(TRIM(catering_id::text), ''), '')`;

/** Catering rows: workflow metadata in checklist.post_analysis only. */
export const CATERING_POST_ANALYSIS_JSON = EVENT_POST_ANALYSIS_JSON;

/** Open / closed — canonical `event_setting` column with legacy theme_design fallback on event rows. */
export function eventSettingSql(alias?: string): string {
  const es = alias ? `${alias}.event_setting` : "event_setting";
  const td = alias ? `${alias}.theme_design` : "theme_design";
  return `COALESCE(NULLIF(TRIM(${es}), ''), NULLIF(TRIM(${td}->>'event_setting'), ''), '')`;
}

export function cateringEventSettingSql(alias?: string): string {
  const es = alias ? `${alias}.event_setting` : "event_setting";
  return `COALESCE(NULLIF(TRIM(${es}), ''), '')`;
}

/** API alias: inquiry vs stage additional costs (no legacy additional_costs column). */
export function eventAdditionalCostsSql(stageParamRef: string): string {
  return `CASE
    WHEN ${stageParamRef}::text IN ('new_event', 'online_inquiries')
      THEN COALESCE(inquiry_additional_costs, '[]'::jsonb)
    ELSE COALESCE(stage_additional_costs, '[]'::jsonb)
  END`;
}

/** Event styling: yes = with styling, no = without (column + legacy JSON fallbacks). */
export function cateringServiceIncludedSql(): string {
  return `COALESCE(
    NULLIF(TRIM(service_included), ''),
    NULLIF(TRIM((${CATERING_POST_ANALYSIS_JSON})->>'service_included'), ''),
    'no'
  )`;
}

export function eventServiceIncludedSql(): string {
  return `COALESCE(
    NULLIF(TRIM(service_included), ''),
    NULLIF(TRIM(theme_design->>'service_included'), ''),
    NULLIF(TRIM((${EVENT_POST_ANALYSIS_JSON})->>'service_included'), ''),
    'no'
  )`;
}

export function cateringMenuModificationsSql(): string {
  return `COALESCE(
    NULLIF(menu_modifications, '{}'::jsonb),
    (${CATERING_POST_ANALYSIS_JSON})->'menu_modifications',
    '{}'::jsonb
  )`;
}

export function eventMenuModificationsSql(): string {
  return `COALESCE(
    NULLIF(menu_modifications, '{}'::jsonb),
    NULLIF(theme_design->'menu_modifications', 'null'::jsonb),
    (${EVENT_POST_ANALYSIS_JSON})->'menu_modifications',
    '{}'::jsonb
  )`;
}

export function cateringCostBreakdownSql(): string {
  return `COALESCE(
    NULLIF(cost_breakdown, '[]'::jsonb),
    (${CATERING_POST_ANALYSIS_JSON})->'cost_breakdown',
    '[]'::jsonb
  )`;
}

export function eventCostBreakdownSql(): string {
  return `COALESCE(
    NULLIF(cost_breakdown, '[]'::jsonb),
    (${EVENT_POST_ANALYSIS_JSON})->'cost_breakdown',
    '[]'::jsonb
  )`;
}

export function cateringSelectedSetMenuSql(): string {
  return `COALESCE(
    NULLIF(TRIM(selected_set_menu), ''),
    NULLIF(TRIM((${CATERING_POST_ANALYSIS_JSON})->>'selected_set_menu'), ''),
    ''
  )`;
}

export function eventSelectedSetMenuSql(): string {
  return `COALESCE(
    NULLIF(TRIM(selected_set_menu), ''),
    NULLIF(TRIM((${EVENT_POST_ANALYSIS_JSON})->>'selected_set_menu'), ''),
    ''
  )`;
}

export function eventPostAnalysisPersistSet(paramRef: string): string {
  return `checklist = jsonb_set(
      COALESCE(checklist, '{}'::jsonb),
      '{post_analysis}',
      COALESCE(${paramRef}::jsonb, COALESCE(checklist->'post_analysis', '{}'::jsonb))
    )`;
}
