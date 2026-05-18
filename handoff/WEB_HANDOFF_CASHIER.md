# Cashier / POS — Web repository handoff

Source of truth in this monorepo: **`packages/frontend/lib/main.dart`** (cashier UI ~lines **20099–22728**) and **`packages/backend/src/index.ts`** (POS routes ~lines **1668–2500**).

This document gives you **copy-paste TypeScript** for the web app API layer, data shapes, and backend contracts. The full Flutter UI is not duplicated here (2,600+ lines); extract it from `main.dart` using the line map below, or rebuild pages from the API + screen list.

---

## 1. Web dependencies (`package.json`)

```json
{
  "dependencies": {
    "react": "^18.0.0",
    "react-dom": "^18.0.0"
  }
}
```

Cashier web needs only **`fetch`** (or axios) for REST. Optional: image preview for GCash proofs (base64), date formatting (`date-fns` or `dayjs`).

**Flutter equivalents (mobile only):** `http`, `image_picker`, `intl`, `shared_preferences`, `flutter_local_notifications`.

**API base:** same as mobile, e.g. `https://curatering-mobile-production.up.railway.app`

---

## 2. Auth (cashier login)

| Method | Path | Body / query |
|--------|------|----------------|
| POST | `/api/mobile/auth/login` | `{ email, password, role: "cashier" }` |
| POST | `/api/mobile/auth/request-password-reset` | `{ email, role: "cashier" }` |
| POST | `/api/mobile/auth/check-password-reset-otp` | `{ email, role, otp }` |
| POST | `/api/mobile/auth/reset-password` | `{ email, role, otp, new_password }` |

Staff users live in DB table `users` with `role` / `pos_role` = `cashier`. Every POS call below sends **`cashier_email`** + **`cashier_password`** (session password from login).

**Shared with POS:** `GET /api/mobile/menu` — dish list for “New Order” tab (no cashier credentials required on mobile; confirm your web backend policy).

---

## 3. Cashier REST API (all require `cashier_email` + `cashier_password`)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/mobile/pos/online-orders/list` | Mobile/web customer orders (excludes `order_source = 'POS'`) |
| PATCH | `/api/mobile/pos/online-orders/:id/review` | `action`: `confirm` \| `insufficient` \| `overpayment` |
| POST | `/api/mobile/pos/online-orders/:id/remind-balance` | Email customer about insufficient balance |
| PATCH | `/api/mobile/pos/online-orders/:id/fulfillment` | `fulfillment_stage`: `PENDING_CASHIER`, `IN_PREPARATION`, `OUT_FOR_DELIVERY`, `DELIVERED` |
| POST | `/api/mobile/pos/walkin-order` | Create walk-in (`order_source = 'POS'`) → **201** |
| POST | `/api/mobile/pos/walkin-queue` | Body `{ filter: "preparing" \| "claimed" \| "cancelled" }` |
| PATCH | `/api/mobile/pos/walkin-orders/:id/claim` | Mark walk-in claimed |
| PATCH | `/api/mobile/pos/walkin-orders/:id/cancel` | Cancel walk-in |
| POST | `/api/mobile/pos/order-history` | Delivered online + claimed walk-in (limit 250) |

**Not cashier** (manager/supervisor only): `/api/mobile/pos/catering/*`

### Review PATCH body

```json
{
  "cashier_email": "cashier@example.com",
  "cashier_password": "***",
  "action": "confirm",
  "amount_received": 500.00,
  "supplemental_amount_received": 200.00
}
```

- **`confirm`**: first payment or balance after proof; may require `amount_received` and/or `supplemental_amount_received`.
- **`insufficient`**: mark underpaid; customer must pay remainder.
- **`overpayment`**: record overpayment path.

### Walk-in POST body

```json
{
  "cashier_email": "...",
  "cashier_password": "...",
  "payment_method": "CASH",
  "amount_received": 350,
  "note": "",
  "pos_customer_label": "Table 3",
  "payment_proof": "<base64 optional, required for GCASH>",
  "items": [
    { "item_name": "Adobo", "dip": "", "dip_qty": 0, "qty": 2, "price": 120 }
  ]
}
```

### Fulfillment PATCH body

```json
{
  "cashier_email": "...",
  "cashier_password": "...",
  "fulfillment_stage": "IN_PREPARATION",
  "delivery_tracking_url": "https://..."
}
```

