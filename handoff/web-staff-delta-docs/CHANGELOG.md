# Staff changes since `web-staff-full` (May 2026)

Delta handoff for **cashier**, **manager**, and **supervisor** behavior. Customer/guest edits are in the same `main.dart` file but are listed only when they affect shared APIs or staff-visible data.

---

## Backend

### Manager catering pipeline — `for_ongoing` status

**Problem:** Moving an order to **On going** (`for_ongoing`) could fail with Postgres `23514` (`event_orders_status_check` / `catering_orders_status_check`) on older databases, so the UI reverted after refresh.

**Changes:**

- **`db.ts`**
  - New exported `ensureCateringPipelineStatusChecks(pool)` — (re)applies CHECK constraints including `for_ongoing`, `for_down_payment`, `for_full_payment`, plus legacy `for_processing` / `for_post_analysis`.
  - Called from `initDb()` and `ensureNewEventSchemaOnce()` in `index.ts`.

- **`sql/migrations/20260520_catering_pipeline_status_check.sql`**
  - Standalone migration for the same CHECK lists (run on production DBs that skip full `initDb`).

- **`index.ts` (staff variant)**
  - Imports `ensureCateringPipelineStatusChecks` from `db.js` (removed duplicate inline helper from older handoff `index.ts`).
  - Stage PATCH `PATCH /api/mobile/pos/catering/:id/stage`:
    - Sets `post_analysis.processing_phase = "ongoing"` when `nextStatus === "for_ongoing"`.
    - On CHECK violation (`23514`), **legacy fallback** via `cateringStatusLegacyWriteFallback`: writes `for_processing` + `processing_phase` (`ongoing` / `down_payment`) or `for_post_analysis` for `for_full_payment`.
  - List/filter helpers include `for_ongoing` in allowed pipeline statuses.

**Web action:** Deploy updated `db.ts` + `index.ts`, run migration, restart backend.

### Unchanged exclusions (same as full handoff)

- No `registerEventDesignSeatingRoutes` in this `index.ts`.
- No `POST /api/public/events/theme-design/*` proxies.
- Theme/seating CRUD: see `backend/EXCLUDED/eventDesignSeating.ts.reference`.

---

## Frontend (`main.dart` — staff-relevant)

### Manager

- **`kStageForOngoing` / `for_ongoing`** — Pipeline tab and stage dropdown; aligns with backend status and `processing_phase`.
- **Processing substage filters** — Ongoing vs down payment vs full payment UI under `for_processing` / dedicated stages.
- **Manager catering detail** — Theme design + seating blocks (UI only; APIs still excluded from staff backend bundle).
- **Hours / schedule validation** — Catering schedule conflict checks (8am–7pm window) on manager/customer flows sharing the same validators.

### Cashier (`PosShellScreen` / online orders)

- **`cashierPaymentProofSuffixIcon`** — Image icon on **Amount received** `TextField` in `PosOnlineOrderDetailScreen` (initial + balance payment).
- **Removed from order list tiles** — `cashierPaymentProofListIcon` / `VIEW PROOF OF PAYMENT` buttons on online and walk-in **list** rows; proof is only in full order detail.
- **`cashierPaymentProofAndReferenceSection`** — Still defined for reference cards but no longer used on list tiles.

### Supervisor

- **`SupervisorOngoingShellScreen`** — Ongoing catering list; uses same `ManagerCateringDetailScreen` with `supervisorMode: true` (checklist-only restrictions unchanged).

### Shared staff utilities (unchanged paths, verify when merging)

- `cashierCustomerLabel`, `orderPaymentProofDetailWidgets`, `showRestaurantOrderConfirmationDialog` — used for detail dialogs and guest track (proof images in full order view).

---

## Files in this delta zip

| File | vs `web-staff-full` |
|------|---------------------|
| `backend/src/db.ts` | Updated (`ensureCateringPipelineStatusChecks`) |
| `backend/src/index.ts` | Updated (pipeline stage + legacy fallback; staff-stripped from production) |
| `frontend/lib/main.dart` | Updated (manager ongoing + cashier proof UI) |
| `backend/sql/migrations/20260520_catering_pipeline_status_check.sql` | **New** |

Other files in `web-staff-full` (feature modules, `seatingPlanNormalize.ts`, compat layers, etc.) are **unchanged** in this delta — keep using the full handoff copy for those.

---

## Quick test checklist (staff)

1. Manager: move catering order to **On going** → refresh → status stays `for_ongoing` (or legacy `for_processing` + `processing_phase: ongoing` on old DB).
2. Cashier: online order list → **no** proof button on tile → open detail → proof icon on amount field.
3. Restart backend after migration → no `23514` on stage change.

---

## Source repo

| Delta path | Production |
|------------|------------|
| `backend/src/index.ts` | `packages/backend/src/index.ts` (minus exclusions above) |
| `backend/src/db.ts` | `packages/backend/src/db.ts` |
| `frontend/lib/main.dart` | `packages/frontend/lib/main.dart` |
