/**
 * SQL fragments and row normalizers so APIs stay stable while the DB uses canonical column names.
 */

/** Touch timestamp on customer_accounts (legacy updated_at was pruned). */
export const CUSTOMER_ACCOUNT_TOUCH = `updated_pw_dt_stamp = NOW()`;

/** Change-detection timestamps (production DB may not have updated_at on all tables). */
export const MENU_CHANGED_AT_SQL = `COALESCE(created_at, NOW())`;
export const CATERING_ORDER_CHANGED_AT_SQL = `COALESCE(stage_entered_at, created_at, NOW())`;

/** Shared SELECT list for restaurant order API responses (legacy aliases included). */
export const RESTAURANT_ORDER_SELECT = `
  mobile_id,
  mobile_id AS id,
  id AS order_uuid,
  user_email,
  COALESCE(order_id, CASE WHEN mobile_id IS NOT NULL THEN 'ORD-' || LPAD(mobile_id::text, 6, '0') END) AS order_id,
  COALESCE(order_id, CASE WHEN mobile_id IS NOT NULL THEN 'ORD-' || LPAD(mobile_id::text, 6, '0') END) AS order_no,
  COALESCE(order_status, 'PENDING_CASHIER') AS status,
  COALESCE(order_status, 'PENDING_CASHIER') AS fulfillment_stage,
  COALESCE(total_cost, 0) AS total,
  total_cost,
  COALESCE(delivery_notes, '') AS note,
  delivery_notes,
  payment_mode,
  COALESCE(payment_uploaded_initial, FALSE) AS payment_uploaded,
  payment_uploaded_initial,
  payment_proof_initial AS payment_proof,
  payment_proof_initial,
  payment_proof_balance AS supplemental_payment_proof,
  payment_proof_balance,
  COALESCE(NULLIF(TRIM(payment_reference_initial), ''), '') AS payment_reference_initial,
  COALESCE(NULLIF(TRIM(payment_reference_balance), ''), '') AS payment_reference_balance,
  payment_reference_initial,
  payment_reference_balance,
  COALESCE(payment_uploaded_balance, FALSE) AS payment_uploaded_balance,
  payment_uploaded_balance,
  COALESCE(payment_confirmed_initial, FALSE) AS payment_confirmed_initial,
  COALESCE(payment_confirmed_balance, FALSE) AS payment_confirmed_balance,
  payment_confirmed_initial,
  payment_confirmed_balance,
  COALESCE(loyalty_points_restaurant_obtained, 0) AS loyalty_points_restaurant_obtained,
  loyalty_reward_restaurant_obtained,
  COALESCE(NULLIF(TRIM(full_name), ''), '') AS delivery_name,
  COALESCE(NULLIF(TRIM(full_name), ''), '') AS full_name,
  COALESCE(NULLIF(TRIM(contact_number), ''), '') AS delivery_contact,
  COALESCE(NULLIF(TRIM(contact_number), ''), '') AS contact_number,
  delivery_address,
  delivery_lat,
  delivery_lng,
  delivery_time,
  COALESCE(submitted_order_dt_stamp, NOW()) AS created_at,
  submitted_order_dt_stamp,
  COALESCE(last_updated_order_status_dt_stamp, submitted_order_dt_stamp, NOW()) AS updated_at,
  last_updated_order_status_dt_stamp,
  order_source,
  ''::text AS pos_customer_label,
  COALESCE(cashier_amount_received_initial, 0) AS cashier_amount_received,
  cashier_amount_received_initial,
  COALESCE(cashier_amount_received_balance, 0) AS cashier_secondary_amount_received,
  cashier_amount_received_balance,
  0::numeric AS cashier_change,
  delivery_tracking_url,
  COALESCE(tray_items, '[]'::jsonb) AS order_lines_snapshot,
  tray_items,
  (upper(COALESCE(order_status, '')) LIKE '%CLAIMED%') AS pos_claimed,
  FALSE AS balance_proof_pending_review,
  guest_contact_email,
  customer_id
`.trim();

/** Minimal SELECT for cashier PATCH handlers (canonical columns only). */
export const RESTAURANT_ORDER_PATCH_SELECT = `
  mobile_id AS id,
  user_email,
  COALESCE(order_id, 'ORD-' || LPAD(mobile_id::text, 6, '0')) AS order_no,
  COALESCE(order_status, 'PENDING_CASHIER') AS status,
  COALESCE(total_cost, 0) AS total,
  order_source,
  cashier_amount_received_initial AS cashier_amount_received,
  payment_proof_balance AS supplemental_payment_proof,
  COALESCE(NULLIF(TRIM(payment_reference_balance), ''), '') AS payment_reference_balance,
  COALESCE(NULLIF(TRIM(payment_reference_initial), ''), '') AS payment_reference_initial,
  guest_contact_email,
  contact_number AS delivery_contact
`.trim();

/** Cashier online queue: mobile app + web restaurant orders (not walk-in POS). */
export const CASHIER_ONLINE_ORDER_WHERE = `
  mo.order_source <> 'POS'
  AND (
    (mo.user_email IS NOT NULL AND TRIM(mo.user_email) <> '')
    OR (mo.guest_contact_email IS NOT NULL AND TRIM(mo.guest_contact_email) <> '')
  )
`.trim();

export function restaurantLoyaltyEarnedSql(
  restaurantStepAmount: number,
  restaurantStepPoints: number,
): string {
  return `CASE
    WHEN LOWER(TRIM(COALESCE(user_email, ''))) LIKE '%@guest.curatering.internal' THEN 0
    WHEN upper(COALESCE(order_status, '')) LIKE '%ORDER CONFIRMED%'
      OR upper(COALESCE(order_status, '')) LIKE '%OVERPAYMENT%'
      THEN FLOOR(COALESCE(total_cost, 0)::numeric / ${restaurantStepAmount}::numeric)::int * ${restaurantStepPoints}
    ELSE COALESCE(loyalty_points_restaurant_obtained, 0)
  END AS loyalty_points_earned`;
}

