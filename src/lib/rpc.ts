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
