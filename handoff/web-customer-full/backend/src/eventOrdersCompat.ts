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

export function eventPostAnalysisPersistSet(paramRef: string): string {
  return `checklist = jsonb_set(
      COALESCE(checklist, '{}'::jsonb),
      '{post_analysis}',
      COALESCE(${paramRef}::jsonb, COALESCE(checklist->'post_analysis', '{}'::jsonb))
    )`;
}
