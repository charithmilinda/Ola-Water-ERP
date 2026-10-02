"use server";

import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const P = ["/sales", "/sales/my", "/sales/commissions"];
const n = (v: string) => (v === "" ? null : Number(v));

export async function saveTerritory(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_territory", { p_id: str(f, "id") || null, p: { code: str(f, "code"), name: str(f, "name"),
    districts: str(f, "districts").split(",").map((x) => x.trim()).filter(Boolean), notes: str(f, "notes"), is_active: f.get("is_active") !== "off" } },
    "Territory saved.", [...P, "/distributors"]);
}

export async function saveCommissionPlan(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_commission_plan", { p_id: str(f, "id") || null, p: {
    code: str(f, "code"), name: str(f, "name"), sales_rate_pct: n(str(f, "sales_rate_pct")), collection_rate_pct: n(str(f, "collection_rate_pct")),
    target_bonus_pct: n(str(f, "target_bonus_pct")), new_customer_bonus: n(str(f, "new_customer_bonus")), notes: str(f, "notes"), is_active: true,
  }, p_reason: str(f, "reason") || null }, "Plan saved.", P);
}

export async function saveRep(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id");
  return runRpc("save_sales_rep", { p_id: id || null, p: {
    profile_id: str(f, "profile_id") || null, employee_id: str(f, "employee_id") || null, code: str(f, "code"), territory_id: str(f, "territory_id") || null,
    commission_plan_id: str(f, "commission_plan_id") || null, phone: str(f, "phone"), is_active: id ? f.get("is_active") === "on" : true,
  } }, "Rep saved.", [...P, id ? `/sales/reps/${id}` : "/sales"]);
}

export async function setTargets(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const [y, m] = str(f, "month").split("-").map(Number);
  const ids = [...new Set([...f.keys()].filter((k) => k.startsWith("st:")).map((k) => k.slice(3)))];
  const rows = ids.map((id) => ({ rep_id: id, sales_target: n(str(f, `st:${id}`)) ?? 0, collection_target: n(str(f, `ct:${id}`)) ?? 0,
    new_customers: n(str(f, `nc:${id}`)) ?? 0, visits: n(str(f, `vs:${id}`)) ?? 0 }));
  return runRpc("set_sales_targets", { p_year: y, p_month: m, p_rows: rows }, "Targets saved.", P);
}

export async function assignCustomers(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const rep = str(f, "rep_id");
  const ids = f.getAll("customer_ids").map(String).filter(Boolean);
  if (!ids.length) return { ok: false, message: "Tick at least one customer." };
  return runRpc<number>("assign_customers_to_rep", { p_customers: ids, p_rep: rep || null, p_reason: str(f, "reason") || null },
    (k) => `${k} customer(s) assigned.`, [...P, `/sales/reps/${rep}`, "/customers"]);
}

export async function cashHandover(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const rep = str(f, "rep_id");
  return runRpc<{ handover_no: string; still_held: number }>("rep_cash_handover", { p_rep: rep, p_amount: Number(str(f, "amount")), p_money_account: str(f, "money_account_id"),
    p_reference: str(f, "reference") || null, p_notes: str(f, "notes") || null, p_client_txn_id: str(f, "client_txn_id") },
    (d) => `${d.handover_no} recorded.${Number(d.still_held) > 0 ? ` The rep still holds Rs. ${Number(d.still_held).toLocaleString("en-LK")}.` : ""}`,
    [...P, `/sales/reps/${rep}`, "/accounting/banking"]);
}

export async function checkIn(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const who = str(f, "who");
  const [kind, id] = who.split(":");
  return runRpc<{ warning: string | null; distance_m: number | null }>("rep_check_in", { p: {
    customer_id: kind === "c" ? id : null, lead_id: kind === "l" ? id : null, purpose: str(f, "purpose"),
    lat: n(str(f, "lat")), lng: n(str(f, "lng")), accuracy: n(str(f, "accuracy")), notes: str(f, "notes"),
  }, p_client_txn_id: str(f, "client_txn_id") }, (d) => d.warning ? `Checked in. ${d.warning}.` : "Checked in.", P);
}

export async function checkOut(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("rep_check_out", { p_visit: str(f, "visit_id"), p: { outcome: str(f, "outcome"), notes: str(f, "notes"),
    next_action_on: str(f, "next_action_on") || null } }, "Checked out.", P);
}

export async function collectPayment(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ payment_no: string; outstanding: number; cash_with_rep: number }>("rep_collect_payment", {
    p_customer: str(f, "customer_id"), p_method: str(f, "method"), p_amount: Number(str(f, "amount")), p_reference: str(f, "reference") || null,
    p_notes: str(f, "notes") || null, p_visit: str(f, "visit_id") || null, p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.payment_no} recorded. Customer now owes Rs. ${Number(d.outstanding).toLocaleString("en-LK", { minimumFractionDigits: 2 })}.`, [...P, "/customers"]);
}

export async function prepareCommissions(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const [y, m] = str(f, "month").split("-").map(Number);
  return runRpc<number>("prepare_commissions", { p_year: y, p_month: m }, (k) => `${k} statement(s) prepared.`, P);
}

export async function adjustCommission(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("adjust_commission", { p_statement: str(f, "statement_id"), p_amount: Number(str(f, "amount") || 0), p_note: str(f, "note") || null },
    "Adjustment saved.", P);
}

export async function approveCommission(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ status: string; via_payroll: boolean }>("approve_commission", { p_statement: str(f, "statement_id"), p_note: str(f, "reason") || null },
    (d) => d.status === "paid" ? "Approved (nothing to pay)." : d.via_payroll ? "Approved — it will be paid on the rep's next payslip." : "Approved — record the payment when paid.",
    [...P, "/payroll"]);
}

export async function payCommission(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("pay_commission", { p_statement: str(f, "statement_id"), p_money_account: str(f, "money_account_id"), p_reference: str(f, "reference") || null,
    p_client_txn_id: str(f, "client_txn_id") }, "Payment recorded.", P);
}
