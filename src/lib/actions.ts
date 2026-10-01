// Shared result type and helpers for server actions.

export type ActionResult<T = unknown> =
  | { ok: true; message: string; data?: T }
  | { ok: false; message: string; fieldErrors?: Record<string, string> };

export const initialActionState: ActionResult = { ok: true, message: "" };

/** Turn a Supabase/PostgREST error into a message an employee can act on. */
export function friendlyError(error: { message?: string; code?: string } | null | undefined): string {
  if (!error) return "Something went wrong. Please try again.";
  const msg = error.message ?? "";
  if (error.code === "42501" || /permission denied/i.test(msg)) {
    return msg.startsWith("Permission denied") ? msg : "You do not have permission to do this.";
  }
  if (error.code === "23505" && !/already/i.test(msg)) return "This record already exists.";
  if (/fetch failed|network/i.test(msg)) return "Cannot reach the server. Check your connection and try again.";
  return msg || "Something went wrong. Please try again.";
}

export function str(form: FormData, key: string): string {
  const v = form.get(key);
  return typeof v === "string" ? v.trim() : "";
}

export function isUuid(v: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
}
