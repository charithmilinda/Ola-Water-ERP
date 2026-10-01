"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyError, str, type ActionResult } from "@/lib/actions";
import { todayISO } from "@/lib/format";

export async function changeSetting(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const key = str(form, "key");
  const raw = str(form, "value");
  const effective = str(form, "effective_from") || todayISO();
  const reason = str(form, "reason");
  if (!reason) return { ok: false, message: "A reason is required." };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(effective)) return { ok: false, message: "Choose a valid date." };

  const supabase = await createClient();
  const { data: def } = await supabase.from("setting_definitions").select("value_type").eq("key", key).maybeSingle();
  if (!def) return { ok: false, message: "Unknown setting." };

  let value: unknown;
  switch (def.value_type) {
    case "boolean":
      value = raw === "true";
      break;
    case "text":
    case "choice":
      value = raw;
      break;
    default: {
      const n = Number(raw.replace(/,/g, ""));
      if (raw === "" || Number.isNaN(n)) return { ok: false, message: "Enter a number." };
      value = n;
    }
  }

  const { error } = await supabase.rpc("set_setting", {
    p_key: key,
    p_value: value,
    p_effective_from: effective,
    p_reason: reason,
  });
  if (error) return { ok: false, message: friendlyError(error) };
  revalidatePath("/admin/settings");
  return {
    ok: true,
    message: effective === todayISO() ? "Setting changed. It applies from today." : `Change scheduled for ${effective.split("-").reverse().join("/")}.`,
  };
}
