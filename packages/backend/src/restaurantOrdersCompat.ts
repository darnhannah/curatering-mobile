/**
 * Canonical restaurant_orders column usage (online vs walk-in).
 */

export const WALK_IN_ORDER_SOURCES = ["POS", "POS_MOBILE", "POS_WEB"] as const;

export function isWalkInOrderSource(orderSource: string | null | undefined): boolean {
  const s = String(orderSource ?? "")
    .trim()
    .toUpperCase();
  return WALK_IN_ORDER_SOURCES.includes(s as (typeof WALK_IN_ORDER_SOURCES)[number]);
}

export function restaurantFulfillmentStageExpr(alias?: string): string {
  const src = alias ? `${alias}.order_source` : "order_source";
  const st = alias ? `${alias}.order_status` : "order_status";
  const claimed = alias ? `${alias}.pos_claimed` : "pos_claimed";
  return `CASE
    WHEN upper(COALESCE(${src}, '')) IN ('POS', 'POS_MOBILE', 'POS_WEB') THEN
      CASE WHEN COALESCE(${claimed}, FALSE) THEN 'DELIVERED' ELSE 'IN_PREPARATION' END
    WHEN upper(COALESCE(${st}, '')) LIKE '%DELIVERED%' THEN 'DELIVERED'
    WHEN upper(COALESCE(${st}, '')) LIKE '%OUT_FOR_DELIVERY%'
      OR upper(COALESCE(${st}, '')) LIKE '%FOR DELIVERY%' THEN 'OUT_FOR_DELIVERY'
    WHEN upper(COALESCE(${st}, '')) LIKE '%IN_PREPARATION%'
      OR upper(COALESCE(${st}, '')) LIKE '%ORDER CONFIRMED%'
      OR upper(COALESCE(${st}, '')) LIKE '%OVERPAYMENT%'
      OR upper(COALESCE(${st}, '')) LIKE '%PREPARING%' THEN 'IN_PREPARATION'
    ELSE 'PENDING_CASHIER'
  END`;
}

export function restaurantOrderIdExpr(alias?: string): string {
  const oid = alias ? `${alias}.order_id` : "order_id";
  const mid = alias ? `${alias}.mobile_id` : "mobile_id";
  return `COALESCE(NULLIF(TRIM(${oid}), ''), CASE WHEN ${mid} IS NOT NULL THEN 'ORD-' || LPAD(${mid}::text, 6, '0') END)`;
}

function col(alias: string | undefined, name: string): string {
  return alias ? `${alias}.${name}` : name;
}

