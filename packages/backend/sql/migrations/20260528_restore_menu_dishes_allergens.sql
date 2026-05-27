-- Restore menu_dishes_allergens from menu_dishes_allergens_legacy_junction, then drop legacy table.
-- Run in Supabase SQL editor or psql against production. Safe to re-run only while legacy table exists.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'menu_dishes_allergens_legacy_junction'
  ) THEN
    RAISE NOTICE 'menu_dishes_allergens_legacy_junction not found; nothing to restore.';
    RETURN;
  END IF;

  INSERT INTO public.menu_dishes_allergens (id, name)
  SELECT lj.allergen_id, TRIM(lj.allergen_name)
  FROM public.menu_dishes_allergens_legacy_junction lj
  WHERE TRIM(COALESCE(lj.allergen_name, '')) <> ''
    AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'menu_dishes_allergens' AND column_name = 'id'
    )
    AND NOT EXISTS (SELECT 1 FROM public.menu_dishes_allergens ma WHERE ma.id = lj.allergen_id)
    AND NOT EXISTS (
      SELECT 1 FROM public.menu_dishes_allergens ma
      WHERE LOWER(TRIM(ma.name)) = LOWER(TRIM(lj.allergen_name))
    );

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_dishes_allergens_legacy_junction'
      AND column_name = 'created_at'
  ) AND EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'menu_dishes_allergens' AND column_name = 'created_at'
  ) THEN
    UPDATE public.menu_dishes_allergens ma
    SET created_at = COALESCE(ma.created_at, lj.created_at)
    FROM public.menu_dishes_allergens_legacy_junction lj
    WHERE ma.id = lj.allergen_id;
  END IF;

  UPDATE public.menu_dishes_allergens ma
  SET name = TRIM(lj.allergen_name)
  FROM public.menu_dishes_allergens_legacy_junction lj
  WHERE ma.id = lj.allergen_id
    AND TRIM(COALESCE(lj.allergen_name, '')) <> ''
    AND LOWER(TRIM(COALESCE(ma.name, ''))) <> LOWER(TRIM(lj.allergen_name));

  PERFORM setval(
    pg_get_serial_sequence('menu_dishes_allergens', 'id'),
    GREATEST(
      COALESCE((SELECT MAX(id) FROM public.menu_dishes_allergens), 0),
      COALESCE((SELECT MAX(allergen_id) FROM public.menu_dishes_allergens_legacy_junction), 0),
      1
    ),
    true
  );

  DROP TABLE public.menu_dishes_allergens_legacy_junction CASCADE;
END $$;
