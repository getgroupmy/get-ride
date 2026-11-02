/**
 * News and offers (migration 0333): a broadcast from Admin › Push
 * Notification, sent now or on a schedule, reaches only the accounts that
 * opted in (the permissions notice or Settings › Notifications; off until
 * they do). A phone signed out is not reached. Every other push (a ride request to nearby drivers,
 * trips, offers, calls, chat, money, safety, documents, account, and an
 * admin's push to one person) is sent as before.
 *
 *     deno test supabase/functions/_shared/news_offers_test.ts
 */

/** Who asked send-push (send_push_handler.ts SendCaller). */
export type NewsCaller = "webhook" | "service" | "admin";

/**
 * Whether a send is a News and offers broadcast: no single profile, and
 * either an admin's own send from the panel (the composer, its preview, a
 * saved push sent again) or a scheduled one (push_schedules, 0279), or a
 * caller that says so. A send with a notification type (`data.type`, as
 * every trip, money, safety and account push has) never is.
 */
export function isNewsBroadcast(
  payload: { profileId?: string; scheduleId?: string; news?: boolean; data?: Record<string, unknown> },
  caller: NewsCaller,
): boolean {
  if ((payload.profileId ?? "").trim() !== "") return false;
  const type = payload.data?.type;
  if (typeof type === "string" && type.trim() !== "") return false;
  return caller === "admin" || (payload.scheduleId ?? "") !== "" || payload.news === true;
}

/** The device rows a News and offers broadcast reaches: opted-in accounts only. */
export function newsRecipients<T extends { profile_id?: string | null }>(rows: T[], optedIn: Set<string>): T[] {
  return rows.filter((r) => !!r.profile_id && optedIn.has(r.profile_id));
}

/** The accounts among [rows] left out for not opting in. */
export function newsLeftOut(rows: { profile_id?: string | null }[], optedIn: Set<string>): number {
  const out = new Set<string>();
  for (const r of rows) if (r.profile_id && !optedIn.has(r.profile_id)) out.add(r.profile_id);
  return out.size;
}