/** Full SELECT — canonical DB columns + API aliases for mobile/web clients. */
export function restaurantOrderSelectSql(alias?: string): string {
  const a = alias;
  const orderId = restaurantOrderIdExpr(a);
  const fulfill = restaurantFulfillmentStageExpr(a);
  const walk = isWalkInOrderSource; // unused in SQL — inline below
  void walk;
  return `
  ${col(a, "mobile_id")},
  ${col(a, "mobile_id")} AS id,
  ${col(a, "id")} AS order_uuid,
  ${orderId} AS order_id,
  ${orderId} AS order_no,
  COALESCE(${col(a, "order_status")}, 'PENDING_CASHIER') AS order_status,
  COALESCE(${col(a, "order_status")}, 'PENDING_CASHIER') AS status,
  ${fulfill} AS fulfillment_stage,
  COALESCE(${col(a, "total_cost")}, 0) AS total_cost,
  COALESCE(${col(a, "total_cost")}, 0) AS total,
  COALESCE(${col(a, "tray_items")}, '[]'::jsonb) AS tray_items,
  COALESCE(${col(a, "tray_items")}, '[]'::jsonb) AS order_lines_snapshot,
  COALESCE(${col(a, "loyalty_points_restaurant_obtained")}, 0) AS loyalty_points_restaurant_obtained,
  COALESCE(${col(a, "loyalty_points_restaurant_obtained")}, 0) AS loyalty_points_earned,
  ${col(a, "loyalty_reward_restaurant_obtained")},
  ${col(a, "order_source")},
  ${col(a, "user_email")},
  ${col(a, "full_name")},
  COALESCE(NULLIF(TRIM(${col(a, "full_name")}), ''), '') AS delivery_name,
  ${col(a, "contact_number")},
  COALESCE(NULLIF(TRIM(${col(a, "contact_number")}), ''), '') AS delivery_contact,
  ${col(a, "delivery_address")},
  ${col(a, "delivery_lat")},
  ${col(a, "delivery_lng")},
  COALESCE(${col(a, "delivery_notes")}, '') AS delivery_notes,
  COALESCE(${col(a, "delivery_notes")}, '') AS note,
  ${col(a, "note")} AS walk_in_note,
  ${col(a, "delivery_tracking_url")},
  ${col(a, "delivery_time")},
  COALESCE(${col(a, "payment_mode")}, 'GCASH ONLY') AS payment_mode,
  ${col(a, "payment_method")},
  COALESCE(NULLIF(TRIM(${col(a, "payment_reference_initial")}), ''), '') AS payment_reference_initial,
  COALESCE(NULLIF(TRIM(${col(a, "payment_reference_balance")}), ''), '') AS payment_reference_balance,
  ${col(a, "payment_proof_initial")},
  ${col(a, "payment_proof_balance")},
  CASE
    WHEN upper(COALESCE(${col(a, "order_source")}, '')) IN ('POS', 'POS_MOBILE', 'POS_WEB')
      THEN ${col(a, "payment_proof")}
    ELSE ${col(a, "payment_proof_initial")}
  END AS payment_proof,
  CASE
    WHEN upper(COALESCE(${col(a, "order_source")}, '')) IN ('POS', 'POS_MOBILE', 'POS_WEB')
      THEN NULL::text
    ELSE ${col(a, "payment_proof_balance")}
  END AS supplemental_payment_proof,
  COALESCE(${col(a, "payment_uploaded_initial")}, FALSE) AS payment_uploaded_initial,
  COALESCE(${col(a, "payment_uploaded_balance")}, FALSE) AS payment_uploaded_balance,
  CASE
    WHEN upper(COALESCE(${col(a, "order_source")}, '')) IN ('POS', 'POS_MOBILE', 'POS_WEB')
      THEN COALESCE(${col(a, "payment_uploaded")}, FALSE)
    ELSE COALESCE(${col(a, "payment_uploaded_initial")}, FALSE)
  END AS payment_uploaded,
  COALESCE(${col(a, "payment_confirmed_initial")}, FALSE) AS payment_confirmed_initial,
  COALESCE(${col(a, "payment_confirmed_balance")}, FALSE) AS payment_confirmed_balance,
  ${col(a, "cashier_amount_received_initial")},
  COALESCE(${col(a, "cashier_amount_received_initial")}, 0) AS cashier_amount_received,
  ${col(a, "cashier_amount_received_balance")},
  COALESCE(${col(a, "cashier_amount_received_balance")}, 0) AS cashier_secondary_amount_received,
  ${col(a, "amount_paid")},
  ${col(a, "change_given")},
  COALESCE(${col(a, "change_given")}, 0) AS cashier_change,
  ${col(a, "pos_customer_label")},
  COALESCE(${col(a, "pos_claimed")}, FALSE) AS pos_claimed,
  COALESCE(${col(a, "balance_proof_pending_review")}, FALSE) AS balance_proof_pending_review,
  ${col(a, "pos_claimed_at")},
  ${col(a, "feedback_stars")},
  ${col(a, "feedback_remarks")},
  ${col(a, "feedback_submitted_at")},
  COALESCE(${col(a, "submitted_order_dt_stamp")}, NOW()) AS created_at,
  ${col(a, "submitted_order_dt_stamp")},
  COALESCE(${col(a, "last_updated_order_status_dt_stamp")}, ${col(a, "submitted_order_dt_stamp")}, NOW()) AS updated_at,
  ${col(a, "last_updated_order_status_dt_stamp")},
  ${col(a, "customer_id")}
`.trim();
}