---

## 4. Order JSON shape (from `RESTAURANT_ORDER_SELECT`)

Backend normalizes rows in `packages/backend/src/sqlCompat.ts`. Web client should accept:

| API field | Meaning |
|-----------|---------|
| `id` | `mobile_id` |
| `order_no` / `order_id` | `ORD-******` |
| `status` | Payment/confirmation status (long string) |
| `fulfillment_stage` | `PENDING_CASHIER`, `IN_PREPARATION`, `OUT_FOR_DELIVERY`, `DELIVERED` |
| `total` / `total_cost` | Order total |
| `payment_mode` | e.g. `GCASH`, `CASH` |
| `payment_uploaded` | Initial proof uploaded |
| `payment_proof` / `payment_proof_initial` | Base64 image or reference text |
| `supplemental_payment_proof` / `payment_proof_balance` | Balance proof |
| `payment_reference_initial` / `payment_reference_balance` | Text references |
| `cashier_amount_received` | Amount cashier recorded |
| `cashier_secondary_amount_received` | Balance payment amount |
| `balance_proof_pending_review` | Cashier must review balance proof |
| `pos_customer_label` | Walk-in label |
| `order_source` | `POS` = walk-in; else online/mobile |
| `customer_display_name` | Joined profile name |
| `guest_contact_email` | Guest checkout email |
| `delivery_name`, `delivery_contact`, `delivery_address`, `delivery_time` | Delivery fields |
| `order_lines_snapshot` / `tray_items` | Line items array |
| `loyalty_points_earned` | Points if confirmed |
| `created_at`, `updated_at` | Timestamps |

Line item (in snapshot):

```json
{ "item_name": "...", "dip": "", "dip_qty": 0, "qty": 1, "price": 99 }
```

---

## 5. TypeScript API client (drop into web repo)

Save as e.g. `src/lib/cashierPosApi.ts`:

```typescript
const API_BASE =
  process.env.NEXT_PUBLIC_API_BASE?.replace(/\/+$/, "") ??
  "https://curatering-mobile-production.up.railway.app";

export type CashierCreds = { cashierEmail: string; cashierPassword: string };

export type PosOrderLine = {
  item_name: string;
  dip?: string;
  dip_qty?: number;
  qty: number;
  price: number;
};

export type PosOrder = {
  id: number;
  order_no: string;
  status: string;
  fulfillment_stage: string;
  total: number;
  payment_mode: string;
  payment_uploaded: boolean;
  payment_proof?: string | null;
  supplemental_payment_proof?: string | null;
  payment_reference_initial?: string;
  payment_reference_balance?: string;
  cashier_amount_received?: number | null;
  cashier_secondary_amount_received?: number | null;
  balance_proof_pending_review?: boolean;
  pos_customer_label?: string;
  order_source?: string;
  customer_display_name?: string;
  guest_contact_email?: string;
  delivery_name?: string;
  delivery_contact?: string;
  delivery_address?: string;
  delivery_time?: string;
  delivery_tracking_url?: string;
  order_lines_snapshot?: PosOrderLine[];
  tray_items?: PosOrderLine[];
  loyalty_points_earned?: number;
  created_at?: string;
  updated_at?: string;
};

async function posJson<T>(
  path: string,
  init: RequestInit & { creds: CashierCreds },
): Promise<T> {
  const { creds, ...rest } = init;
  const res = await fetch(`${API_BASE}${path}`, {
    ...rest,
    headers: { "Content-Type": "application/json", ...(rest.headers ?? {}) },
    body: rest.body
      ? typeof rest.body === "string"
        ? rest.body
        : JSON.stringify({
            cashier_email: creds.cashierEmail.trim().toLowerCase(),
            cashier_password: creds.cashierPassword,
            ...JSON.parse(rest.body as string),
          })
      : JSON.stringify({
          cashier_email: creds.cashierEmail.trim().toLowerCase(),
          cashier_password: creds.cashierPassword,
        }),
  });
  if (!res.ok) {
    let msg = `HTTP ${res.status}`;
    try {
      const err = (await res.json()) as { error?: string };
      if (err.error) msg = err.error;
    } catch {
      /* ignore */
    }
    throw new Error(msg);
  }
  if (res.status === 204) return undefined as T;
  return res.json() as Promise<T>;
}

function bodyWithCreds(creds: CashierCreds, extra: Record<string, unknown>) {
  return JSON.stringify({
    cashier_email: creds.cashierEmail.trim().toLowerCase(),
    cashier_password: creds.cashierPassword,
    ...extra,
  });
}

export async function loginCashier(email: string, password: string) {
  const res = await fetch(`${API_BASE}/api/mobile/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: email.trim().toLowerCase(), password, role: "cashier" }),
  });
  if (!res.ok) throw new Error("Login failed");
  return res.json();
}

