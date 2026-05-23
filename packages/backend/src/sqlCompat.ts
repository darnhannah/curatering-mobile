/**
 * SQL fragments and row normalizers so APIs stay stable while the DB uses canonical column names.
 */

export {
  RESTAURANT_ORDER_LIST_SELECT,
  RESTAURANT_ORDER_ONLINE_WHERE,
  RESTAURANT_ORDER_ONLINE_WHERE_UNALIASED,
  RESTAURANT_ORDER_SELECT,
  RESTAURANT_ORDER_WALKIN_WHERE,
  isWalkInOrderSource,
  mapRestaurantOrderRowForApi,
  restaurantFulfillmentStageExpr,
  restaurantOrderIdExpr,
  restaurantOrderListSelectSql,
  restaurantOrderSelectSql,
} from "./restaurantOrdersCompat.js";

/** Touch timestamp on customer_accounts (legacy updated_at was pruned). */
export const CUSTOMER_ACCOUNT_TOUCH = `updated_pw_dt_stamp = NOW()`;

/** Change-detection timestamps (production DB may not have updated_at on all tables). */
export const MENU_CHANGED_AT_SQL = `COALESCE(created_at, NOW())`;
export const CATERING_ORDER_CHANGED_AT_SQL = `COALESCE(stage_entered_at, created_at, NOW())`;

function col(alias: string | undefined, name: string): string {
  return alias ? `${alias}.${name}` : name;
}

/** Minimal SELECT for cashier PATCH handlers (canonical columns only). */
export const RESTAURANT_ORDER_PATCH_SELECT = `
  mobile_id AS id,
  user_email,
  COALESCE(NULLIF(TRIM(order_id), ''), 'ORD-' || LPAD(mobile_id::text, 6, '0')) AS order_no,
  order_id,
  COALESCE(order_status, 'PENDING_CASHIER') AS status,
  COALESCE(total_cost, 0) AS total,
  order_source,
  cashier_amount_received_initial AS cashier_amount_received,
  cashier_amount_received_balance,
  payment_proof_balance,
  payment_reference_balance,
  payment_reference_initial,
  contact_number,
  pos_claimed,
  balance_proof_pending_review
`.trim();

/** @deprecated Use RESTAURANT_ORDER_ONLINE_WHERE */
export const CASHIER_ONLINE_ORDER_WHERE = `
  mo.order_source NOT IN ('POS', 'POS_MOBILE', 'POS_WEB')
  AND mo.user_email IS NOT NULL
  AND TRIM(mo.user_email) <> ''
`.trim();

export function restaurantLoyaltyEarnedSql(
  restaurantStepAmount: number,
  restaurantStepPoints: number,
  alias?: string,
): string {
  const userEmail = col(alias, "user_email");
  const orderStatus = col(alias, "order_status");
  const totalCost = col(alias, "total_cost");
  const loyaltyPts = col(alias, "loyalty_points_restaurant_obtained");
  return `CASE
    WHEN LOWER(TRIM(COALESCE(${userEmail}, ''))) LIKE '%@guest.curatering.internal' THEN 0
    WHEN upper(COALESCE(${orderStatus}, '')) LIKE '%ORDER CONFIRMED%'
      OR upper(COALESCE(${orderStatus}, '')) LIKE '%OVERPAYMENT%'
      THEN FLOOR(COALESCE(${totalCost}, 0)::numeric / ${restaurantStepAmount}::numeric)::int * ${restaurantStepPoints}
    ELSE COALESCE(${loyaltyPts}, 0)
  END AS loyalty_points_earned`;
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

/** Catering rows may still have a legacy post_analysis column; event_orders uses checklist only. */
export const POST_ANALYSIS_JSON = `COALESCE(
  CASE
    WHEN jsonb_typeof(COALESCE(checklist, '[]'::jsonb)) = 'object'
      THEN NULLIF(checklist->'post_analysis', 'null'::jsonb)
    ELSE NULL
  END,
  COALESCE(post_analysis, '{}'::jsonb),
  '{}'::jsonb
)`;

export {
  CATERING_POST_ANALYSIS_JSON,
  CATERING_TRANSACTION_ID,
  EVENT_POST_ANALYSIS_JSON,
  EVENT_TRANSACTION_ID,
  cateringCostBreakdownSql,
  cateringEventSettingSql,
  cateringMenuModificationsSql,
  cateringSelectedSetMenuSql,
  cateringServiceIncludedSql,
  eventAdditionalCostsSql,
  eventCostBreakdownSql,
  eventMenuModificationsSql,
  eventPostAnalysisPersistSet,
  eventSelectedSetMenuSql,
  eventServiceIncludedSql,
  eventSettingSql,
} from "./eventOrdersCompat.js";

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
