"use server";

import { revalidatePath } from "next/cache";
import { runRpc } from "@/lib/rpc";
import { createClient } from "@/lib/supabase/server";
import { str, type ActionResult } from "@/lib/actions";
import { dispatchMessages } from "@/lib/messaging/dispatch";

const P = ["/messages"];

export async function sendNow(): Promise<ActionResult> {
  const supabase = await createClient();
  await supabase.rpc("refresh_notifications", { p_force: true });
  const r = await dispatchMessages(supabase, 50);
  revalidatePath("/messages");
  if ("error" in r && r.error) return { ok: false, message: r.error };
  return { ok: true, message: r.sent + r.failed === 0 ? "Nothing waiting to be sent. Alerts checked." : `${r.sent} sent, ${r.failed} not sent (see the reasons below).` };
}

export async function retryMessage(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("retry_message", { p_id: str(f, "message_id") }, "Queued again.", P);
}

export async function cancelMessage(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("cancel_message", { p_id: str(f, "message_id") }, "Cancelled.", P);
}

export async function saveTemplate(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_message_template", {
    p_code: str(f, "code"),
    p: { channel: str(f, "channel"), subject: str(f, "subject"), body: str(f, "body"), whatsapp_template: str(f, "whatsapp_template"), is_active: f.get("is_active") === "on" },
    p_reason: str(f, "reason") || null,
  }, "Template saved.", P);
}

export async function saveNotificationType(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_notification_type", {
    p_code: str(f, "code"),
    p: { permission: str(f, "permission") || null, in_app: f.get("in_app") === "on", email: f.get("email") === "on", is_active: f.get("is_active") === "on" },
  }, "Saved.", P);
}

export async function messagingSwitch(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const on = str(f, "on") === "true";
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Colombo" }).format(new Date());
  return runRpc("set_setting", { p_key: "messaging.enabled", p_value: on, p_effective_from: today, p_reason: str(f, "reason") || (on ? "Customer messages switched on" : "Customer messages switched off") },
    on ? "Customer messages are on." : "Customer messages are off.", [...P, "/admin/settings"]);
}
