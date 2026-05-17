-- Restaurant orders: keep UUID `id` as table PK; use TEXT `order_id` (ORD-*) for display.
-- Run schemaNormalize on app startup for full repair; this file is a manual supplement.

ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS id UUID;
ALTER TABLE restaurant_orders ADD COLUMN IF NOT EXISTS order_id TEXT;

-- Only add TEXT customer_id when the column does not exist (production may already use UUID).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurant_orders' AND column_name = 'customer_id'
  ) THEN
    ALTER TABLE restaurant_orders ADD COLUMN customer_id TEXT;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurant_orders'
      AND column_name = 'customer_id' AND data_type = 'uuid'
  ) THEN
    UPDATE restaurant_orders ro
    SET customer_id = ca.id
    FROM customer_accounts ca
    WHERE ro.customer_id IS NULL
      AND ro.user_email IS NOT NULL
      AND TRIM(ro.user_email) <> ''
      AND LOWER(TRIM(ca.email)) = LOWER(TRIM(ro.user_email));
  ELSIF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurant_orders'
      AND column_name = 'customer_id' AND data_type IN ('text', 'character varying')
  ) THEN
    UPDATE restaurant_orders ro
    SET customer_id = ca.customer_id
    FROM customer_accounts ca
    WHERE (ro.customer_id IS NULL OR TRIM(ro.customer_id::text) = '')
      AND ro.user_email IS NOT NULL
      AND TRIM(ro.user_email) <> ''
      AND ca.customer_id IS NOT NULL
      AND LOWER(TRIM(ca.email)) = LOWER(TRIM(ro.user_email));
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_sync_mobile_orders_into_restaurant_orders ON mobile_orders;
DROP FUNCTION IF EXISTS sync_mobile_orders_into_restaurant_orders();
DROP TABLE IF EXISTS mobile_orders CASCADE;
