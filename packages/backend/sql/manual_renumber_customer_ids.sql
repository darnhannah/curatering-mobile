-- One-shot: assign unique CUS-0001, CUS-0002, … by account creation time (earliest first).
-- Run in Supabase SQL editor if Railway startup migration has not applied yet.

BEGIN;

DROP INDEX IF EXISTS customer_accounts_customer_id_uq;

CREATE TEMP TABLE customer_id_remap AS
SELECT
  LOWER(TRIM(email)) AS email_key,
  NULLIF(TRIM(customer_id::text), '') AS old_customer_id,
  'CUS-' || LPAD(
    ROW_NUMBER() OVER (
      ORDER BY COALESCE(created_account_dt_stamp, NOW()), LOWER(TRIM(email))
    )::text,
    4,
    '0'
  ) AS new_customer_id
FROM customer_accounts
WHERE email IS NOT NULL AND TRIM(email) <> '';

UPDATE restaurant_orders ro
SET customer_id = m.new_customer_id
FROM customer_id_remap m
WHERE ro.customer_id IS NOT NULL
  AND TRIM(ro.customer_id::text) <> ''
  AND ro.customer_id::text = m.old_customer_id;

UPDATE restaurant_orders ro
SET customer_id = m.new_customer_id
FROM customer_id_remap m
WHERE LOWER(TRIM(COALESCE(ro.user_email, ''))) = m.email_key;

UPDATE catering_orders o
SET customer_id = m.new_customer_id
FROM customer_id_remap m
WHERE o.customer_id IS NOT NULL
  AND TRIM(o.customer_id::text) <> ''
  AND o.customer_id::text = m.old_customer_id;

UPDATE catering_orders o
SET customer_id = m.new_customer_id
FROM customer_id_remap m
WHERE LOWER(TRIM(COALESCE(o.email_address, ''))) = m.email_key;

UPDATE event_orders o
SET customer_id = m.new_customer_id
FROM customer_id_remap m
WHERE o.customer_id IS NOT NULL
  AND TRIM(o.customer_id::text) <> ''
  AND o.customer_id::text = m.old_customer_id;

UPDATE event_orders o
SET customer_id = m.new_customer_id
FROM customer_id_remap m
WHERE LOWER(TRIM(COALESCE(o.email_address, ''))) = m.email_key;

UPDATE customer_accounts ca
SET customer_id = m.new_customer_id
FROM customer_id_remap m
WHERE LOWER(TRIM(ca.email)) = m.email_key;

INSERT INTO id_counters (prefix, last_number)
VALUES ('CUS', (SELECT COUNT(*) FROM customer_accounts))
ON CONFLICT (prefix) DO UPDATE
SET last_number = GREATEST(
  id_counters.last_number,
  (SELECT COUNT(*) FROM customer_accounts)
),
updated_at = NOW();

COMMIT;

CREATE UNIQUE INDEX IF NOT EXISTS customer_accounts_customer_id_uq ON customer_accounts (customer_id);
