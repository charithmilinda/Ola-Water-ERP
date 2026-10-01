"use server";

import { redirect } from "next/navigation";
import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const A = ["/accounting", "/accounting/banking", "/accounting/journals", "/accounting/accounts"];

export async function closePeriod(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("close_accounting_period", { p_period_id: str(f, "period_id"), p_reason: str(f, "reason") },
    "Period closed. Nothing more can be posted into it.", A);
}

export async function openYear(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<number>("open_accounting_year", { p_year: Number(str(f, "year")) }, (n) => (Number(n) ? `${n} monthly period(s) opened.` : "That year is already open."), A);
}

export async function saveAccount(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_account", {
    p_id: id,
    p: { code: str(f, "code"), name: str(f, "name"), account_type: str(f, "account_type"), parent_id: str(f, "parent_id") || null,
      is_postable: f.get("is_postable") === "on", is_active: id ? f.get("is_active") === "on" : true, description: str(f, "description") },
    p_reason: str(f, "reason") || (id ? null : "New account"),
  }, id ? "Account saved." : "Account added.", A);
}

export async function saveMoneyAccount(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_money_account", {
    p_id: id,
    p: { name: str(f, "name"), kind: str(f, "kind"), bank_name: str(f, "bank_name"), branch: str(f, "branch"), account_no: str(f, "account_no"),
      is_active: id ? f.get("is_active") === "on" : true },
    p_reason: str(f, "reason") || (id ? null : "New cash / bank account"),
  }, id ? "Saved." : "Account added with its own ledger account.", A);
}

type JLine = { account_id: string; debit: string; credit: string; memo: string };
export async function submitJournal(_p: ActionResult, f: FormData): Promise<ActionResult> {
  let lines: JLine[] = [];
  try { lines = JSON.parse(str(f, "lines") || "[]"); } catch { lines = []; }
  const clean = lines.filter((l) => l.account_id && (Number(l.debit) > 0 || Number(l.credit) > 0))
    .map((l) => ({ account_id: l.account_id, debit: Number(l.debit || 0), credit: Number(l.credit || 0), memo: l.memo || null }));
  return runRpc<{ draft_no: string }>("submit_manual_journal", {
    p_entry_date: str(f, "entry_date"), p_description: str(f, "description"), p_lines: clean, p_reason: str(f, "reason"),
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Journal ${d.draft_no} sent for approval.`, A);
}

export async function decideJournal(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = str(f, "decision");
  return runRpc<{ status: string; entry_no?: string }>("decide_manual_journal", { p_id: str(f, "draft_id"), p_decision: d, p_note: str(f, "reason") },
    (r) => (r.status === "posted" ? `Approved and posted as ${r.entry_no}.` : r.status === "rejected" ? "Journal rejected." : "Journal withdrawn."), A);
}

export async function reverseEntry(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<{ entry_id: string; entry_no: string }>("reverse_journal_entry", {
    p_entry_id: str(f, "entry_id"), p_reason: str(f, "reason"), p_reversal_date: str(f, "reversal_date") || null, p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Reversed by ${d.entry_no}.`, A);
  if (!res.ok) return res;
  redirect(`/accounting/journals/${res.data?.entry_id}`);
}

export async function fundTransfer(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ transfer_no: string }>("record_fund_transfer", {
    p: { kind: str(f, "kind"), from_account_id: str(f, "from_account_id") || null,
      to_account_id: str(f, "to_account_id") || (str(f, "kind") === "bank_interest" ? str(f, "from_account_id") : null) || null,
      amount: Number(str(f, "amount") || 0), fee: Number(str(f, "fee") || 0), date: str(f, "date") || null, reference: str(f, "reference"), notes: str(f, "notes") },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.transfer_no} recorded.`, A);
}

export async function depositCheques(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const ids = f.getAll("cheque").map(String).filter(Boolean);
  if (ids.length === 0) return { ok: false, message: "Tick the cheques on the deposit slip." };
  return runRpc<{ cheques: number; total: number }>("deposit_cheques", {
    p_payments: ids, p_money_account: str(f, "money_account_id"), p_reference: str(f, "reference"), p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.cheques} cheque(s) deposited (Rs. ${Number(d.total).toFixed(2)}).`, A);
}

export async function clearCheque(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("clear_cheque", { p_payment: str(f, "payment_id") }, "Marked cleared.", A);
}

export async function returnCheque(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ payment_no: string }>("return_cheque", { p_payment: str(f, "payment_id"), p_reason: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id") },
    (d) => `Cheque ${d.payment_no} returned — the customer owes it again.`, [...A, "/payments"]);
}

export async function completeReconciliation(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "money_account_id");
  const lines = f.getAll("line").map((v) => Number(v)).filter((n) => Number.isFinite(n) && n > 0);
  const res = await runRpc<{ items: number }>("complete_bank_reconciliation", {
    p_money_account: id, p_statement_date: str(f, "statement_date"), p_statement_balance: Number(str(f, "statement_balance")),
    p_line_ids: lines, p_notes: str(f, "notes"), p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Reconciled — ${d.items} item(s) matched to the statement.`, [...A, `/accounting/banking/reconcile/${id}`]);
  return res;
}

export async function fileVatReturn(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ return_no: string; net_payable: number }>("file_vat_return", {
    p_from: str(f, "from"), p_to: str(f, "to"), p_money_account: str(f, "money_account_id") || null, p_reference: str(f, "reference"),
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.return_no} recorded${Number(d.net_payable) > 0 ? ` — Rs. ${Number(d.net_payable).toFixed(2)} paid` : " — nothing to pay (credit carried forward)"}.`,
  [...A, "/accounting/reports/vat"]);
}
