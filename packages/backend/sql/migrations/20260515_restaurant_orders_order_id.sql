-- Canonical restaurant order storage: rename PK column and retire mobile_orders.
-- Safe to run once on environments that still have legacy schema.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurant_orders' AND column_name = 'id'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurant_orders' AND column_name = 'order_id'
  ) THEN
    ALTER TABLE restaurant_orders RENAME COLUMN id TO order_id;
  END IF;
END $$;

ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS customer_id TEXT;

UPDATE restaurant_orders ro
SET customer_id = cp.id
FROM customer_profiles cp
WHERE (ro.customer_id IS NULL OR TRIM(ro.customer_id) = '')
  AND ro.user_email IS NOT NULL
  AND TRIM(ro.user_email) <> ''
  AND LOWER(TRIM(cp.user_email)) = LOWER(TRIM(ro.user_email));

DROP TRIGGER IF EXISTS trg_sync_mobile_orders_into_restaurant_orders ON mobile_orders;
DROP FUNCTION IF EXISTS sync_mobile_orders_into_restaurant_orders();
DROP TABLE IF EXISTS mobile_orders CASCADE;
