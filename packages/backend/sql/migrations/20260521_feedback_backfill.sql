-- Ensure public.feedback exists and backfill from mobile feedback sources.
-- Safe to re-run (skips rows already mirrored via message header).

CREATE TABLE IF NOT EXISTS feedback (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  message text NOT NULL,
  created_at timestamp without time zone NULL DEFAULT now(),
  processed boolean NULL DEFAULT false,
  source text NOT NULL DEFAULT 'web'::text,
  status text NOT NULL DEFAULT 'pending'::text,
  analyzed_at timestamp with time zone NULL,
  customer_name text NULL,
  customer_email text NULL,
  rating integer NULL,
  CONSTRAINT feedback_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_feedback_status_created_at
  ON public.feedback USING btree (status, created_at DESC);

INSERT INTO feedback (message, created_at, processed, source, status, customer_name, customer_email, rating)
SELECT
  '[mobile|' || cof.kind || '|' || cof.reference || ']' || E'\n' ||
    'Rating: ' || cof.rating::text || '/5' || E'\n' ||
    CASE WHEN NULLIF(TRIM(cof.comment), '') IS NOT NULL
      THEN 'Remarks: ' || TRIM(cof.comment)
      ELSE 'Remarks: (none)' END
    || CASE
      WHEN cof.kind = 'catering_inquiry' AND COALESCE(e.transaction_no, c.transaction_no, '') <> '' THEN
        E'\nTransaction: ' || COALESCE(e.transaction_no, c.transaction_no, '')
      WHEN cof.kind = 'restaurant_order' THEN E'\nTransaction: ' || cof.reference
      ELSE '' END
    || CASE WHEN NULLIF(TRIM(ca.full_name), '') IS NOT NULL THEN E'\nCustomer: ' || TRIM(ca.full_name)
      WHEN cof.kind = 'catering_inquiry' AND NULLIF(TRIM(COALESCE(e.customer_name, c.customer_name)), '') IS NOT NULL THEN
        E'\nCustomer: ' || TRIM(COALESCE(e.customer_name, c.customer_name))
      WHEN cof.kind = 'restaurant_order' AND NULLIF(TRIM(ro.full_name), '') IS NOT NULL THEN
        E'\nCustomer: ' || TRIM(ro.full_name)
      ELSE '' END,
  cof.created_at::timestamp,
  FALSE,
  'mobile',
  'pending',
  COALESCE(
    NULLIF(TRIM(ca.full_name), ''),
    CASE WHEN cof.kind = 'catering_inquiry' THEN NULLIF(TRIM(COALESCE(e.customer_name, c.customer_name)), '') END,
    CASE WHEN cof.kind = 'restaurant_order' THEN NULLIF(TRIM(ro.full_name), '') END
  ),
  LOWER(TRIM(cof.user_email)),
  cof.rating
FROM customer_order_feedback cof
LEFT JOIN customer_accounts ca ON LOWER(TRIM(ca.email)) = LOWER(TRIM(cof.user_email))
LEFT JOIN restaurant_orders ro ON cof.kind = 'restaurant_order'
  AND LOWER(TRIM(ro.user_email)) = LOWER(TRIM(cof.user_email))
  AND COALESCE(NULLIF(TRIM(ro.order_id), ''),
      CASE WHEN ro.mobile_id IS NOT NULL THEN 'ORD-' || LPAD(ro.mobile_id::text, 6, '0') END) = cof.reference
LEFT JOIN event_orders e ON cof.kind = 'catering_inquiry' AND e.id::text = cof.reference
LEFT JOIN catering_orders c ON cof.kind = 'catering_inquiry' AND c.id::text = cof.reference
WHERE NOT EXISTS (
  SELECT 1 FROM feedback f
  WHERE f.source = 'mobile'
    AND LOWER(TRIM(f.customer_email)) = LOWER(TRIM(cof.user_email))
    AND f.message LIKE '[mobile|' || cof.kind || '|' || cof.reference || ']%'
);

INSERT INTO feedback (message, created_at, processed, source, status, customer_name, customer_email, rating)
SELECT
  '[mobile|restaurant_order|' || ord_ref || ']' || E'\n' ||
    'Rating: ' || ro.feedback_stars::text || '/5' || E'\n' ||
    CASE WHEN NULLIF(TRIM(ro.feedback_remarks), '') IS NOT NULL
      THEN 'Remarks: ' || TRIM(ro.feedback_remarks)
      ELSE 'Remarks: (none)' END
    || E'\nTransaction: ' || ord_ref
    || CASE WHEN NULLIF(TRIM(COALESCE(ro.full_name, ca.full_name)), '') IS NOT NULL
      THEN E'\nCustomer: ' || TRIM(COALESCE(ro.full_name, ca.full_name)) ELSE '' END,
  COALESCE(ro.feedback_submitted_at::timestamp, ro.updated_at::timestamp, NOW()),
  FALSE,
  'mobile',
  'pending',
  NULLIF(TRIM(COALESCE(ro.full_name, ca.full_name)), ''),
  LOWER(TRIM(ro.user_email)),
  ro.feedback_stars::integer
FROM restaurant_orders ro
LEFT JOIN customer_accounts ca ON LOWER(TRIM(ca.email)) = LOWER(TRIM(ro.user_email))
CROSS JOIN LATERAL (
  SELECT COALESCE(NULLIF(TRIM(ro.order_id), ''),
    CASE WHEN ro.mobile_id IS NOT NULL THEN 'ORD-' || LPAD(ro.mobile_id::text, 6, '0') END
  ) AS ord_ref
) x
WHERE ro.feedback_stars IS NOT NULL
  AND NULLIF(TRIM(ro.user_email), '') IS NOT NULL
  AND ord_ref IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM customer_order_feedback cof
    WHERE cof.kind = 'restaurant_order'
      AND LOWER(TRIM(cof.user_email)) = LOWER(TRIM(ro.user_email))
      AND cof.reference = ord_ref
  )
  AND NOT EXISTS (
    SELECT 1 FROM feedback f
    WHERE f.source = 'mobile'
      AND LOWER(TRIM(f.customer_email)) = LOWER(TRIM(ro.user_email))
      AND f.message LIKE '[mobile|restaurant_order|' || ord_ref || ']%'
  );
