"use server";

import { runRpc, payload } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const P = ["/recurring", "/orders"];

export async function saveRecurring(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<Record<string, unknown>>(f);
  return runRpc("save_recurring_order", { p_id: null, p: d, p_reason: "New recurring order" }, "Recurring order created.", P);
}

export async function setRecurringStatus(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("set_recurring_status", { p_id: str(f, "id"), p_status: str(f, "status"), p_reason: str(f, "reason") },
    "Recurring order updated.", P);
}

export async function skipNext(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<string>("skip_next_recurring", { p_id: str(f, "id"), p_reason: str(f, "reason") },
    (d) => `Skipped. Next delivery ${d.split("-").reverse().join("/")}.`, P);
}

export async function generateOrders(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ created: number; on_hold: number; errors: { customer: string; error: string }[] }>(
    "generate_recurring_orders", { p_until: str(f, "until") },
    (d) => `${d.created} order(s) created${d.on_hold ? `, ${d.on_hold} on hold` : ""}${d.errors.length ? `. Problems: ${d.errors.map((e) => `${e.customer}: ${e.error}`).join("; ")}` : "."}`,
    P);
}