export function listOnlineOrders(creds: CashierCreds) {
  return posJson<PosOrder[]>("/api/mobile/pos/online-orders/list", {
    method: "POST",
    creds,
    body: bodyWithCreds(creds, {}),
  });
}

export function reviewOnlineOrder(
  creds: CashierCreds,
  orderId: number,
  action: "confirm" | "insufficient" | "overpayment",
  opts?: { amountReceived?: number; supplementalAmountReceived?: number },
) {
  return posJson<{ ok: boolean; status?: string }>(
    `/api/mobile/pos/online-orders/${orderId}/review`,
    {
      method: "PATCH",
      creds,
      body: bodyWithCreds(creds, {
        action,
        ...(opts?.amountReceived != null ? { amount_received: opts.amountReceived } : {}),
        ...(opts?.supplementalAmountReceived != null
          ? { supplemental_amount_received: opts.supplementalAmountReceived }
          : {}),
      }),
    },
  );
}

export function patchFulfillment(
  creds: CashierCreds,
  orderId: number,
  fulfillmentStage: string,
  deliveryTrackingUrl = "",
) {
  return posJson<{ ok: boolean }>(`/api/mobile/pos/online-orders/${orderId}/fulfillment`, {
    method: "PATCH",
    creds,
    body: bodyWithCreds(creds, {
      fulfillment_stage: fulfillmentStage,
      delivery_tracking_url: deliveryTrackingUrl,
    }),
  });
}

export function remindBalance(creds: CashierCreds, orderId: number) {
  return posJson<{ ok: boolean }>(`/api/mobile/pos/online-orders/${orderId}/remind-balance`, {
    method: "POST",
    creds,
    body: bodyWithCreds(creds, {}),
  });
}

export function submitWalkInOrder(
  creds: CashierCreds,
  payload: {
    paymentMethod: "CASH" | "GCASH";
    amountReceived: number;
    note?: string;
    posCustomerLabel?: string;
    paymentProofBase64?: string;
    items: PosOrderLine[];
  },
) {
  return fetch(`${API_BASE}/api/mobile/pos/walkin-order`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      cashier_email: creds.cashierEmail.trim().toLowerCase(),
      cashier_password: creds.cashierPassword,
      payment_method: payload.paymentMethod,
      amount_received: payload.amountReceived,
      note: payload.note ?? "",
      pos_customer_label: payload.posCustomerLabel ?? "",
      ...(payload.paymentProofBase64 ? { payment_proof: payload.paymentProofBase64 } : {}),
      items: payload.items,
    }),
  }).then(async (res) => {
    if (res.status !== 201) {
      const err = await res.json().catch(() => ({}));
      throw new Error((err as { error?: string }).error ?? `HTTP ${res.status}`);
    }
    return res.json() as Promise<{ id: number; order_no: string; total: number; change: number | null }>;
  });
}

export function walkInQueue(creds: CashierCreds, filter: "preparing" | "claimed" | "cancelled") {
  return posJson<PosOrder[]>("/api/mobile/pos/walkin-queue", {
    method: "POST",
    creds,
    body: bodyWithCreds(creds, { filter }),
  });
}

export function claimWalkIn(creds: CashierCreds, orderId: number) {
  return posJson<{ ok: boolean }>(`/api/mobile/pos/walkin-orders/${orderId}/claim`, {
    method: "PATCH",
    creds,
    body: bodyWithCreds(creds, {}),
  });
}

export function cancelWalkIn(creds: CashierCreds, orderId: number) {
  return posJson<{ ok: boolean }>(`/api/mobile/pos/walkin-orders/${orderId}/cancel`, {
    method: "PATCH",
    creds,
    body: bodyWithCreds(creds, {}),
  });
}

export function orderHistory(creds: CashierCreds) {
  return posJson<PosOrder[]>("/api/mobile/pos/order-history", {
    method: "POST",
    creds,
    body: bodyWithCreds(creds, {}),
  });
}
```

---

## 6. Client-side filters (port from `main.dart`)

```typescript
export function statusReadable(o: PosOrder): string {
  return (o.status ?? "").trim();
}

