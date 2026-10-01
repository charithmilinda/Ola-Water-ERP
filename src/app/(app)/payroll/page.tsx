import type { Metadata } from "next";
import Link from "next/link";
import { HandCoins, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { MONTHS, PAYROLL_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { createRun, savePayComponent, setApit, setRate } from "./actions";

export const metadata: Metadata = { title: "Payroll" };

const RATE_NAMES: Record<string, string> = { epf_employee: "EPF — employee", epf_employer: "EPF — employer", etf_employer: "ETF — employer" };

export default async function PayrollPage() {
  const access = await requirePermission(["payroll.run", "payroll.approve"]);
  const supabase = await createClient();
  const [{ data: runs }, { data: rates }, { data: bands }, { data: components }] = await Promise.all([
    supabase.from("payroll_runs").select("id, run_no, pay_year, pay_month, status, employees, gross, net, epf_employee, epf_employer, etf, apit, prepared_at, paid_at")
      .order("pay_year", { ascending: false }).order("pay_month", { ascending: false }).limit(36),
    supabase.from("payroll_statutory_rates").select("code, rate_percent, effective_from").order("effective_from", { ascending: false }),
    supabase.from("apit_bands").select("effective_from, band_no, band_width, rate_percent").order("effective_from", { ascending: false }).order("band_no"),
    supabase.from("pay_components").select("id, code, name, kind, epf_liable, taxable, is_active").order("sort_order"),
  ]);
  const today = todayISO();
  const lastMonth = (() => { const d = new Date(`${today.slice(0, 7)}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 1); return d.toISOString().slice(0, 7); })();
  const approve = can(access, "payroll.approve");
  const current = (code: string) => (rates ?? []).find((r) => r.code === code && r.effective_from <= today);
  const apitFrom = (bands ?? []).find((b) => b.effective_from <= today)?.effective_from;
  const apit = (bands ?? []).filter((b) => b.effective_from === apitFrom);
  const nextMonth = `${today.slice(0, 7)}-01`;

  return (
    <>
      <PageHeader title="Payroll" description="Prepare the month's payroll from attendance, leave and pay details; a second person approves it (the salary journal is posted); then record the payment."
        actions={can(access, "payroll.run") && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> Prepare payroll</>} triggerVariant="primary" triggerSize="md" title="Prepare a payroll"
            description="Everyone employed during the month is included. You can recalculate the draft as often as needed." submitLabel="Prepare" action={createRun}>
            <Field label="Month" htmlFor="pr-m" required><Input id="pr-m" name="month" type="month" defaultValue={lastMonth} max={today.slice(0, 7)} required /></Field>
            <Field label="Notes" htmlFor="pr-n"><Textarea id="pr-n" name="notes" /></Field>
          </FormDialog>
        )} />

      <div className="space-y-6">
        <Card>
          <CardHeader title="Payroll runs" actions={<Link href="/payroll/statutory" className={buttonVariants({ variant: "secondary", size: "sm" })}>EPF / ETF / APIT lists</Link>} />
          {(runs ?? []).length === 0 ? <EmptyState icon={HandCoins} title="No payroll yet" /> : (
            <Table>
              <thead><tr><Th>Month</Th><Th>Payroll</Th><Th className="text-right">Staff</Th><Th className="text-right">Gross</Th><Th className="text-right">EPF + ETF</Th>
                <Th className="text-right">APIT</Th><Th className="text-right">Net pay</Th><Th>Status</Th></tr></thead>
              <tbody>{runs?.map((r) => { const st = statusBadge(PAYROLL_STATUS, r.status); return (
                <tr key={r.id} className="hover:bg-ola-50/40">
                  <Td><Link href={`/payroll/${r.id}`} className="font-medium text-ola-700 hover:underline">{MONTHS[r.pay_month - 1]} {r.pay_year}</Link></Td>
                  <Td className="font-mono text-xs">{r.run_no}</Td><Td className="num text-right">{r.employees}</Td>
                  <Td className="num text-right">{formatLKR(r.gross)}</Td>
                  <Td className="num text-right">{formatLKR(Number(r.epf_employee) + Number(r.epf_employer) + Number(r.etf))}</Td>
                  <Td className="num text-right">{formatLKR(r.apit)}</Td><Td className="num text-right font-medium">{formatLKR(r.net)}</Td>
                  <Td><Badge tone={st.tone}>{st.label}</Badge></Td></tr>); })}</tbody>
            </Table>
          )}
        </Card>

        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader title="Statutory rates" description="Set by law; change them from a date when the law changes."
              actions={approve && (
                <FormDialog trigger="Change a rate" title="Change a statutory rate" description="Applies to payrolls of months from this date. Earlier payrolls keep their rates."
                  submitLabel="Save" action={setRate}>
                  <Field label="Rate" htmlFor="sr-c"><Select id="sr-c" name="code">{Object.entries(RATE_NAMES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
                  <div className="grid gap-4 sm:grid-cols-2">
                    <Field label="New rate (%)" htmlFor="sr-r" required><Input id="sr-r" name="rate" type="number" step="0.01" min={0} max={100} required /></Field>
                    <Field label="From" htmlFor="sr-f" required><Input id="sr-f" name="effective_from" type="date" min={nextMonth} defaultValue={nextMonth} required /></Field>
                  </div>
                  <Field label="Reason / gazette" htmlFor="sr-n" required><Input id="sr-n" name="reason" required /></Field>
                </FormDialog>
              )} />
            <ul className="divide-y divide-line text-sm">
              {Object.entries(RATE_NAMES).map(([k, v]) => (
                <li key={k} className="flex justify-between px-5 py-2.5"><span>{v}</span>
                  <span className="num font-semibold">{current(k) ? `${Number(current(k)!.rate_percent)}%` : "—"}</span></li>))}
            </ul>
          </Card>

          <Card>
            <CardHeader title="APIT table (monthly, primary employment)" description={apitFrom ? `In force from ${formatDate(apitFrom)}. Confirm with your accountant against the IRD table.` : "Not set"}
              actions={approve && (
                <FormDialog trigger="New table" title="New APIT table" description="Each band taxes the next slice of monthly pay at its rate; leave the last width empty."
                  submitLabel="Save table" action={setApit} wide>
                  <Field label="From" htmlFor="ap-f" required><Input id="ap-f" name="effective_from" type="date" min={nextMonth} defaultValue={nextMonth} required /></Field>
                  <div className="grid grid-cols-2 gap-2">
                    {[...Array(8).keys()].map((i) => (
                      <div key={i} className="contents">
                        <Input aria-label={`Band ${i + 1} width`} name={`w${i}`} type="number" step="0.01" min={0} placeholder={`Band ${i + 1}: next Rs.… (empty = rest)`}
                          defaultValue={apit[i]?.band_width ?? ""} />
                        <Input aria-label={`Band ${i + 1} rate`} name={`r${i}`} type="number" step="0.01" min={0} max={100} placeholder="rate %" defaultValue={apit[i]?.rate_percent ?? ""} />
                      </div>
                    ))}
                  </div>
                  <Field label="Reason / circular" htmlFor="ap-r" required><Input id="ap-r" name="reason" required /></Field>
                </FormDialog>
              )} />
            <Table>
              <thead><tr><Th>Band</Th><Th className="text-right">Next (Rs. a month)</Th><Th className="text-right">Rate</Th></tr></thead>
              <tbody>{apit.map((b) => (
                <tr key={b.band_no}><Td>{b.band_no}</Td><Td className="num text-right">{b.band_width === null ? "Balance" : formatLKR(b.band_width)}</Td>
                  <Td className="num text-right">{Number(b.rate_percent)}%</Td></tr>))}</tbody>
            </Table>
          </Card>
        </div>

        <Card>
          <CardHeader title="Allowances & deductions" description="Fixed amounts are set on each employee; one-off ones are added to a draft payslip."
            actions={approve && (
              <FormDialog trigger="Add" title="New allowance or deduction" submitLabel="Add" action={savePayComponent}>
                <div className="grid gap-4 sm:grid-cols-3">
                  <Field label="Code" htmlFor="pc-c" required><Input id="pc-c" name="code" required placeholder="ALLOW_MEAL" /></Field>
                  <Field label="Name" htmlFor="pc-n" required className="sm:col-span-2"><Input id="pc-n" name="name" required /></Field>
                </div>
                <Field label="Kind" htmlFor="pc-k"><Select id="pc-k" name="kind"><option value="earning">Allowance / earning</option><option value="deduction">Deduction</option></Select></Field>
                <div className="flex gap-6 text-sm">
                  <label className="flex items-center gap-2"><input type="checkbox" name="epf_liable" /> Counts for EPF / ETF</label>
                  <label className="flex items-center gap-2"><input type="checkbox" name="taxable" defaultChecked /> Taxable (APIT)</label>
                </div>
              </FormDialog>
            )} />
          <CardBody className="flex flex-wrap gap-2">
            {components?.map((c) => (
              <span key={c.id} className={`rounded-lg px-2.5 py-1 text-xs ring-1 ring-inset ${c.kind === "earning" ? "bg-emerald-50 ring-emerald-200" : "bg-red-50 ring-red-200"} ${c.is_active ? "" : "opacity-50"}`}>
                {c.name}{c.epf_liable ? " · EPF" : ""}{!c.taxable ? " · tax-free" : ""}</span>))}
          </CardBody>
        </Card>
      </div>
    </>
  );
}
