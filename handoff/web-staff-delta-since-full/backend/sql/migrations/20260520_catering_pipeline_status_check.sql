-- Allow manager pipeline tabs: for_down_payment, for_ongoing, for_full_payment (plus legacy for_processing / for_post_analysis).
ALTER TABLE event_orders DROP CONSTRAINT IF EXISTS event_orders_status_check;
ALTER TABLE event_orders ADD CONSTRAINT event_orders_status_check
  CHECK (status = ANY (ARRAY[
    'new_event'::text, 'online_inquiries'::text,
    'for_down_payment'::text, 'for_ongoing'::text, 'for_full_payment'::text,
    'for_processing'::text, 'for_post_analysis'::text,
    'completed'::text, 'cancelled'::text
  ]));

ALTER TABLE catering_orders DROP CONSTRAINT IF EXISTS catering_orders_status_check;
ALTER TABLE catering_orders ADD CONSTRAINT catering_orders_status_check
  CHECK (status = ANY (ARRAY[
    'new_event'::text, 'online_inquiries'::text,
    'for_down_payment'::text, 'for_ongoing'::text, 'for_full_payment'::text,
    'for_processing'::text, 'for_post_analysis'::text,
    'completed'::text, 'cancelled'::text
  ]));
