# Curatering — full customer & guest web handoff

Snapshot for porting **customer** (registered account) and **guest** (no account) mobile flows to web.

## Package layout

| Path | Contents |
|------|----------|
| `frontend/` | Flutter `lib/`: `main.dart` (~26k lines, monolith), `main_customer.dart` entry, event theme + seating modules, utils, `pubspec.yaml` |
| `backend/` | Full Express API (`index.ts`), `db.ts`, `eventDesignSeating.ts`, compat layers, mail/SMS/guest notify, SQL migrations |

Unlike the **staff** handoff, this bundle **includes** theme-design and seating-plan **backend** (`eventDesignSeating.ts`, public RunPod/Pexels proxy routes, `registerEventDesignSeatingRoutes`).

Staff POS routes (`/api/mobile/pos/*`) are present in `index.ts` for parity with production but are **out of scope** for the customer/guest web app — see below.

## Roles & entry (Flutter)

| Mode | Entry | Shell after session |
|------|--------|---------------------|
| **Guest** | `CustomerPreAuthShell` auto-starts guest session → `GuestCustomerShell` (bottom nav: Menu, Inquire, Track, Log in) | No account; `userEmail` is internal `guest_*@guest.curatering.internal` |
| **Registered customer** | `AuthScreen` login/sign-up → `CustomerDashboardScreen` | Drawer + dashboard tiles |

`main_customer.dart` → `runCurateringApp(forcePosLogin: false)`.

Routing: `frontend/lib/main.dart` (`CurateringApp` home builder, ~lines 407–426).

## Frontend: what to read first

1. **`main_customer.dart`** — customer app entry.
2. **`main.dart`** — search for:
   - `CustomerPreAuthShell`, `GuestCustomerShell`, `CustomerDashboardScreen`
   - `RestaurantMenuScreen`, `CheckoutScreen`, `PaymentScreen`, `OrderStatusScreen`
   - `InquiryScreen`, `MyOrdersScreen`, `MyInquiriesScreen`, `GuestTrackOrdersScreen`
   - `AuthScreen`, `SettingsScreen` (customer logout → guest menu)
3. **Theme / seating (customer)** — `lib/features/event_design/`, `lib/features/seating/`
4. **Utils** — `allergen_ui.dart`, `order_type_utils.dart`, `theme_design_venue_refs.dart`, `image_pick_limits.dart`

The monolith also contains **cashier/manager/supervisor** UI in the same file; ignore `PosShellScreen`, `ManagerDashboardScreen`, etc. when porting customer/guest only.

### Assets

Copy `packages/frontend/assets/images/` from the main repo (logos, placeholders). Not duplicated in the zip to save size.

### Dependencies

See `frontend/pubspec.yaml` (`http`, `image_picker`, `pdf`, `flutter_map`, `intl`, etc.).

## Backend: customer/guest API surface

### Auth & profile

- `POST /api/mobile/auth/signup/request-otp`, `signup/complete`
- `POST /api/mobile/auth/login`
- `POST /api/mobile/auth/request-password-reset`, `check-password-reset-otp`, `reset-password`
- `GET` / `PUT /api/mobile/profile`
- `GET` / `PUT /api/mobile/customer/tray-draft`

### Restaurant orders (guest + customer)

- `GET /api/mobile/menu`, `/api/mobile/allergens`, `/api/mobile/set-menus`
- `GET` / `POST /api/mobile/orders`, `GET /api/mobile/orders/:id`
- `PATCH /api/mobile/orders/:id/payment` (payment proof / GCash reference)
- `PATCH /api/mobile/orders/:id/cancel-customer`

### Catering inquiries

- `GET /api/mobile/inquiries`
- `POST /api/mobile/inquiries` (includes `theme_design`, `seating_plan` JSON)
- `PATCH /api/mobile/inquiries/:id/cancel-customer`
- `POST /api/mobile/catering/schedule-conflicts`

### Guest track (no account)

- `POST /api/mobile/guest-orders/request-track-otp`
- `POST /api/mobile/guest-orders/list` (email + OTP)

### Theme design & seating (included in this package)

- `POST /api/public/events/theme-design/*` (theme-search, yolo-sam-infer, swap-colors, extract-objects, analyze-base, auto-place, render-composite, add-by-prompt)
- `GET` / `PUT /api/mobile/events/:id/theme-design`
- `GET` / `PUT /api/mobile/events/:id/seating-plan` (via `eventDesignSeating.ts`)

### Notifications & realtime

- `GET /api/mobile/notifications`
- Realtime sync stamps/deltas (same as mobile `AppState`)

### Out of scope for customer/guest web (present in `index.ts` only for production parity)

- All `/api/mobile/pos/*` (cashier, manager, supervisor)
- Staff auth via `staff_email` / `staff_password` on POS routes

## Running the handoff backend

```bash
cd backend
cp .env.example .env   # DATABASE_URL, mail, RunPod/Pexels keys for theme design, etc.
npm install
npm run build   # or: npx tsx src/index.ts
```

Use the same Postgres schema as production.

## Web integration notes

1. **API base** — mirror `AppState.apiBase` / `api_config.dart` / env pattern.
2. **Guest session** — no login; create local guest email server-side pattern or call your own guest bootstrap; mobile uses `enterGuestCheckoutSession()`.
3. **Guest track** — email + OTP only; no password.
4. **Payment proof** — multipart/base64 upload on order payment PATCH; GCash reference digits validation on client.
5. **Monolith** — optional split of customer widgets from `main.dart` into web routes; keep API contracts.

## Related handoffs

| Package | Scope |
|---------|--------|
| `handoff/web-staff-full-handoff.zip` | Cashier, manager, supervisor (excludes theme/seating backend) |
| `handoff/web-staff-delta-since-full-handoff.zip` | Staff changes after full staff handoff |
| **`handoff/web-customer-full-handoff.zip`** | **This package** — customer + guest |

## Source repo paths

| Handoff | Production |
|---------|------------|
| `frontend/lib/main.dart` | `packages/frontend/lib/main.dart` |
| `backend/src/index.ts` | `packages/backend/src/index.ts` |

Generated for web customer/guest port — May 2026.
