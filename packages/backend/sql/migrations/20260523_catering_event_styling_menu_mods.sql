-- Event styling choice, menu modifications, cost breakdown, and set menu on catering/event orders.

ALTER TABLE catering_orders
  ADD COLUMN IF NOT EXISTS service_included TEXT NOT NULL DEFAULT 'no',
  ADD COLUMN IF NOT EXISTS selected_set_menu TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS menu_modifications JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS cost_breakdown JSONB NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE event_orders
  ADD COLUMN IF NOT EXISTS service_included TEXT NOT NULL DEFAULT 'no',
  ADD COLUMN IF NOT EXISTS selected_set_menu TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS menu_modifications JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS cost_breakdown JSONB NOT NULL DEFAULT '[]'::jsonb;

-- Backfill from checklist.post_analysis / theme_design (idempotent).
UPDATE catering_orders c
SET
  service_included = COALESCE(
    NULLIF(TRIM(c.service_included), ''),
    NULLIF(TRIM(
      CASE
        WHEN jsonb_typeof(COALESCE(c.checklist, '[]'::jsonb)) = 'object'
          THEN c.checklist->'post_analysis'->>'service_included'
        ELSE NULL
      END
    ), ''),
    'no'
  ),
  selected_set_menu = COALESCE(
    NULLIF(TRIM(c.selected_set_menu), ''),
    NULLIF(TRIM(
      CASE
        WHEN jsonb_typeof(COALESCE(c.checklist, '[]'::jsonb)) = 'object'
          THEN c.checklist->'post_analysis'->>'selected_set_menu'
        ELSE NULL
      END
    ), ''),
    ''
  ),
  menu_modifications = CASE
    WHEN c.menu_modifications IS NOT NULL AND c.menu_modifications <> '{}'::jsonb THEN c.menu_modifications
    WHEN jsonb_typeof(COALESCE(c.checklist, '[]'::jsonb)) = 'object'
      AND jsonb_typeof(c.checklist->'post_analysis'->'menu_modifications') = 'object'
      THEN c.checklist->'post_analysis'->'menu_modifications'
    ELSE c.menu_modifications
  END,
  cost_breakdown = CASE
    WHEN c.cost_breakdown IS NOT NULL AND c.cost_breakdown <> '[]'::jsonb THEN c.cost_breakdown
    WHEN jsonb_typeof(COALESCE(c.checklist, '[]'::jsonb)) = 'object'
      AND jsonb_typeof(c.checklist->'post_analysis'->'cost_breakdown') = 'array'
      THEN c.checklist->'post_analysis'->'cost_breakdown'
    ELSE c.cost_breakdown
  END
WHERE TRUE;

UPDATE event_orders e
SET
  service_included = COALESCE(
    NULLIF(TRIM(e.service_included), ''),
    NULLIF(TRIM(e.theme_design->>'service_included'), ''),
    NULLIF(TRIM(
      CASE
        WHEN jsonb_typeof(COALESCE(e.checklist, '[]'::jsonb)) = 'object'
          THEN e.checklist->'post_analysis'->>'service_included'
        ELSE NULL
      END
    ), ''),
    'no'
  ),
  selected_set_menu = COALESCE(
    NULLIF(TRIM(e.selected_set_menu), ''),
    NULLIF(TRIM(
      CASE
        WHEN jsonb_typeof(COALESCE(e.checklist, '[]'::jsonb)) = 'object'
          THEN e.checklist->'post_analysis'->>'selected_set_menu'
        ELSE NULL
      END
    ), ''),
    ''
  ),
  menu_modifications = CASE
    WHEN e.menu_modifications IS NOT NULL AND e.menu_modifications <> '{}'::jsonb THEN e.menu_modifications
    WHEN jsonb_typeof(e.theme_design->'menu_modifications') = 'object' THEN e.theme_design->'menu_modifications'
    WHEN jsonb_typeof(COALESCE(e.checklist, '[]'::jsonb)) = 'object'
      AND jsonb_typeof(e.checklist->'post_analysis'->'menu_modifications') = 'object'
      THEN e.checklist->'post_analysis'->'menu_modifications'
    ELSE e.menu_modifications
  END,
  cost_breakdown = CASE
    WHEN e.cost_breakdown IS NOT NULL AND e.cost_breakdown <> '[]'::jsonb THEN e.cost_breakdown
    WHEN jsonb_typeof(COALESCE(e.checklist, '[]'::jsonb)) = 'object'
      AND jsonb_typeof(e.checklist->'post_analysis'->'cost_breakdown') = 'array'
      THEN e.checklist->'post_analysis'->'cost_breakdown'
    ELSE e.cost_breakdown
  END
WHERE TRUE;
