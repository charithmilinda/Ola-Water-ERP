import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Printer } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDateTime, formatLKR, formatQty } from "@/lib/format";
import { MONTHS, PAYROLL_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { LineEditor } from "@/components/ui/line-editor";
import { buttonVariants } from "@/components/ui/button";
import { adjustPayslip, approveRun, cancelRun, payRun, recalcRun } from "../actions";

export const metadata: Metadata = { title: "Payroll run" };

type Line = { source: string; component_id: string | null; name: string; kind: string; amount: number };
type Slip = { id: string; emp_no: string; employee_name: string; department: string | null; pay_basis: string; basic: number; days_paid: number; nopay_days: number;
  nopay_amount: number; ot_hours: number; ot_amount: number; earnings: number; gross: number; epf_employee: number; epf_employer: number; etf: number;
  apit: number; advance_recovery: number; other_deductions: number; net: number; warning: string | null; bank_name: string | null; bank_account_no: string | null;
  lines: Line[] };
type Details = {
  run: { id: string; run_no: string; pay_year: number; pay_month: number; status: string; employees: number; gross: number; epf_employee: number;
    epf_employer: number; etf: number; apit: number; advances: number; other_deductions: number; net: number; notes: string | null; decision_note: string | null;
    prepared_by_name: string | null; prepared_at: string; approved_by_name: string | null; approved_at: string | null; paid_at: string | null; paid_from: string | null;
    payment_reference: string | null };
  payslips: Slip[];
  journals: { id: string; entry_no: string; event_type: string; total: number }[];
};

export default async function PayrollRunPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["payroll.run", "payroll.approve"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [{ data, error }, { data: components }, { data: money }] = await Promise.all([
    supabase.rpc("payroll_run_details", { p_run: id }),
    supabase.from("pay_components").select("id, name, kind").eq("is_active", true).order("sort_order"),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).in("kind", ["bank", "cash"]).order("kind").order("is_default", { ascending: false }),
  ]);
  if (error || !data) notFound();
  const d = data as Details;
  const r = d.run;
  const st = statusBadge(PAYROLL_STATUS, r.status);
  const draft = r.status === "draft";
  const hidden = { run_id: r.id };
  const warnings = d.payslips.filter((s) => s.warning);

  return (
    <>
      <Link href="/payroll" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Payroll</Link>
      <PageHeader title={`Payroll — ${MONTHS[r.pay_month - 1]} ${r.pay_year}`}
        description={`${r.run_no} · prepared by ${r.prepared_by_name ?? "—"} ${formatDateTime(r.prepared_at)}${r.approved_by_name ? ` · approved by ${r.approved_by_name}` : ""}`}
        actions={<div className="flex flex-wrap items-center gap-2">
          <Badge tone={st.tone} className="text-sm">{st.label}</Badge>
          {r.status !== "cancelled" && <a href={`/print/payslips/${r.id}`} target="_blank" rel="noreferrer" className={buttonVariants({ variant: "secondary", size: "sm" })}><Printer className="h-4 w-4" /> Payslips</a>}
          {draft && can(access, "payroll.run") && (
            <FormDialog trigger="Recalculate" title="Recalculate" description="Takes the latest attendance, leave, advances and pay details." submitLabel="Recalculate"
              action={recalcRun} hidden={hidden}><p className="text-sm">One-off adjustments on payslips are kept.</p></FormDialog>
          )}
          {draft && can(access, "payroll.approve") && (
            <ReasonDialog trigger="Approve payroll" triggerVariant="primary" title="Approve and post" reasonRequired={false}
              description={`Net pay ${formatLKR(r.net)} for ${r.employees} employee(s). Attendance for the month is locked after this.`} confirmLabel="Approve" action={approveRun} hidden={hidden} />
          )}
          {draft && can(access, "payroll.run") && (
            <ReasonDialog trigger="Cancel" triggerVariant="dangerOutline" title="Cancel this draft" confirmLabel="Cancel payroll" confirmVariant="danger" action={cancelRun} hidden={hidden} />
          )}
          {r.status === "approved" && can(access, "payments.manage") && (
            <FormDialog trigger="Record salary payment" triggerVariant="primary" title="Salaries paid" description={`Net pay ${formatLKR(r.net)}.`}
              submitLabel="Record payment" action={payRun} hidden={hidden}>
              <Field label="Paid from" htmlFor="pp-m"><Select id="pp-m" name="money_account_id">{money?.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
              <Field label="Bank transfer reference" htmlFor="pp-r" hint="Required for bank payments"><Input id="pp-r" name="reference" /></Field>
            </FormDialog>
          )}
        </div>} />

      {draft && <Alert tone="warning" className="mb-4">Draft — check each payslip. Fix attendance or pay details and press Recalculate; add one-off bonuses or deductions with Adjust.</Alert>}
      {warnings.length > 0 && <Alert tone="warning" className="mb-4">{warnings.map((s) => `${s.employee_name}: ${s.warning}`).join(" · ")}</Alert>}
      {r.status === "paid" && <Alert tone="success" className="mb-4">Paid {r.paid_at ? formatDateTime(r.paid_at) : ""} from {r.paid_from}{r.payment_reference && ` (${r.payment_reference})`}.</Alert>}

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Gross pay" value={formatLKR(r.gross)} hint={`${r.employees} employee(s)`} />
        <Stat label="EPF (8% + 12%)" value={formatLKR(Number(r.epf_employee) + Number(r.epf_employer))} hint={`ETF ${formatLKR(r.etf)}`} />
        <Stat label="APIT" value={formatLKR(r.apit)} hint={`Advances recovered ${formatLKR(r.advances)}`} />
        <Stat label="Net pay" value={formatLKR(r.net)} hint={`Other deductions ${formatLKR(r.other_deductions)}`} />
      </div>

      <Card>
        <CardHeader title="Payslips" />
        <Table>
          <thead><tr><Th>Employee</Th><Th className="text-right">Basic</Th><Th className="text-right">No-pay</Th><Th className="text-right">OT</Th>
            <Th className="text-right">Allowances</Th><Th className="text-right">Gross</Th><Th className="text-right">EPF 8%</Th><Th className="text-right">APIT</Th>
            <Th className="text-right">Other ded.</Th><Th className="text-right">Net</Th><Th /></tr></thead>
          <tbody>{d.payslips.map((s) => (
            <tr key={s.id} className={s.warning ? "bg-amber-50/50" : ""}>
              <Td><span className="font-medium">{s.employee_name}</span><span className="block text-xs text-muted">{s.emp_no}{s.department && ` · ${s.department}`}
                {s.pay_basis === "daily" && ` · ${formatQty(s.days_paid)} days`}</span>
                {s.lines.filter((l) => l.source === "adjustment").map((l, i) => <span key={i} className="block text-xs text-ola-800">{l.kind === "deduction" ? "−" : "+"} {l.name} {formatLKR(l.amount)}</span>)}</Td>
              <Td className="num text-right">{formatLKR(s.basic)}</Td>
              <Td className="num text-right">{Number(s.nopay_amount) ? <>{formatLKR(s.nopay_amount)}<span className="block text-xs text-muted">{formatQty(s.nopay_days)} d</span></> : "—"}</Td>
              <Td className="num text-right">{Number(s.ot_amount) ? <>{formatLKR(s.ot_amount)}<span className="block text-xs text-muted">{formatQty(s.ot_hours)} h</span></> : "—"}</Td>
              <Td className="num text-right">{Number(s.earnings) ? formatLKR(s.earnings) : "—"}</Td>
              <Td className="num text-right">{formatLKR(s.gross)}</Td>
              <Td className="num text-right">{Number(s.epf_employee) ? formatLKR(s.epf_employee) : "—"}</Td>
              <Td className="num text-right">{Number(s.apit) ? formatLKR(s.apit) : "—"}</Td>
              <Td className="num text-right">{Number(s.other_deductions) + Number(s.advance_recovery) ? formatLKR(Number(s.other_deductions) + Number(s.advance_recovery)) : "—"}</Td>
              <Td className="num text-right font-semibold">{formatLKR(s.net)}</Td>
              <Td className="whitespace-nowrap text-right">
                {draft && can(access, "payroll.run") && (
                  <FormDialog trigger="Adjust" triggerVariant="ghost" title={`One-off items — ${s.employee_name}`} description="Bonus, incentive, a fine or a one-time deduction for this month only."
                    submitLabel="Save" action={adjustPayslip} hidden={{ ...hidden, payslip_id: s.id }} wide>
                    <LineEditor name="lines" items={(components ?? []).map((c) => ({ id: c.id, name: `${c.name} (${c.kind === "earning" ? "+" : "−"})` }))}
                      itemLabel="Item" addLabel="Add" minRows={0} columns={[{ key: "amount", label: "Rs.", type: "number", step: "0.01", min: 0 }]}
                      initial={s.lines.filter((l) => l.source === "adjustment" && l.component_id).map((l) => ({ item_id: l.component_id!, amount: String(Number(l.amount)) }))} />
                    <Field label="Reason" htmlFor={`ar-${s.id}`}><Input id={`ar-${s.id}`} name="reason" /></Field>
                  </FormDialog>
                )}
                <a href={`/print/payslip/${s.id}`} target="_blank" rel="noreferrer" className="ml-2 text-sm text-ola-700 hover:underline">Print</a>
              </Td>
            </tr>))}</tbody>
        </Table>
      </Card>

      {d.journals.length > 0 && (
        <p className="mt-4 text-sm text-muted">Accounting: {d.journals.map((j) => <Link key={j.id} href={`/accounting/journals/${j.id}`} className="mr-3 text-ola-700 hover:underline">{j.entry_no} ({formatLKR(j.total)})</Link>)}</p>
      )}
    </>
  );
}
