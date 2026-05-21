# Curatering — staff web handoff (delta since `web-staff-full`)

**Incremental update** for the web team. Apply on top of the earlier full bundle:

| Prior package | This package |
|---------------|--------------|
| `handoff/web-staff-full-handoff.zip` | `handoff/web-staff-delta-since-full-handoff.zip` |

If you do not have the full handoff yet, start with **`web-staff-full`** first; this zip only contains files that changed afterward.

## What is in this zip

| Path | Purpose |
|------|---------|
| `CHANGELOG.md` | Staff-focused list of changes since the full handoff |
| `backend/src/db.ts` | Pipeline status CHECK helper (`for_ongoing`, `for_down_payment`, …) |
| `backend/src/index.ts` | Staff API variant (same exclusions as full handoff: no `eventDesignSeating` routes, no public RunPod/Pexels proxies) |
| `backend/sql/migrations/20260520_catering_pipeline_status_check.sql` | SQL migration for pipeline status constraints |
| `frontend/lib/main.dart` | Full monolith (staff + customer); replace or merge staff sections |
| `backend/EXCLUDED/eventDesignSeating.ts.reference` | Unchanged reference for theme/seating APIs (implement on web separately) |

## How to apply

1. **Backend** — Replace `db.ts` and `index.ts` in your staff backend tree (or merge `CHANGELOG` items). Run the new migration on Postgres, then restart the API so `initDb()` / `ensureCateringPipelineStatusChecks` runs.
2. **Frontend** — Replace `main.dart` if you track the mobile monolith 1:1, or port only the staff areas listed in `CHANGELOG.md` (search symbols there).
3. **Theme / seating** — Still **not** in `index.ts`; use `EXCLUDED/eventDesignSeating.ts.reference` for dedicated APIs.

## Staff areas touched (summary)

- **Manager:** `for_ongoing` pipeline tab; stage PATCH with legacy DB fallback; `processing_phase: ongoing`
- **Cashier:** Payment proof only via suffix icon on **Amount received** in full order detail (removed from list tiles)
- **Supervisor:** Same catering detail paths as manager where shared

## Regenerating this zip

From repo root:

```powershell
powershell -ExecutionPolicy Bypass -File handoff/build-web-staff-delta.ps1
```

Generated May 2026.
