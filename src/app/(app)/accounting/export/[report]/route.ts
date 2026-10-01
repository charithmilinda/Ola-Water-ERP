import { NextResponse, type NextRequest } from "next/server";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";

const iso = (v: string | null, d: string) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : d);
const cell = (v: unknown) => {
  const s = v === null || v === undefined ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
type R = Record<string, unknown>;

/** Report download as CSV (opens in Excel). */
export async function GET(req: NextRequest, { params }: { params: Promise<{ report: string }> }) {
  const access = await getAccess();
  if (!can(access, "reports.export") || !can(access, "accounting.view")) return new NextResponse("Not allowed", { status: 403 });
  const { report } = await params;
  const sp = req.nextUrl.searchParams;
  const today = new Date().toISOString().slice(0, 10);
  const to = iso(sp.get("to"), today);
  const from = iso(sp.get("from"), `${to.slice(0, 8)}01`);
  const supabase = await createClient();
  let header: string[] = [];
  let rows: unknown[][] = [];

  const section = (name: string, list: R[]) => list.map((r) => [name, r.code, r.name, r.amount, r.previous ?? ""]);

  if (report === "trial-balance") {
    const { data, error } = await supabase.rpc("report_trial_balance", { p_from: from, p_to: to });
    if (error) return new NextResponse(error.message, { status: 400 });
    header = ["Code", "Account", "Type", "Opening", "Debits", "Credits", "Closing (debit +, credit −)"];
    rows = ((data ?? []) as R[]).map((r) => [r.code, r.name, r.account_type, r.opening, r.debit, r.credit, r.closing]);
  } else if (report === "profit-loss") {
    const { data, error } = await supabase.rpc("report_profit_loss", { p_from: from, p_to: to });
    if (error) return new NextResponse(error.message, { status: 400 });
    const d = data as { sections: Record<string, R[]>; totals: R };
    header = ["Section", "Code", "Account", `${from} to ${to}`, "Previous period"];
    rows = [...section("Income", d.sections.income), ...section("Cost of sales", d.sections.cost_of_sales), ...section("Expenses", d.sections.expenses),
      ["Gross profit", "", "", d.totals.gross_profit, ""], ["Net profit", "", "", d.totals.net_profit, d.totals.previous_net_profit]];
  } else if (report === "balance-sheet") {
    const { data, error } = await supabase.rpc("report_balance_sheet", { p_as_at: to });
    if (error) return new NextResponse(error.message, { status: 400 });
    const d = data as { assets: R[]; liabilities: R[]; equity: R[]; profit_prior_years: number; profit_this_year: number; totals: R };
    header = ["Section", "Code", "Account", `As at ${to}`];
    rows = [...d.assets.map((r) => ["Assets", r.code, r.name, r.amount]), ["Total assets", "", "", d.totals.assets],
      ...d.liabilities.map((r) => ["Liabilities", r.code, r.name, r.amount]), ["Total liabilities", "", "", d.totals.liabilities],
      ...d.equity.map((r) => ["Equity", r.code, r.name, r.amount]), ["Equity", "", "Profit of earlier years", d.profit_prior_years],
      ["Equity", "", "Profit this financial year", d.profit_this_year], ["Total equity", "", "", d.totals.equity]];
  } else if (report === "cash-flow") {
    const { data, error } = await supabase.rpc("report_cash_flow", { p_from: from, p_to: to });
    if (error) return new NextResponse(error.message, { status: 400 });
    const d = data as { opening: number; closing: number; lines: R[] };
    header = ["Purpose", "Cash in", "Cash out", "Net"];
    rows = [["Opening cash and bank", "", "", d.opening], ...d.lines.map((l) => [l.category, l.cash_in, l.cash_out, l.net]), ["Closing cash and bank", "", "", d.closing]];
  } else if (report === "ar-ageing") {
    const { data, error } = await supabase.rpc("report_ar_ageing", { p_as_at: to });
    if (error) return new NextResponse(error.message, { status: 400 });
    header = ["Customer no", "Customer", "Phone", "Not due", "1-30", "31-60", "61-90", "Over 90", "Total due", "Unused credit", "Credit limit"];
    rows = ((data ?? []) as R[]).map((r) => [r.customer_no, r.name, r.phone, r.not_due, r.d1_30, r.d31_60, r.d61_90, r.d90_plus, r.total_due, r.unapplied, r.credit_limit]);
  } else if (report === "ap-ageing") {
    const { data, error } = await supabase.rpc("report_ap_ageing", { p_as_at: to });
    if (error) return new NextResponse(error.message, { status: 400 });
    header = ["Supplier / payee", "Not due", "1-30", "31-60", "61-90", "Over 90", "Total due", "Paid in advance"];
    rows = ((data ?? []) as R[]).map((r) => [r.party, r.not_due, r.d1_30, r.d31_60, r.d61_90, r.d90_plus, r.total_due, r.advances]);
  } else if (report === "vat") {
    const { data, error } = await supabase.rpc("report_vat", { p_from: from, p_to: to });
    if (error) return new NextResponse(error.message, { status: 400 });
    const d = data as { output_vat: number; input_vat: number; net: number; sales_by_rate: R[]; credit_notes: R; purchases: R; expenses: R };
    header = ["Line", "Value before VAT", "VAT"];
    rows = [...d.sales_by_rate.map((r) => [`Sales at ${r.rate}%`, r.net, r.vat]), ["Credit notes", d.credit_notes.net, d.credit_notes.vat],
      ["Output VAT (ledger)", "", d.output_vat], ["Supplier invoices", d.purchases.net, d.purchases.vat], ["Expenses", d.expenses.net, d.expenses.vat],
      ["Input VAT (ledger)", "", d.input_vat], ["VAT for the period", "", d.net]];
  } else if (report === "ledger") {
    const account = sp.get("account") ?? "";
    const { data, error } = await supabase.rpc("report_general_ledger", { p_account: account, p_from: from, p_to: to });
    if (error) return new NextResponse(error.message, { status: 400 });
    const d = data as { opening: number; closing: number; lines: R[] };
    header = ["Date", "Entry", "Description", "Memo", "Party", "Debit", "Credit", "Balance"];
    rows = [["", "", "Opening balance", "", "", "", "", d.opening], ...d.lines.map((l) => [l.date, l.entry_no, l.description, l.memo, l.party, l.debit, l.credit, l.balance]),
      ["", "", "Closing balance", "", "", "", "", d.closing]];
  } else {
    return new NextResponse("Unknown report", { status: 404 });
  }

  const body = "﻿" + [header, ...rows].map((r) => r.map(cell).join(",")).join("\r\n");
  return new NextResponse(body, {
    headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": `attachment; filename="ola-${report}-${from}-${to}.csv"` },
  });
}
