"use server";

import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const P = ["/approvals", "/"];

export async function decideApproval(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = str(f, "decision") === "approve";
  return runRpc<{ status: string; request_no: string; levels_done?: number }>("decide_approval", {
    p_id: str(f, "request_id"), p_approve: approve, p_note: str(f, "reason") || null,
  }, (d) => d.status === "approved" ? `${d.request_no} approved and carried out.`
    : d.status === "pending" ? `${d.request_no}: your approval is recorded — it now needs the next approver.`
    : `${d.request_no} rejected.`, [...P, "/inventory", "/customers", "/orders", "/products", "/bottles", "/exceptions"]);
}

export async function cancelApproval(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("cancel_approval", { p_id: str(f, "request_id"), p_reason: str(f, "reason") || null }, "Request withdrawn.", P);
}

export async function saveApprovalRule(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_approval_rule", {
    p_kind: str(f, "kind"),
    p: { approver_permission: str(f, "approver_permission"), levels: Number(str(f, "levels") || 1), is_active: f.get("is_active") === "on" },
    p_reason: str(f, "reason"),
  }, "Rule saved.", ["/approvals"]);
}

export async function saveThreshold(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const value = str(f, "value");
  if (value === "" || Number.isNaN(Number(value))) return { ok: false, message: "Enter a number." };
  return runRpc("set_setting", {
    p_key: str(f, "key"), p_value: Number(value), p_effective_from: str(f, "effective_from"), p_reason: str(f, "reason"),
  }, "Limit saved.", ["/approvals", "/admin/settings"]);
}
