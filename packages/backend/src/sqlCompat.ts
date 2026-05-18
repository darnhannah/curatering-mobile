/**
 * SQL fragments and row normalizers so APIs stay stable while the DB uses canonical column names.
 */

/** Touch timestamp on customer_accounts (legacy updated_at was pruned). */
export const CUSTOMER_ACCOUNT_TOUCH = `updated_pw_dt_stamp = NOW()`;

/** Business order number ORD-****** from `order_id` column (not legacy empty `order_no`). */
export const RESTAURANT_ORDER_BUSINESS_ID_SQL = `
  COALESCE(
    NULLIF(TRIM(order_id), ''),
    NULLIF(TRIM(order_no), ''),
    CASE WHEN mobile_id IS NOT NULL THEN 'ORD-' || LPAD(mobile_id::text, 6, '0') END
  )
`.trim();

/** Shared SELECT list for restaurant order API responses (legacy aliases included). */
export const RESTAURANT_ORDER_SELECT = `
  mobile_id,
  mobile_id AS id,
  user_email,
  ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_id,
  ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_no,
  COALESCE(order_status, 'PENDING_CASHIER') AS status,
  COALESCE(order_status, 'PENDING_CASHIER') AS fulfillment_stage,
  COALESCE(total_cost, total, 0) AS total,
  COALESCE(total_cost, total, 0) AS total_cost,
  COALESCE(delivery_notes, note, '') AS note,
  COALESCE(delivery_notes, note, '') AS delivery_notes,
  payment_mode,
  COALESCE(payment_uploaded_initial, payment_uploaded, FALSE) AS payment_uploaded,
  COALESCE(payment_uploaded_initial, payment_uploaded, FALSE) AS payment_uploaded_initial,
  COALESCE(payment_proof_initial, payment_proof) AS payment_proof,
  COALESCE(payment_proof_initial, payment_proof) AS payment_proof_initial,
  COALESCE(payment_proof_balance, supplemental_payment_proof) AS supplemental_payment_proof,
  COALESCE(payment_proof_balance, supplemental_payment_proof) AS payment_proof_balance,
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
  COALESCE(NULLIF(TRIM(full_name), ''), NULLIF(TRIM(delivery_name), ''), '') AS delivery_name,
  COALESCE(NULLIF(TRIM(full_name), ''), NULLIF(TRIM(delivery_name), ''), '') AS full_name,
  COALESCE(NULLIF(TRIM(contact_number), ''), NULLIF(TRIM(delivery_contact), ''), '') AS delivery_contact,
  COALESCE(NULLIF(TRIM(contact_number), ''), NULLIF(TRIM(delivery_contact), ''), '') AS contact_number,
  delivery_address,
  delivery_time,
  COALESCE(submitted_order_dt_stamp, NOW()) AS created_at,
  submitted_order_dt_stamp,
  COALESCE(last_updated_order_status_dt_stamp, submitted_order_dt_stamp, NOW()) AS updated_at,
  last_updated_order_status_dt_stamp,
  order_source,
  COALESCE(NULLIF(TRIM(pos_customer_label), ''), '') AS pos_customer_label,
  COALESCE(cashier_amount_received_initial, cashier_amount_received, 0) AS cashier_amount_received,
  COALESCE(cashier_amount_received_initial, cashier_amount_received) AS cashier_amount_received_initial,
  COALESCE(cashier_amount_received_balance, cashier_secondary_amount_received, 0) AS cashier_secondary_amount_received,
  COALESCE(cashier_amount_received_balance, cashier_secondary_amount_received, 0) AS cashier_amount_received_balance,
  0::numeric AS cashier_change,
  delivery_tracking_url,
  COALESCE(tray_items, order_lines_snapshot, '[]'::jsonb) AS order_lines_snapshot,
  COALESCE(tray_items, order_lines_snapshot, '[]'::jsonb) AS tray_items,
  (upper(COALESCE(order_status, '')) LIKE '%CLAIMED%') AS pos_claimed,
  COALESCE(balance_proof_pending_review, FALSE) AS balance_proof_pending_review,
  guest_contact_email,
  customer_id
`.trim();

/** Minimal SELECT for cashier PATCH handlers (canonical columns only). */
export const RESTAURANT_ORDER_PATCH_SELECT = `
  mobile_id AS id,
  user_email,
  ${RESTAURANT_ORDER_BUSINESS_ID_SQL} AS order_no,
  COALESCE(order_status, 'PENDING_CASHIER') AS status,
  COALESCE(total_cost, total, 0) AS total,
  order_source,
  COALESCE(cashier_amount_received_initial, cashier_amount_received) AS cashier_amount_received,
  COALESCE(balance_proof_pending_review, FALSE) AS balance_proof_pending_review,
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
  let orderNo = String(row.order_id ?? row.order_no ?? "").trim();
  if (!orderNo || orderNo.toUpperCase() === "TEMP") {
    orderNo = String(row.order_no ?? "").trim();
  }
  if (!orderNo || orderNo.toUpperCase() === "TEMP") {
    const mid = row.mobile_id ?? row.id;
    if (mid != null && `${mid}`.trim() !== "") {
      const digits = `${mid}`.replace(/\D/g, "");
      if (digits) orderNo = `ORD-${digits.padStart(6, "0").slice(-6)}`;
    }
  }
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

/** API `created_at` for catering/event orders (canonical timestamps; legacy columns may be pruned). */
export const CATERING_ORDER_CREATED_AT_SQL = `COALESCE(
  submitted_order_dt_stamp,
  created_at,
  stage_entered_at,
  NOW()
)`.trim();

/** API `updated_at` for catering/event orders. */
export const CATERING_ORDER_UPDATED_AT_SQL = `COALESCE(
  last_updated_order_status_dt_stamp,
  submitted_order_dt_stamp,
  created_at,
  stage_entered_at,
  NOW()
)`.trim();

/** Touch row after catering/event order mutation (works without `updated_at` column). */
export const CATERING_ORDER_TOUCH_SET = `last_updated_order_status_dt_stamp = NOW()`;

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

/** Strip spaces/dashes so "123 456" and "123456" match stored OTP. */
export function normalizeOtpDigits(raw: unknown): string {
  return String(raw ?? "").replace(/\D/g, "");
}

/** SQL expression: normalized OTP column equals normalized parameter. */
export function sqlOtpMatches(columnRef: string, paramRef: string): string {
  return `REGEXP_REPLACE(COALESCE(${columnRef}, ''), '[^0-9]', '', 'g') = REGEXP_REPLACE(COALESCE(${paramRef}::text, ''), '[^0-9]', '', 'g')`;
}

/** True when Postgres reports a missing column (SQLSTATE 42703). */
export function isPgUndefinedColumn(err: unknown): boolean {
  const e = err as { code?: string };
  return e?.code === "42703";
}

/** Strip data-URI prefix and whitespace from client payment proof payloads. */
export function normalizePaymentProofBase64(raw: unknown): string {
  let s = String(raw ?? "").trim();
  const comma = s.indexOf(",");
  if (s.toLowerCase().startsWith("data:") && comma >= 0) {
    s = s.slice(comma + 1).trim();
  }
  return s.replace(/\s+/g, "");
}
