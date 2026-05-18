/**
 * Catering / event order pipeline stages (canonical DB + API names).
 *
 * Replaces legacy `for_processing` + `processing_phase` and `for_post_analysis`.
 */
export const CATERING_PIPELINE_STATUSES = [
  "new_event",
  "online_inquiries",
  "for_down_payment",
  "for_ongoing",
  "for_full_payment",
  "completed",
  "cancelled",
] as const;

export type CateringPipelineStatus = (typeof CATERING_PIPELINE_STATUSES)[number];

/** Legacy status values still present in older rows until migration runs. */
export const LEGACY_CATERING_STATUSES = ["for_processing", "for_post_analysis"] as const;

export function processingSubstageFromRow(row: Record<string, unknown>): "down_payment" | "ongoing" {
  const raw = String(row.processing_phase_sk ?? "").trim().toLowerCase();
  if (raw === "ongoing") return "ongoing";
  if (raw === "down_payment") return "down_payment";
  const n = Number(row.checklist_count_summary ?? 0);
  if (Number.isFinite(n) && n > 0) return "ongoing";
  return "down_payment";
}

/** Map DB / legacy status to canonical API stage name. */
export function normalizeCateringStatusForApi(
  status: string,
  row?: Record<string, unknown>,
): string {
  const s = status.trim().toLowerCase();
  if (s === "for_post_analysis" || s === "for_full_payment") return "for_full_payment";
  if (s === "for_ongoing") return "for_ongoing";
  if (s === "for_down_payment") return "for_down_payment";
  if (s === "for_processing") {
    if (row && processingSubstageFromRow(row) === "ongoing") return "for_ongoing";
    return "for_down_payment";
  }
  return s;
}

/** DB status values to match when loading a manager tab (includes legacy rows until migrated). */
export function cateringStatusesForApiStage(apiStage: string): string[] {
  const s = mapManagerCateringStageToDb(apiStage);
  switch (s) {
    case "for_down_payment":
      return ["for_down_payment", "for_processing"];
    case "for_ongoing":
      return ["for_ongoing", "for_processing"];
    case "for_full_payment":
      return ["for_full_payment", "for_post_analysis"];
    default:
      return [s];
  }
}

/** Write canonical status to DB (accept legacy API aliases). */
export function mapManagerCateringStageToDb(apiStage: string): string {
  const s = apiStage.trim().toLowerCase();
  if (s === "for_post_analysis") return "for_full_payment";
  if (s === "for_processing") return "for_down_payment";
  if (s === "ongoing") return "for_ongoing";
  return s;
}

/** SQL fragment: active pipeline stages that may overlap schedules. */
export const CATERING_ACTIVE_SCHEDULE_STATUSES_SQL = `'for_down_payment', 'for_ongoing'`;

/** SQL fragment: stages where loyalty / final billing apply. */
export const CATERING_BILLING_LATE_STATUSES_SQL = `'for_full_payment', 'completed'`;
