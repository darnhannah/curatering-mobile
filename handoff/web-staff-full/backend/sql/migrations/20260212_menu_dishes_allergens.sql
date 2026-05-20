-- Menu allergens: canonical names in menu_dishes_allergens;
-- menu_dishes.allergens stores BIGINT[] of allergen_id (join to allergen_name for display).
-- Run in Supabase SQL editor or psql against the same DB as public.menu_dishes.

CREATE TABLE IF NOT EXISTS public.menu_dishes_allergens (
  allergen_id BIGSERIAL PRIMARY KEY,
  allergen_name TEXT NOT NULL UNIQUE
);

INSERT INTO public.menu_dishes_allergens (allergen_name) VALUES
  ('Milk / Dairy'),
  ('Eggs'),
  ('Fish'),
  ('Shellfish / Crustaceans'),
  ('Tree nuts'),
  ('Peanuts'),
  ('Wheat / Gluten'),
  ('Soy'),
  ('Sesame'),
  ('Mustard'),
  ('Celery'),
  ('Lupin'),
  ('Sulfites'),
  ('Mollusks'),
  ('Corn'),
  ('Garlic'),
  ('Onion'),
  ('Coconut'),
  ('Chocolate / Cocoa'),
  ('Caffeine'),
  ('Other: [manual input]')
ON CONFLICT (allergen_name) DO NOTHING;

-- New installs: array of menu_dishes_allergens.allergen_id.
-- If public.menu_dishes.allergens already exists with another type (e.g. TEXT),
-- migrate data separately, then DROP that column and re-run this block, or use a new column name.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_dishes'
      AND column_name = 'allergens'
  ) THEN
    ALTER TABLE public.menu_dishes
      ADD COLUMN allergens BIGINT[] NOT NULL DEFAULT '{}'::bigint[];
  END IF;
END $$;

COMMENT ON COLUMN public.menu_dishes.allergens IS
  'Array of menu_dishes_allergens.allergen_id. Resolve display text via menu_dishes_allergens.allergen_name.';

-- Optional helper view: same rows as menu_dishes plus allergen_name_list (TEXT[] in id order).
CREATE OR REPLACE VIEW public.menu_dishes_with_allergen_names AS
SELECT
  md.*,
  COALESCE(
    (
      SELECT array_agg(ma.allergen_name ORDER BY ord)
      FROM unnest(COALESCE(md.allergens, '{}'::bigint[])) WITH ORDINALITY AS t(allergen_id, ord)
      INNER JOIN public.menu_dishes_allergens ma ON ma.allergen_id = t.allergen_id
    ),
    ARRAY[]::text[]
  ) AS allergen_name_list
FROM public.menu_dishes md;
