import type { Metadata } from "next";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDateTime, formatLKR, todayISO } from "@/lib/format";
import { MONTHS } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { PrintButton } from "../../accounting/reports/[report]/print-button";
import { payStatutory } from "../actions";

export const metadata: Metadata = { title: "EPF, ETF & APIT" };

type Row = { emp_no: string; name: string; epf_no: string | null; epf_earnings: number; epf_employee: number; epf_employer: number; etf: number; taxable: number; apit: number };
type Report = { year: number; month: number; employer_epf_no: string | null; rows: Row[]; paid: { kind: string; payment_no: string; amount: number; paid_at: string; reference: string | null }[];
  payroll_status: string | null };

export default async function StatutoryPage({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
  const access = await requirePermission(["payroll.run", "payroll.approve"]);
  const today = todayISO();
  const raw = (await searchParams).month;
  const def = (() => { const d = new Date(`${today.slice(0, 7)}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 1); return d.toISOString().slice(0, 7); })();
  const month = raw && /^\d{4}-\d{2}$/.test(raw) ? raw : def;
  const [y, m] = month.split("-").map(Number);
  const supabase = await createClient();
  const [{ data }, { data: money }] = await Promise.all([
    supabase.rpc("statutory_report", { p_year: y, p_month: m }),
    supabase.from("money_accounts").select("id, name").eq("is_active", true).eq("kind", "bank").order("is_default", { ascending: false }),
  ]);
  const r = data as Report;
  const sum = (k: keyof Row) => r.rows.reduce((a, x) => a + Number(x[k]), 0);
  const due = { epf: sum("epf_employee") + sum("epf_employer"), etf: sum("etf"), apit: sum("apit") };
  const paid = (k: string) => r.paid.filter((p) => p.kind === k).reduce((a, p) => a + Number(p.amount), 0);

  return (
    <>
      <PageHeader title={`EPF, ETF & APIT — ${MONTHS[m - 1]} ${y}`}
        description={`From the approved payroll. Employer EPF no.: ${r.employer_epf_no || "not set (System Settings → Company)"}`}
        actions={<div className="no-print flex flex-wrap items-center gap-2">
          <form className="flex items-center gap-1"><Input type="month" name="month" defaultValue={month} max={today.slice(0, 7)} className="h-10 w-40" aria-label="Month" />
            <button className={buttonVariants({ variant: "secondary", size: "md" })}>Show</button></form>
          <PrintButton />
          {can(access, "payments.manage") && r.rows.length > 0 && (
            <FormDialog trigger="Record payment" triggerVariant="primary" triggerSize="md" title="Payment to the authorities" submitLabel="Record payment" action={payStatutory}
              hidden={{ year: String(y), month: String(m) }}>
              <Field label="For" htmlFor="sp-k"><Select id="sp-k" name="kind">
                <option value="epf">EPF — Central Bank ({formatLKR(due.epf - paid("epf"))} due)</option>
                <option value="etf">ETF — ETF Board ({formatLKR(due.etf - paid("etf"))} due)</option>
                <option value="apit">APIT — Inland Revenue ({formatLKR(due.apit - paid("apit"))} due)</option></Select></Field>
              <Field label="Amount (Rs.)" htmlFor="sp-a" required><Input id="sp-a" name="amount" type="number" min={0.01} step="0.01" required /></Field>
              <Field label="Paid from" htmlFor="sp-m"><Select id="sp-m" name="money_account_id">{money?.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
              <Field label="Reference" htmlFor="sp-r"><Input id="sp-r" name="reference" placeholder="Bank / receipt reference" /></Field>
            </FormDialog>
          )}
        </div>} />

      {r.payroll_status === "draft" && <Alert tone="warning" className="mb-4">The payroll for this month is still a draft — figures appear once it is approved.</Alert>}
      {!r.payroll_status && <Alert tone="info" className="mb-4">No payroll for this month.</Alert>}

      <div className="mb-6 grid gap-4 sm:grid-cols-3">
        {(["epf", "etf", "apit"] as const).map((k) => (
          <Card key={k} className="p-5"><p className="text-sm text-muted">{k.toUpperCase()}</p>
            <p className="num mt-1 text-2xl font-semibold">{formatLKR(due[k])}</p>
            <p className={`text-xs ${paid(k) >= due[k] && due[k] > 0 ? "text-emerald-700" : "text-muted"}`}>Paid {formatLKR(paid(k))}</p></Card>
        ))}
      </div>

      <Card>
        <CardHeader title="Per employee" />
        <Table>
          <thead><tr><Th>Employee</Th><Th>EPF no.</Th><Th className="text-right">EPF earnings</Th><Th className="text-right">EPF 8%</Th><Th className="text-right">EPF 12%</Th>
            <Th className="text-right">Total EPF</Th><Th className="text-right">ETF 3%</Th><Th className="text-right">Taxable pay</Th><Th className="text-right">APIT</Th></tr></thead>
          <tbody>
            {r.rows.map((x) => (
              <tr key={x.emp_no}><Td>{x.name}<span className="block text-xs text-muted">{x.emp_no}</span></Td><Td>{x.epf_no ?? "—"}</Td>
                <Td className="num text-right">{formatLKR(x.epf_earnings)}</Td><Td className="num text-right">{formatLKR(x.epf_employee)}</Td>
                <Td className="num text-right">{formatLKR(x.epf_employer)}</Td><Td className="num text-right">{formatLKR(Number(x.epf_employee) + Number(x.epf_employer))}</Td>
                <Td className="num text-right">{formatLKR(x.etf)}</Td><Td className="num text-right">{formatLKR(x.taxable)}</Td><Td className="num text-right">{formatLKR(x.apit)}</Td></tr>))}
            {r.rows.length > 0 && (
              <tr className="font-semibold"><Td colSpan={2}>Total</Td><Td className="num text-right">{formatLKR(sum("epf_earnings"))}</Td>
                <Td className="num text-right">{formatLKR(sum("epf_employee"))}</Td><Td className="num text-right">{formatLKR(sum("epf_employer"))}</Td>
                <Td className="num text-right">{formatLKR(due.epf)}</Td><Td className="num text-right">{formatLKR(due.etf)}</Td>
                <Td className="num text-right">{formatLKR(sum("taxable"))}</Td><Td className="num text-right">{formatLKR(due.apit)}</Td></tr>
            )}
          </tbody>
        </Table>
      </Card>
      {r.paid.length > 0 && (
        <p className="mt-4 text-sm text-muted">Payments: {r.paid.map((p) => `${p.kind.toUpperCase()} ${formatLKR(p.amount)} on ${formatDateTime(p.paid_at)}${p.reference ? ` (${p.reference})` : ""}`).join(" · ")}</p>
      )}
    </>
  );
}