/** List SELECT — omits large proof blobs; keeps references and tray lines. */
export function restaurantOrderListSelectSql(alias?: string): string {
  const a = alias;
  const orderId = restaurantOrderIdExpr(a);
  const fulfill = restaurantFulfillmentStageExpr(a);
  return `
  ${col(a, "mobile_id")},
  ${col(a, "mobile_id")} AS id,
  ${col(a, "id")} AS order_uuid,
  ${orderId} AS order_id,
  ${orderId} AS order_no,
  COALESCE(${col(a, "order_status")}, 'PENDING_CASHIER') AS order_status,
  COALESCE(${col(a, "order_status")}, 'PENDING_CASHIER') AS status,
  ${fulfill} AS fulfillment_stage,
  COALESCE(${col(a, "total_cost")}, 0) AS total_cost,
  COALESCE(${col(a, "total_cost")}, 0) AS total,
  COALESCE(${col(a, "tray_items")}, '[]'::jsonb) AS tray_items,
  COALESCE(${col(a, "tray_items")}, '[]'::jsonb) AS order_lines_snapshot,
  COALESCE(${col(a, "loyalty_points_restaurant_obtained")}, 0) AS loyalty_points_restaurant_obtained,
  COALESCE(${col(a, "loyalty_points_restaurant_obtained")}, 0) AS loyalty_points_earned,
  ${col(a, "loyalty_reward_restaurant_obtained")},
  ${col(a, "order_source")},
  ${col(a, "user_email")},
  ${col(a, "full_name")},
  COALESCE(NULLIF(TRIM(${col(a, "full_name")}), ''), '') AS delivery_name,
  ${col(a, "contact_number")},
  COALESCE(NULLIF(TRIM(${col(a, "contact_number")}), ''), '') AS delivery_contact,
  ${col(a, "delivery_address")},
  ${col(a, "delivery_lat")},
  ${col(a, "delivery_lng")},
  COALESCE(${col(a, "delivery_notes")}, '') AS delivery_notes,
  COALESCE(${col(a, "delivery_notes")}, '') AS note,
  ${col(a, "note")} AS walk_in_note,
  ${col(a, "delivery_tracking_url")},
  ${col(a, "delivery_time")},
  COALESCE(${col(a, "payment_mode")}, 'GCASH ONLY') AS payment_mode,
  ${col(a, "payment_method")},
  COALESCE(NULLIF(TRIM(${col(a, "payment_reference_initial")}), ''), '') AS payment_reference_initial,
  COALESCE(NULLIF(TRIM(${col(a, "payment_reference_balance")}), ''), '') AS payment_reference_balance,
  NULL::text AS payment_proof_initial,
  NULL::text AS payment_proof_balance,
  NULL::text AS payment_proof,
  NULL::text AS supplemental_payment_proof,
  COALESCE(${col(a, "payment_uploaded_initial")}, FALSE) AS payment_uploaded_initial,
  COALESCE(${col(a, "payment_uploaded_balance")}, FALSE) AS payment_uploaded_balance,
  CASE
    WHEN upper(COALESCE(${col(a, "order_source")}, '')) IN ('POS', 'POS_MOBILE', 'POS_WEB')
      THEN COALESCE(${col(a, "payment_uploaded")}, FALSE)
    ELSE COALESCE(${col(a, "payment_uploaded_initial")}, FALSE)
  END AS payment_uploaded,
  COALESCE(${col(a, "payment_confirmed_initial")}, FALSE) AS payment_confirmed_initial,
  COALESCE(${col(a, "payment_confirmed_balance")}, FALSE) AS payment_confirmed_balance,
  ${col(a, "cashier_amount_received_initial")},
  COALESCE(${col(a, "cashier_amount_received_initial")}, 0) AS cashier_amount_received,
  ${col(a, "cashier_amount_received_balance")},
  COALESCE(${col(a, "cashier_amount_received_balance")}, 0) AS cashier_secondary_amount_received,
  ${col(a, "amount_paid")},
  ${col(a, "change_given")},
  COALESCE(${col(a, "change_given")}, 0) AS cashier_change,
  ${col(a, "pos_customer_label")},
  COALESCE(${col(a, "pos_claimed")}, FALSE) AS pos_claimed,
  COALESCE(${col(a, "balance_proof_pending_review")}, FALSE) AS balance_proof_pending_review,
  ${col(a, "pos_claimed_at")},
  ${col(a, "feedback_stars")},
  ${col(a, "feedback_remarks")},
  ${col(a, "feedback_submitted_at")},
  COALESCE(${col(a, "submitted_order_dt_stamp")}, NOW()) AS created_at,
  ${col(a, "submitted_order_dt_stamp")},
  COALESCE(${col(a, "last_updated_order_status_dt_stamp")}, ${col(a, "submitted_order_dt_stamp")}, NOW()) AS updated_at,
  ${col(a, "last_updated_order_status_dt_stamp")},
  ${col(a, "customer_id")}
`.trim();
}

export const RESTAURANT_ORDER_SELECT = restaurantOrderSelectSql();
export const RESTAURANT_ORDER_LIST_SELECT = restaurantOrderListSelectSql();

export const RESTAURANT_ORDER_ONLINE_WHERE = `
  upper(COALESCE(mo.order_source, '')) NOT IN ('POS', 'POS_MOBILE', 'POS_WEB')
  AND mo.user_email IS NOT NULL
  AND TRIM(mo.user_email) <> ''
`.trim();

