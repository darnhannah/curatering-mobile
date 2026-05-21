# Customer & guest handoff — snapshot notes (May 2026)

Initial **full** customer/guest web bundle (no prior customer handoff zip in this repo).

## Guest

- **`CustomerPreAuthShell`** — boots guest menu on cold start (no tile landing).
- **`GuestCustomerShell`** — bottom nav: Order Now (menu), Inquire, Track My Order, Log in/Sign up.
- **Nested menu navigator** — checkout/payment/your-order keep bottom nav; `guestPopToMenu()` returns to menu tab.
- **Menu** — meal-type filters with cached dish thumbnails (no blink on tab change); no guest service-area banner above chips.
- **Payment / Your Order** — post–payment-proof notice: email + in-app track copy (`kGuestPostPaymentProofNotice`).
- **Track My Order** — OTP email lookup; full order/inquiry dialogs with payment proof images.

## Registered customer

- **`CustomerDashboardScreen`** — off-white body, centered 2×2 secondary tiles + Order Now / Inquire row.
- **Logout** — clears session and `pushAndRemoveUntil` `CustomerPreAuthShell` (guest menu), not stuck loading overlay.
- **My Orders / My Inquiries** — pending, confirmed, completed, cancelled tabs; loyalty hints; customer cancel where allowed.
- **Checkout** — map pin, delivery radius, schedule, tray, payment proof upload.

## Backend (this zip = production `packages/backend`)

- Full `index.ts` including **public theme-design proxies** and **`registerEventDesignSeatingRoutes`**.
- Guest track OTP + list, inquiry `theme_design` / `seating_plan`, restaurant orders, auth OTP signup.
- Migrations through `20260520_catering_pipeline_status_check.sql` (shared DB; POS pipeline statuses included).

## Files bundled

- `frontend/lib/main.dart`, `main_customer.dart`, `customer_local_notifications.dart`
- `frontend/lib/features/event_design/*`, `features/seating/*`, `utils/*`
- `backend/src/*.ts`, `backend/sql/migrations/*`, `package.json`, `.env.example`

Regenerate: `powershell -ExecutionPolicy Bypass -File handoff/build-web-customer-full.ps1`
