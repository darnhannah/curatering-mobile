# Curatering — full staff handoff (cashier, manager, supervisor)

Snapshot for porting **staff-side** behavior to web. Includes **all staff Flutter UI** (including event theme design and seating layout screens) plus **backend** for POS, catering pipeline, menu, notifications, and shared mobile APIs — **excluding** theme-design and seating-plan **backend** modules.

## Package layout

| Path | Contents |
|------|----------|
| `frontend/` | Full `lib/` from mobile app: `main.dart` (~26k lines, staff + customer in one tree), `main_staff.dart` entry, feature modules, utils, `pubspec.yaml` |
| `backend/` | Express API (`index.ts` staff variant), `db.ts`, compat layers, mail/SMS, SQL migrations |
| `backend/EXCLUDED/` | Reference-only `eventDesignSeating.ts` from production (do not run as-is in this package) |

## Staff roles (Flutter routing)

After staff login (`AuthScreen` with `cashierMode` / `forcePosLogin` via `main_staff.dart`):

| Role | Shell widget | Primary work |
|------|----------------|--------------|
| **Cashier** | `PosShellScreen` | Online orders, walk-in queue, payment proof, order history |
| **Manager** | `ManagerDashboardScreen` | Catering pipeline, new events, inquiries, theme/seating UI entry points |
| **Supervisor** | `SupervisorOngoingShellScreen` | Ongoing catering (`ManagerCateringDetailScreen` with `supervisorMode: true`) |

Routing lives in `frontend/lib/main.dart` (post-login `home` builder, ~lines 399–417).

## Frontend: what to read first

1. **`main_staff.dart`** — staff app entry: `runCurateringApp(forcePosLogin: true)`.
2. **`main.dart`** — search for: `PosShellScreen`, `ManagerDashboardScreen`, `SupervisorOngoingShellScreen`, `AppState`, `/api/mobile/pos`.
3. **Theme / seating UI** (included; calls APIs you must implement on web or keep on mobile backend):
   - `lib/features/event_design/`
   - `lib/features/seating/`
   - `lib/widgets/manager_theme_seating_blocks.dart`
4. **Shared utils**: `allergen_ui.dart`, `order_type_utils.dart`, `theme_design_venue_refs.dart`, `image_pick_limits.dart`.

The monolith also contains **customer/guest** screens in the same file; web staff port can ignore everything outside staff shells or split later.

### Assets

Copy `packages/frontend/assets/images/` from the main repo (logos, placeholders). Not duplicated in this zip to save size.

### Dependencies

See `frontend/pubspec.yaml` (`http`, `image_picker`, `pdf`, `printing`, `flutter_map`, `intl`, etc.).

## Backend: included vs excluded

### Included (`backend/src/index.ts` — staff variant)

- All `/api/mobile/pos/*` cashier and manager/supervisor catering routes
- Staff auth via `verifyPosStaff` on each POS route (email + password body fields)
- Catering create/patch with **`normalizeSeatingPlan`** on `seating_plan` JSON (via `seatingPlanNormalize.ts`)
- Menu, allergens, inquiries, orders, guest track, notifications, realtime sync, mail/SMS helpers
- `db.ts`, `eventOrdersCompat.ts`, `restaurantOrdersCompat.ts`, `webMenu.ts`, migrations

### Excluded (implement separately on web)

| Item | Reason |
|------|--------|
| `eventDesignSeating.ts` | Theme CRUD + seating GET/PUT APIs |
| `registerEventDesignSeatingRoutes(...)` | Removed from handoff `index.ts` |
| Public RunPod/Pexels proxies | `POST /api/public/events/theme-design/*` (8 routes, formerly index.ts ~3420–3911) |

Reference implementation: `backend/EXCLUDED/eventDesignSeating.ts`.

### Seating data without excluded module

Handoff keeps **`seatingPlanNormalize.ts`** so catering `POST`/`PATCH` still validate `seating_plan` blobs. Manager UI can **save** seating into the order JSON via existing catering draft/patch routes; **dedicated** `GET/PUT /api/mobile/events/:id/seating-plan` are **not** in this package.

### Staff POS API checklist

**Cashier** (`verifyPosStaff` role `cashier`):

- `POST /api/mobile/pos/online-orders/list`
- `POST /api/mobile/pos/online-orders/:id/detail`
- `PATCH /api/mobile/pos/online-orders/:id/review`
- `POST /api/mobile/pos/online-orders/:id/remind-balance`
- `PATCH /api/mobile/pos/online-orders/:id/fulfillment`
- `POST /api/mobile/pos/walkin-order`
- `POST /api/mobile/pos/order-history`
- `POST /api/mobile/pos/walkin-queue`
- `PATCH /api/mobile/pos/walkin-orders/:id/cancel`
- `PATCH /api/mobile/pos/walkin-orders/:id/claim`

**Manager / supervisor** (`manager` or `supervisor`):

- `POST /api/mobile/pos/catering/list`
- `POST /api/mobile/pos/catering/item`
- `POST /api/mobile/pos/catering/new-event`
- `PATCH /api/mobile/pos/catering/:id/stage`
- `PATCH /api/mobile/pos/catering/:id/post-analysis-patch`
- `PATCH /api/mobile/pos/catering/:id/draft`
- `POST /api/mobile/pos/catering/:id/switch-order-kind`
- `POST /api/mobile/pos/catering/send-order-summary-email`
- `GET /api/mobile/pos/catering/:id/invoice-preview`

**Excluded theme/seating APIs** (in reference file only):

- `GET/PUT /api/mobile/events/:id/theme-design`
- `GET/PUT /api/mobile/events/:id/seating-plan`
- `POST /api/public/events/theme-design/*` (theme-search, yolo-sam-infer, swap-colors, extract-objects, analyze-base, auto-place, render-composite, add-by-prompt)

### Shared APIs staff UI may call

- `GET /api/mobile/menu`, `/api/mobile/allergens`, `/api/mobile/set-menus`
- `POST /api/mobile/catering/schedule-conflicts`
- `GET /api/mobile/inquiries`, `POST /api/mobile/inquiries`
- `GET /api/mobile/notifications`, realtime sync stamps/deltas
- `POST /api/mobile/auth/login` (staff accounts in `pos_staff` table)

## Running the handoff backend

```bash
cd backend
cp .env.example .env   # set DATABASE_URL, mail keys, etc.
npm install
npm run build   # or tsx src/index.ts per package.json scripts
```

Use the same Postgres schema as production mobile backend.

## Web integration notes

1. **API base URL** — mirror `AppState.apiBase` / `events_feature_api.dart` / `api_config.dart` env pattern.
2. **Auth** — staff routes expect `staff_email` + `staff_password` (or `cashier_email` + `cashier_password`) in JSON body, not Bearer tokens.
3. **Theme/seating** — port UI from `features/event_design` and `features/seating`; wire to your own theme/seating backend using `EXCLUDED/eventDesignSeating.ts` as spec.
4. **Monolith split** — optional: extract staff widgets from `main.dart` into web components; behavior is unchanged if you keep the same API contracts.

## Related handoff

Smaller **theme + seating frontend-only** bundle (no backend): `handoff/web-staff-theme-seating-frontend.zip` and `handoff/web-staff-theme-seating-frontend/`. This full package **supersedes** that frontend subset but does **not** include theme/seating backend.

## Source repo paths

| Handoff | Production |
|---------|------------|
| `frontend/lib/main.dart` | `packages/frontend/lib/main.dart` |
| `backend/src/index.ts` | `packages/backend/src/index.ts` (minus exclusions above) |

Generated for web staff port — May 2026.
