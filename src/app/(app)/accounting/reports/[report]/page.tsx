import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Download } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatPhone, todayISO } from "@/lib/format";
import { REPORTS } from "@/lib/reports";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Alert } from "@/components/ui/alert";
import { Button, buttonVariants } from "@/components/ui/button";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Label, Select } from "@/components/ui/field";
import { PrintButton } from "./print-button";
import { fileVatReturn } from "../../actions";

export const metadata: Metadata = { title: "Report" };

type Row = { account_id?: string; code: string; name: string; amount: number; previous?: number };
const iso = (v: string | undefined, d: string) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : d);
const money = (n: number | string | null | undefined) => formatLKR(n ?? 0);
const neg = (n: number | string) => (Number(n) < 0 ? "text-red-700" : "");

function Section({ title, rows, total, compare, from, to }: { title: string; rows: Row[]; total: number; compare?: number; from: string; to: string }) {
  return (
    <>
      <tr><Td colSpan={compare === undefined ? 2 : 3} className="bg-surface/60 font-semibold">{title}</Td></tr>
      {rows.map((r) => (
        <tr key={r.code}>
          <Td className="pl-8"><Link href={`/accounting/ledger?account=${r.account_id}&from=${from}&to=${to}`} className="hover:underline">{r.code} {r.name}</Link></Td>
          <Td className={`num text-right ${neg(r.amount)}`}>{money(r.amount)}</Td>
          {compare !== undefined && <Td className="num text-right text-muted">{money(r.previous)}</Td>}
        </tr>
      ))}
      <tr><Td className="pl-8 font-medium">Total {title.toLowerCase()}</Td><Td className="num text-right font-semibold">{money(total)}</Td>
        {compare !== undefined && <Td className="num text-right font-medium text-muted">{money(compare)}</Td>}</tr>
    </>
  );
}