export const RESTAURANT_ORDER_WALKIN_WHERE = `
  upper(COALESCE(order_source, '')) IN ('POS', 'POS_MOBILE', 'POS_WEB')
`.trim();

/** Same as RESTAURANT_ORDER_ONLINE_WHERE without table alias (for UPDATE … WHERE). */
export const RESTAURANT_ORDER_ONLINE_WHERE_UNALIASED = `
  upper(COALESCE(order_source, '')) NOT IN ('POS', 'POS_MOBILE', 'POS_WEB')
  AND user_email IS NOT NULL
  AND TRIM(user_email) <> ''
`.trim();

export function mapRestaurantOrderRowForApi(row: Record<string, unknown>): Record<string, unknown> {
  const orderSource = String(row.order_source ?? "").trim();
  const walkIn = isWalkInOrderSource(orderSource);
  const total = Number(row.total_cost ?? row.total ?? 0);
  const orderId = String(row.order_id ?? row.order_no ?? "").trim();
  const status = String(row.order_status ?? row.status ?? "").trim();
  const fulfillment = String(row.fulfillment_stage ?? status).trim();
  const snap = row.tray_items ?? row.order_lines_snapshot;
  const trayArr = Array.isArray(snap) ? snap : [];
  const posLabel = String(row.pos_customer_label ?? "").trim();
  const fullName = String(row.full_name ?? row.delivery_name ?? "").trim();
  const customerDisplay =
    String(row.customer_display_name ?? "").trim() || posLabel || fullName || String(row.user_email ?? "").trim();

  const paymentProof = walkIn
    ? row.payment_proof
    : row.payment_proof_initial ?? row.payment_proof;
  const supplementalProof = walkIn ? null : row.payment_proof_balance ?? row.supplemental_payment_proof;
  const note = walkIn
    ? String(row.walk_in_note ?? row.note ?? "").trim()
    : String(row.delivery_notes ?? row.note ?? "").trim();

  return {
    ...row,
    id: row.mobile_id ?? row.id,
    order_uuid: row.order_uuid ?? row.id ?? null,
    order_id: orderId,
    order_no: orderId,
    order_source: orderSource,
    status,
    order_status: status,
    fulfillment_stage: fulfillment,
    total,
    total_cost: total,
    tray_items: snap,
    order_lines_snapshot: snap,
    items: trayArr,
    note,
    delivery_notes: note,
    walk_in_note: walkIn ? note : "",
    full_name: fullName,
    delivery_name: fullName,
    contact_number: String(row.contact_number ?? row.delivery_contact ?? "").trim(),
    delivery_contact: String(row.contact_number ?? row.delivery_contact ?? "").trim(),
    payment_uploaded: walkIn ? row.payment_uploaded : row.payment_uploaded_initial ?? row.payment_uploaded,
    payment_uploaded_initial: row.payment_uploaded_initial ?? false,
    payment_uploaded_balance: row.payment_uploaded_balance ?? false,
    payment_proof: paymentProof,
    payment_proof_initial: paymentProof,
    supplemental_payment_proof: supplementalProof,
    payment_proof_balance: supplementalProof,
    payment_reference_initial: String(row.payment_reference_initial ?? "").trim(),
    payment_reference_balance: String(row.payment_reference_balance ?? "").trim(),
    payment_confirmed_initial: row.payment_confirmed_initial ?? false,
    payment_confirmed_balance: row.payment_confirmed_balance ?? false,
    loyalty_points_restaurant_obtained: row.loyalty_points_restaurant_obtained ?? 0,
    loyalty_points_earned: row.loyalty_points_earned ?? row.loyalty_points_restaurant_obtained ?? 0,
    loyalty_reward_restaurant_obtained: row.loyalty_reward_restaurant_obtained ?? null,
    cashier_amount_received: row.cashier_amount_received_initial ?? row.cashier_amount_received ?? 0,
    cashier_amount_received_initial: row.cashier_amount_received_initial,
    cashier_secondary_amount_received: row.cashier_amount_received_balance ?? 0,
    cashier_amount_received_balance: row.cashier_amount_received_balance,
    cashier_change: row.change_given ?? row.cashier_change ?? 0,
    amount_paid: row.amount_paid,
    change_given: row.change_given,
    payment_method: row.payment_method,
    pos_customer_label: posLabel,
    pos_claimed: row.pos_claimed ?? false,
    balance_proof_pending_review: row.balance_proof_pending_review ?? false,
    customer_display_name: customerDisplay || null,
    user_email: row.user_email,
    guest_contact_email: null,
  };
}