export function matchesPendingFilter(o: PosOrder, mode: string): boolean {
  const u = statusReadable(o).toUpperCase();
  switch (mode) {
    case "wait_payment":
      return (
        u.includes("WAITING FOR PAYMENT CONFIRMATION") ||
        u.includes("WAITING FOR ORDER CONFIRMATION") ||
        u.includes("WAITING FOR ORDER")
      );
    case "payment_insufficient":
      return u.includes("INSUFFICIENT") || u.includes("PAYMENT INSUFFICIENT");
    case "wait_balance":
      return (
        u.includes("BALANCE PAYMENT CONFIRMATION") ||
        u.includes("WAITING FOR BALANCE") ||
        (o.balance_proof_pending_review && !!o.supplemental_payment_proof?.trim())
      );
    default:
      return true;
  }
}

export function matchesPreparingFilter(o: PosOrder, mode: string): boolean {
  const u = (o.status ?? "").toUpperCase();
  if (mode === "payment_confirmed") return u.includes("ORDER CONFIRMED") && !u.includes("OVERPAYMENT");
  if (mode === "overpayment") return u.includes("OVERPAYMENT");
  return true;
}

export function isWalkIn(o: PosOrder): boolean {
  return (o.order_source ?? "").toUpperCase() === "POS";
}
```

---

## 7. Flutter screen map (extract from `main.dart`)

| Lines (approx) | Widget | Role |
|----------------|--------|------|
| 29–32, 45 | `kPosLoginBuild`, `runCurateringApp` | Staff build entry |
| 399 | Route to `PosShellScreen` when `userRole == 'cashier'` |
| 1125–1344 | `OrderData`, `orderDataFromApiMap`, payment helpers | Models |
| 1797–1843 | `orderMatchesCashierOnline*Filter` | List filters |
| 4229–4590 | `AppState` cashier API methods | **Same as §5 TypeScript** |
| 4593+ | `AuthScreen(cashierMode: true)` | Login |
| 13482+ | `PosOrderHistoryScreen` | History drawer |
| 20101–20231 | `PosShellScreen` | 3 tabs shell |
| 20233+ | `PosNewOrderTab` | Menu + tray |
| 20542+ | `PosWalkInCheckoutScreen` | Walk-in checkout |
| 20946+ | `PosWalkInOngoingTab` | Walk-in queues |
| 21391+ | `PosOnlineOrdersTab` | Online queues |
| 21826+ | `PosOnlineOrderDetailScreen` | Review / fulfillment |

**Staff entry file:** `packages/frontend/lib/main_staff.dart` → `runCurateringApp(forcePosLogin: true)`.

**Build APK (staff):**

```bash
flutter build apk --release --flavor staff \
  --dart-define=APP_FLAVOR=staff \
  --dart-define=DEFAULT_API_BASE=https://curatering-mobile-production.up.railway.app
```

---

## 8. Suggested web page structure

```
/cashier/login
/cashier                    → shell: tabs New Order | Online | Walk-in
/cashier/online/:id         → review + fulfillment
/cashier/walk-in/checkout   → tray checkout
/cashier/history            → order history
```

Store `cashierEmail` + `cashierPassword` in session (httpOnly cookie or secure sessionStorage). Never log passwords.

---

## 9. Backend files to keep in sync

| File | Contents |
|------|----------|
| `packages/backend/src/index.ts` | All `/api/mobile/pos/*` handlers, `verifyPosStaff`, `insertPosWalkInOrder` |
| `packages/backend/src/sqlCompat.ts` | `RESTAURANT_ORDER_SELECT`, `CASHIER_ONLINE_ORDER_WHERE`, `mapRestaurantOrderRowForApi` |
| `packages/backend/src/db.ts` | `restaurant_orders` POS columns, `users` cashier role |

---

## 10. Customer → cashier pipeline (web orders)

Customers upload payment via `PATCH /api/mobile/orders/:id/payment` → status becomes waiting for cashier → appears in `online-orders/list` when `CASHIER_ONLINE_ORDER_WHERE` matches (not POS, has email or guest email).

Optional env: `CASHIER_BALANCE_NOTIFY_EMAIL` for balance-proof email alerts.
