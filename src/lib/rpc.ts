import "server-only";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyError, type ActionResult } from "@/lib/actions";

/** Call a database function and turn the outcome into an ActionResult. */
export async function runRpc<T = unknown>(
  fn: string,
  args: Record<string, unknown>,
  success: string | ((data: T) => string),
  revalidate: string[] = [],
): Promise<ActionResult<T>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(fn, args);
  if (error) return { ok: false, message: friendlyError(error) };
  revalidate.forEach((p) => revalidatePath(p));
  return { ok: true, message: typeof success === "function" ? success(data as T) : success, data: data as T };
}

/** Parse the JSON "payload" field that client-side editors submit. */
export function payload<T = Record<string, unknown>>(form: FormData): T {
  const raw = form.get("payload");
  if (typeof raw !== "string" || !raw) return {} as T;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return {} as T;
  }
}

export type ApprovalOutcome = { approval: { request_id: string; request_no: string } };

/**
 * Like runRpc, but when the database answers "needs approval" (SQLSTATE OL001)
 * the same action is sent to the approvers instead of failing. The result then
 * carries `approval` instead of the function's own data.
 */
export async function runRpcOrApproval<T = unknown>(
  fn: string,
  args: Record<string, unknown>,
  success: string | ((data: T) => string),
  revalidate: string[] = [],
  requestReason?: string | null,
): Promise<ActionResult<T | ApprovalOutcome>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(fn, args);
  if (error && error.code === "OL001" && error.hint) {
    const req = await supabase.rpc("submit_approval", { p_kind: error.hint, p_fn: fn, p_args: args, p_reason: requestReason ?? null });
    if (req.error) return { ok: false, message: friendlyError(req.error) };
    const r = req.data as { request_id: string; request_no: string };
    revalidatePath("/approvals");
    return {
      ok: true,
      message: `${error.message}. Sent for approval as ${r.request_no} — you will be notified when it is decided.`,
      data: { approval: r },
    };
  }
  if (error) return { ok: false, message: friendlyError(error) };
  revalidate.forEach((p) => revalidatePath(p));
  return { ok: true, message: typeof success === "function" ? success(data as T) : success, data: data as T };
}

export function isApproval(d: unknown): d is ApprovalOutcome {
  return !!d && typeof d === "object" && "approval" in d;
}