export default async function ReportPage({ params, searchParams }: { params: Promise<{ report: string }>; searchParams: Promise<{ from?: string; to?: string }> }) {
  const access = await requirePermission("accounting.view");
  const { report } = await params;
  const meta = REPORTS.find((r) => r.slug === report);
  if (!meta) notFound();
  const sp = await searchParams;
  const today = todayISO();
  const to = iso(sp.to, today);
  const from = iso(sp.from, `${to.slice(0, 8)}01`);
  const pointInTime = report === "balance-sheet" || report === "ar-ageing" || report === "ap-ageing";
  const supabase = await createClient();
  const csv = `/accounting/export/${report}?from=${from}&to=${to}`;

  let body: React.ReactNode = null;
  let extra: React.ReactNode = null;

  if (report === "profit-loss") {
    const { data, error } = await supabase.rpc("report_profit_loss", { p_from: from, p_to: to });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const d = data as { previous_from: string; previous_to: string; sections: Record<string, Row[]>; totals: Record<string, number> };
    const t = d.totals;
    body = (
      <Table>
        <thead><tr><Th>Account</Th><Th className="text-right">{formatDate(from)} – {formatDate(to)}</Th><Th className="text-right">Previous ({formatDate(d.previous_from)} – {formatDate(d.previous_to)})</Th></tr></thead>
        <tbody>
          <Section title="Income" rows={d.sections.income} total={t.income} compare={t.previous_income} from={from} to={to} />
          <Section title="Cost of sales" rows={d.sections.cost_of_sales} total={t.cost_of_sales} compare={t.previous_cost_of_sales} from={from} to={to} />
          <tr><Td className="font-semibold">Gross profit</Td><Td className={`num text-right font-semibold ${neg(t.gross_profit)}`}>{money(t.gross_profit)}</Td>
            <Td className="num text-right text-muted">{money(Number(t.previous_income) - Number(t.previous_cost_of_sales))}</Td></tr>
          <Section title="Expenses" rows={d.sections.expenses} total={t.expenses} compare={t.previous_expenses} from={from} to={to} />
          <tr className="text-base"><Td className="font-bold">Net profit</Td><Td className={`num text-right font-bold ${neg(t.net_profit)}`}>{money(t.net_profit)}</Td>
            <Td className="num text-right font-medium text-muted">{money(t.previous_net_profit)}</Td></tr>
        </tbody>
      </Table>
    );
  } else if (report === "balance-sheet") {
    const { data, error } = await supabase.rpc("report_balance_sheet", { p_as_at: to });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const d = data as { year_start: string; assets: Row[]; liabilities: Row[]; equity: Row[]; profit_prior_years: number; profit_this_year: number; totals: Record<string, number> };
    const ok = Math.abs(Number(d.totals.assets) - Number(d.totals.liabilities) - Number(d.totals.equity)) < 0.01;
    body = (
      <Table>
        <thead><tr><Th>As at {formatDate(to)}</Th><Th className="text-right">Rs.</Th></tr></thead>
        <tbody>
          <Section title="Assets" rows={d.assets} total={d.totals.assets} from={d.year_start} to={to} />
          <Section title="Liabilities" rows={d.liabilities} total={d.totals.liabilities} from={d.year_start} to={to} />
          <tr><Td colSpan={2} className="bg-surface/60 font-semibold">Equity</Td></tr>
          {d.equity.map((r) => <tr key={r.code}><Td className="pl-8">{r.code} {r.name}</Td><Td className="num text-right">{money(r.amount)}</Td></tr>)}
          <tr><Td className="pl-8">Profit of earlier years (not yet moved to retained earnings)</Td><Td className={`num text-right ${neg(d.profit_prior_years)}`}>{money(d.profit_prior_years)}</Td></tr>
          <tr><Td className="pl-8">Profit this financial year (from {formatDate(d.year_start)})</Td><Td className={`num text-right ${neg(d.profit_this_year)}`}>{money(d.profit_this_year)}</Td></tr>
          <tr><Td className="pl-8 font-medium">Total equity</Td><Td className="num text-right font-semibold">{money(d.totals.equity)}</Td></tr>
          <tr className="text-base"><Td className="font-bold">Liabilities + equity</Td><Td className="num text-right font-bold">{money(Number(d.totals.liabilities) + Number(d.totals.equity))}</Td></tr>
        </tbody>
      </Table>
    );
    if (!ok) extra = <Alert tone="error" className="mb-4">The balance sheet does not balance — tell your system administrator.</Alert>;
  } else if (report === "cash-flow") {
    const { data, error } = await supabase.rpc("report_cash_flow", { p_from: from, p_to: to });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const d = data as { opening: number; closing: number; lines: { category: string; cash_in: number; cash_out: number; net: number }[];
      accounts: { code: string; name: string; opening: number; closing: number }[] };
    body = (
      <>
        <Table>
          <thead><tr><Th>Purpose</Th><Th className="text-right">Cash in</Th><Th className="text-right">Cash out</Th><Th className="text-right">Net</Th></tr></thead>
          <tbody>
            <tr><Td className="font-medium">Cash and bank at {formatDate(from)}</Td><Td /><Td /><Td className="num text-right font-medium">{money(d.opening)}</Td></tr>
            {d.lines.map((l) => (
              <tr key={l.category}><Td className="pl-8">{l.category}</Td><Td className="num text-right">{money(l.cash_in)}</Td>
                <Td className="num text-right">{money(l.cash_out)}</Td><Td className={`num text-right ${neg(l.net)}`}>{money(l.net)}</Td></tr>
            ))}
            <tr className="text-base"><Td className="font-bold">Cash and bank at {formatDate(to)}</Td><Td /><Td /><Td className="num text-right font-bold">{money(d.closing)}</Td></tr>
          </tbody>
        </Table>
        <p className="px-5 pt-4 text-sm font-medium">Made up of</p>
        <Table>
          <tbody>{d.accounts.filter((a) => Number(a.opening) || Number(a.closing)).map((a) => (
            <tr key={a.code}><Td>{a.code} {a.name}</Td><Td className="num text-right text-muted">{money(a.opening)}</Td><Td className="num text-right">{money(a.closing)}</Td></tr>
          ))}</tbody>
        </Table>
      </>
    );
  } else if (report === "trial-balance") {
    const { data, error } = await supabase.rpc("report_trial_balance", { p_from: from, p_to: to });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const rows = (data ?? []) as { account_id: string; code: string; name: string; account_type: string; opening: number; debit: number; credit: number; closing: number }[];
    const sum = (k: "opening" | "debit" | "credit" | "closing") => rows.reduce((a, r) => a + Number(r[k]), 0);
    const dr = rows.reduce((a, r) => a + Math.max(Number(r.closing), 0), 0);
    const cr = rows.reduce((a, r) => a + Math.max(-Number(r.closing), 0), 0);
    body = (
      <Table>
        <thead><tr><Th>Account</Th><Th className="text-right">Opening</Th><Th className="text-right">Debits</Th><Th className="text-right">Credits</Th>
          <Th className="text-right">Closing debit</Th><Th className="text-right">Closing credit</Th></tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.code}><Td><Link href={`/accounting/ledger?account=${r.account_id}&from=${from}&to=${to}`} className="hover:underline">{r.code} {r.name}</Link></Td>
              <Td className="num text-right text-muted">{money(r.opening)}</Td><Td className="num text-right">{money(r.debit)}</Td><Td className="num text-right">{money(r.credit)}</Td>
              <Td className="num text-right">{Number(r.closing) > 0 ? money(r.closing) : ""}</Td><Td className="num text-right">{Number(r.closing) < 0 ? money(-r.closing) : ""}</Td></tr>
          ))}
          <tr className="font-semibold"><Td>Total</Td><Td className="num text-right">{money(sum("opening"))}</Td><Td className="num text-right">{money(sum("debit"))}</Td>
            <Td className="num text-right">{money(sum("credit"))}</Td><Td className="num text-right">{money(dr)}</Td><Td className="num text-right">{money(cr)}</Td></tr>
        </tbody>
      </Table>
    );
    if (Math.abs(dr - cr) >= 0.01) extra = <Alert tone="error" className="mb-4">Debits and credits differ — tell your system administrator.</Alert>;
  } else if (report === "ar-ageing") {
    const { data, error } = await supabase.rpc("report_ar_ageing", { p_as_at: to });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const rows = (data ?? []) as { customer_id: string; customer_no: string; name: string; phone: string | null; not_due: number; d1_30: number; d31_60: number;
      d61_90: number; d90_plus: number; total_due: number; unapplied: number; net: number; credit_limit: number }[];
    const t = (k: keyof (typeof rows)[number]) => rows.reduce((a, r) => a + Number(r[k] ?? 0), 0);
    body = (
      <Table>
        <thead><tr><Th>Customer</Th><Th className="text-right">Not due</Th><Th className="text-right">1–30 days</Th><Th className="text-right">31–60</Th><Th className="text-right">61–90</Th>
          <Th className="text-right">Over 90</Th><Th className="text-right">Total</Th><Th className="text-right">Unused credit</Th></tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.customer_id}><Td><Link href={`/customers/${r.customer_id}`} className="font-medium text-ola-700 hover:underline">{r.name}</Link>
              <span className="block text-xs text-muted">{r.customer_no}{r.phone && ` · ${formatPhone(r.phone)}`}</span></Td>
              <Td className="num text-right">{money(r.not_due)}</Td><Td className="num text-right">{money(r.d1_30)}</Td><Td className="num text-right">{money(r.d31_60)}</Td>
              <Td className="num text-right">{money(r.d61_90)}</Td><Td className={`num text-right ${Number(r.d90_plus) > 0 ? "font-semibold text-red-700" : ""}`}>{money(r.d90_plus)}</Td>
              <Td className="num text-right font-medium">{money(r.total_due)}</Td><Td className="num text-right text-muted">{Number(r.unapplied) ? money(r.unapplied) : ""}</Td></tr>
          ))}
          <tr className="font-semibold"><Td>Total</Td><Td className="num text-right">{money(t("not_due"))}</Td><Td className="num text-right">{money(t("d1_30"))}</Td>
            <Td className="num text-right">{money(t("d31_60"))}</Td><Td className="num text-right">{money(t("d61_90"))}</Td><Td className="num text-right">{money(t("d90_plus"))}</Td>
            <Td className="num text-right">{money(t("total_due"))}</Td><Td className="num text-right">{money(t("unapplied"))}</Td></tr>
        </tbody>
      </Table>
    );
  } else if (report === "ap-ageing") {
    const { data, error } = await supabase.rpc("report_ap_ageing", { p_as_at: to });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const rows = (data ?? []) as { party: string; supplier_id: string | null; not_due: number; d1_30: number; d31_60: number; d61_90: number; d90_plus: number; total_due: number; advances: number }[];
    const t = (k: "not_due" | "d1_30" | "d31_60" | "d61_90" | "d90_plus" | "total_due") => rows.reduce((a, r) => a + Number(r[k]), 0);
    body = (
      <Table>
        <thead><tr><Th>Supplier / payee</Th><Th className="text-right">Not due</Th><Th className="text-right">1–30 days</Th><Th className="text-right">31–60</Th><Th className="text-right">61–90</Th>
          <Th className="text-right">Over 90</Th><Th className="text-right">Total</Th></tr></thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i}><Td>{r.supplier_id ? <Link href={`/suppliers/${r.supplier_id}`} className="font-medium text-ola-700 hover:underline">{r.party}</Link> : r.party}
              {Number(r.advances) > 0 && <span className="block text-xs text-muted">{money(r.advances)} paid in advance</span>}</Td>
              <Td className="num text-right">{money(r.not_due)}</Td><Td className="num text-right">{money(r.d1_30)}</Td><Td className="num text-right">{money(r.d31_60)}</Td>
              <Td className="num text-right">{money(r.d61_90)}</Td><Td className={`num text-right ${Number(r.d90_plus) > 0 ? "font-semibold text-red-700" : ""}`}>{money(r.d90_plus)}</Td>
              <Td className="num text-right font-medium">{money(r.total_due)}</Td></tr>
          ))}
          <tr className="font-semibold"><Td>Total</Td>{(["not_due", "d1_30", "d31_60", "d61_90", "d90_plus", "total_due"] as const).map((k) => <Td key={k} className="num text-right">{money(t(k))}</Td>)}</tr>
        </tbody>
      </Table>
    );
  } else if (report === "vat") {
    const [{ data, error }, { data: banks }] = await Promise.all([
      supabase.rpc("report_vat", { p_from: from, p_to: to }),
      supabase.from("money_accounts").select("id, name").eq("kind", "bank").eq("is_active", true).order("is_default", { ascending: false }),
    ]);
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const d = data as { output_vat: number; input_vat: number; net: number; vat_no: string | null; sales_by_rate: { rate: number; net: number; vat: number }[];
      credit_notes: { net: number; vat: number }; purchases: { net: number; vat: number }; expenses: { net: number; vat: number };
      balances: { vat_output: number; vat_input: number }; last_return_to: string | null;
      returns: { return_no: string; period_from: string; period_to: string; output_vat: number; input_vat: number; net_payable: number; reference: string | null }[] };
    body = (
      <>
        <Table>
          <tbody>
            <tr><Td colSpan={3} className="bg-surface/60 font-semibold">Sales (output VAT)</Td></tr>
            {d.sales_by_rate.map((r) => <tr key={r.rate}><Td className="pl-8">Sales at {Number(r.rate)}%</Td><Td className="num text-right">{money(r.net)}</Td><Td className="num text-right">{money(r.vat)}</Td></tr>)}
            <tr><Td className="pl-8">Less credit notes</Td><Td className="num text-right">−{money(d.credit_notes.net)}</Td><Td className="num text-right">−{money(d.credit_notes.vat)}</Td></tr>
            <tr><Td className="pl-8 font-medium">Output VAT (from the ledger)</Td><Td /><Td className="num text-right font-semibold">{money(d.output_vat)}</Td></tr>
            <tr><Td colSpan={3} className="bg-surface/60 font-semibold">Purchases and expenses (input VAT)</Td></tr>
            <tr><Td className="pl-8">Supplier invoices</Td><Td className="num text-right">{money(d.purchases.net)}</Td><Td className="num text-right">{money(d.purchases.vat)}</Td></tr>
            <tr><Td className="pl-8">Expenses</Td><Td className="num text-right">{money(d.expenses.net)}</Td><Td className="num text-right">{money(d.expenses.vat)}</Td></tr>
            <tr><Td className="pl-8 font-medium">Input VAT (from the ledger)</Td><Td /><Td className="num text-right font-semibold">{money(d.input_vat)}</Td></tr>
            <tr className="text-base"><Td className="font-bold">VAT for the period</Td><Td /><Td className={`num text-right font-bold ${neg(d.net)}`}>{money(d.net)}</Td></tr>
          </tbody>
        </Table>
        <p className="px-5 pt-3 text-xs text-muted">Values in the two middle columns are before VAT. VAT registration no. {d.vat_no || "— not set (System Settings)"}.
          Balance still to settle up to {formatDate(to)}: output {money(d.balances.vat_output)}, input {money(d.balances.vat_input)}.</p>
        {d.returns.length > 0 && (
          <>
            <p className="px-5 pt-4 text-sm font-medium">VAT returns filed</p>
            <Table>
              <thead><tr><Th>Return</Th><Th>Period</Th><Th className="text-right">Output</Th><Th className="text-right">Input</Th><Th className="text-right">Paid</Th></tr></thead>
              <tbody>{d.returns.map((r) => <tr key={r.return_no}><Td>{r.return_no}<span className="block text-xs text-muted">{r.reference}</span></Td>
                <Td>{formatDate(r.period_from)} – {formatDate(r.period_to)}</Td><Td className="num text-right">{money(r.output_vat)}</Td>
                <Td className="num text-right">{money(r.input_vat)}</Td><Td className="num text-right">{money(Math.max(Number(r.net_payable), 0))}</Td></tr>)}</tbody>
            </Table>
          </>
        )}
      </>
    );
    if (can(access, "accounting.period_close")) {
      extra = (
        <div className="mb-4 flex justify-end">
          <FormDialog trigger="Record VAT return & payment" triggerVariant="primary" triggerSize="md" title="Record a VAT return"
            description="Clears the VAT owed up to the end of the period against input VAT and records the payment to the Inland Revenue Department. Excess input VAT is carried forward."
            submitLabel="Record return" action={fileVatReturn}>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Period from" htmlFor="vr-f" required><Input id="vr-f" name="from" type="date" defaultValue={d.last_return_to ?? from} required /></Field>
              <Field label="Period to" htmlFor="vr-t" required><Input id="vr-t" name="to" type="date" defaultValue={to} required /></Field>
            </div>
            <Field label="Paid from" htmlFor="vr-b"><Select id="vr-b" name="money_account_id">{banks?.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</Select></Field>
            <Field label="Payment reference" htmlFor="vr-r" hint="IRD payment reference / bank reference"><Input id="vr-r" name="reference" /></Field>
          </FormDialog>
        </div>
      );
    }
  }

  return (
    <>
      <Link href="/accounting" className="no-print mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Accounting</Link>
      <PageHeader title={meta.title} description={meta.description} actions={<div className="no-print flex gap-2">
        <PrintButton />
        {can(access, "reports.export") && <a href={csv} className={buttonVariants({ variant: "secondary", size: "md" })}><Download className="h-4 w-4" /> Excel (CSV)</a>}
      </div>} />
      <Card className="no-print mb-4 p-4">
        <form className="flex flex-wrap items-end gap-3" method="get">
          {!pointInTime && <div><Label htmlFor="from">From</Label><Input id="from" name="from" type="date" defaultValue={from} /></div>}
          <div><Label htmlFor="to">{pointInTime ? "As at" : "To"}</Label><Input id="to" name="to" type="date" defaultValue={to} /></div>
          <Button type="submit">Show</Button>
        </form>
      </Card>
      {extra}
      <Card>
        <CardHeader title={`${meta.title} — ${pointInTime ? `as at ${formatDate(to)}` : `${formatDate(from)} to ${formatDate(to)}`}`} />
        {body}
      </Card>
    </>
  );
}
