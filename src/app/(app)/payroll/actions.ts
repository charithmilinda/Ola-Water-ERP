"use server";

import { redirect } from "next/navigation";
import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";
import { parseLines, num } from "@/lib/lines";

const P = (id?: string) => ["/payroll", "/payroll/statutory", "/hr", "/accounting", ...(id ? [`/payroll/${id}`] : [])];

export async function createRun(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const [y, m] = str(f, "month").split("-").map(Number);
  const res = await runRpc<{ run_id: string; run_no: string; employees: number }>("create_payroll_run", {
    p_year: y, p_month: m, p_notes: str(f, "notes"), p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.run_no} prepared for ${d.employees} employee(s).`, P());
  if (!res.ok) return res;
  redirect(`/payroll/${res.data?.run_id}`);
}

export async function recalcRun(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "run_id");
  return runRpc("recalculate_payroll_run", { p_run: id }, "Recalculated from the latest attendance, leave and pay details.", P(id));
}

export async function approveRun(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "run_id");
  return runRpc<{ entry_no: string }>("approve_payroll_run", { p_run: id, p_note: str(f, "reason") }, (d) => `Approved and posted (${d.entry_no}).`, P(id));
}

export async function cancelRun(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "run_id");
  return runRpc("cancel_payroll_run", { p_run: id, p_reason: str(f, "reason") }, "Payroll cancelled.", P(id));
}

export async function payRun(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "run_id");
  return runRpc<{ paid: number }>("pay_payroll_run", { p_run: id, p_money_account: str(f, "money_account_id"), p_reference: str(f, "reference"),
    p_client_txn_id: str(f, "client_txn_id") }, (d) => `Salaries of Rs. ${Number(d.paid).toFixed(2)} recorded as paid.`, P(id));
}

export async function adjustPayslip(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "run_id");
  const lines = parseLines(f.get("lines")).map((l) => ({ component_id: l.item_id, amount: num(l.amount), name: l.name || null }));
  return runRpc<{ net: number }>("set_payslip_adjustments", { p_payslip: str(f, "payslip_id"), p_lines: lines, p_reason: str(f, "reason") || null },
    (d) => `Saved — net pay now Rs. ${Number(d.net).toFixed(2)}.`, P(id));
}

export async function setRate(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("set_statutory_rate", { p_code: str(f, "code"), p_rate: Number(str(f, "rate")), p_effective_from: str(f, "effective_from"),
    p_reason: str(f, "reason") }, "Rate saved.", P());
}

export async function setApit(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const bands = [...Array(8).keys()].map((i) => ({ band_width: num(str(f, `w${i}`)), rate_percent: num(str(f, `r${i}`)) }))
    .filter((b) => b.rate_percent !== null);
  return runRpc<number>("set_apit_bands", { p_effective_from: str(f, "effective_from"), p_bands: bands, p_reason: str(f, "reason") },
    (n) => `New APIT table with ${n} bands saved.`, P());
}

export async function payStatutory(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ payment_no: string }>("pay_statutory", {
    p: { kind: str(f, "kind"), pay_year: Number(str(f, "year")), pay_month: Number(str(f, "month")), amount: num(str(f, "amount")),
      money_account_id: str(f, "money_account_id"), reference: str(f, "reference") },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.payment_no} recorded.`, P());
}

export async function savePayComponent(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_pay_component", { p_id: null, p: { code: str(f, "code"), name: str(f, "name"), kind: str(f, "kind"),
    epf_liable: f.get("epf_liable") === "on", taxable: f.get("taxable") === "on" }, p_reason: "New pay component" }, "Added.", P());
}
