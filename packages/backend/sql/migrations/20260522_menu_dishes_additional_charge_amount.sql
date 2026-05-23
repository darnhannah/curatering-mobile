-- Per-dish add-on extra charge (e.g. sauce/dip portions beyond the first).
-- Run in Supabase SQL editor or psql against the same DB as public.menu_dishes.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_dishes'
      AND column_name = 'additional_charge_amount'
  ) THEN
    ALTER TABLE public.menu_dishes
      ADD COLUMN additional_charge_amount NUMERIC(12, 2) NOT NULL DEFAULT 0;
  END IF;
END $$;

COMMENT ON COLUMN public.menu_dishes.additional_charge_amount IS
  'PHP charged per extra add-on unit beyond the first (per main dish qty). 0 = use app default.';