export function mapRestaurantOrderRowForApi(row: Record<string, unknown>): Record<string, unknown> {
  const total = Number(row.total ?? row.total_cost ?? row.total_amount ?? 0);
  const orderNo = String(row.order_no ?? row.order_id ?? "").trim();
  const status = String(row.status ?? row.order_status ?? row.fulfillment_stage ?? "").trim();
  const fulfillment = String(row.fulfillment_stage ?? row.order_status ?? row.status ?? "PENDING_CASHIER").trim();
  const snap = row.order_lines_snapshot ?? row.tray_items ?? row.items;
  let items: unknown[] = [];
  if (snap != null) {
    const arr = Array.isArray(snap) ? snap : [];
    items = arr;
  }
  return {
    ...row,
    id: row.mobile_id ?? row.id,
    order_uuid: row.order_uuid ?? row.id ?? null,
    order_no: orderNo,
    order_id: row.order_id ?? orderNo,
    status,
    fulfillment_stage: fulfillment,
    order_status: status,
    total,
    total_cost: total,
    note: row.note ?? row.delivery_notes ?? "",
    delivery_notes: row.delivery_notes ?? row.note ?? "",
    payment_uploaded: row.payment_uploaded ?? row.payment_uploaded_initial ?? false,
    payment_proof: row.payment_proof ?? row.payment_proof_initial ?? null,
    supplemental_payment_proof:
      row.supplemental_payment_proof ?? row.payment_proof_balance ?? null,
    payment_reference_initial: String(row.payment_reference_initial ?? "").trim(),
    payment_reference_balance: String(row.payment_reference_balance ?? "").trim(),
    payment_confirmed_initial: row.payment_confirmed_initial ?? false,
    payment_confirmed_balance: row.payment_confirmed_balance ?? false,
    payment_uploaded_balance: row.payment_uploaded_balance ?? false,
    loyalty_points_earned: row.loyalty_points_earned ?? row.loyalty_points_restaurant_obtained ?? 0,
    loyalty_points_restaurant_obtained: row.loyalty_points_restaurant_obtained ?? row.loyalty_points_earned ?? 0,
    loyalty_reward_restaurant_obtained: row.loyalty_reward_restaurant_obtained ?? null,
    full_name: row.full_name ?? row.delivery_name ?? "",
    contact_number: row.contact_number ?? row.delivery_contact ?? "",
    items,
    order_lines_snapshot: snap,
    tray_items: snap,
  };
}

export function mapProfileRowForApi(row: Record<string, unknown>): Record<string, unknown> {
  const restaurant = Number(row.loyalty_points_restaurant ?? row.restaurant_loyalty_points ?? 0);
  const catering = Number(row.loyalty_points_catering ?? row.catering_loyalty_points ?? 0);
  const addrs = row.delivery_addresses ?? row.other_delivery_addresses ?? [];
  return {
    ...row,
    user_email: row.user_email ?? row.email ?? "",
    email: row.email ?? row.user_email ?? "",
    contact_email: row.email ?? row.user_email ?? "",
    delivery_address: row.delivery_address ?? row.primary_delivery_address ?? "",
    primary_delivery_address: row.primary_delivery_address ?? row.delivery_address ?? "",
    delivery_addresses: addrs,
    other_delivery_addresses: addrs,
    loyalty_points_restaurant: restaurant,
    loyalty_points_catering: catering,
    restaurant_loyalty_points: restaurant,
    catering_loyalty_points: catering,
    loyalty_points: Number(row.loyalty_points ?? restaurant + catering),
    customer_id: row.customer_id ?? null,
  };
}

/** SQL to read forgot-password OTP (canonical columns only). */
export const CUSTOMER_FORGOT_OTP_SELECT = `
  forgot_password_otp_code AS password_reset_otp,
  forgot_password_otp_code_expiry AS password_reset_expires_at
`.trim();

/** Manager catering/event post-analysis JSON (stored under checklist.post_analysis). */
export const POST_ANALYSIS_JSON = `COALESCE(checklist->'post_analysis', '{}'::jsonb)`;

/** Business transaction id TR-****** (catering_orders.catering_id). */
export const CATERING_TRANSACTION_ID = `COALESCE(NULLIF(TRIM(catering_id::text), ''), '')`;

/** Business transaction id TR-****** (event_orders.event_id). */
export const EVENT_TRANSACTION_ID = `COALESCE(NULLIF(TRIM(event_id::text), ''), '')`;

/** SET clause: persist post_analysis into checklist.post_analysis. */
export function postAnalysisPersistSet(paramRef: string): string {
  return `checklist = jsonb_set(
      COALESCE(checklist, '{}'::jsonb),
      '{post_analysis}',
      COALESCE(${paramRef}::jsonb, COALESCE(checklist->'post_analysis', '{}'::jsonb))
    )`;
}

export function postAnalysisPersistCoalesceSet(paramRef: string): string {
  return postAnalysisPersistSet(paramRef);
}

export function customerForgotOtpUpdateSql(): { set: string; clear: string } {
  return {
    set: `forgot_password_otp_code = $2,
          forgot_password_otp_code_expiry = $3,
          updated_pw_dt_stamp = NOW()`,
    clear: `forgot_password_otp_code = NULL,
            forgot_password_otp_code_expiry = NULL,
            updated_pw_dt_stamp = NOW()`,
  };
}
