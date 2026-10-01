import type { Metadata } from "next";
import { DocumentsCard } from "@/components/documents/documents-card";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatLKR, formatPhone, formatQty } from "@/lib/format";
import { EMPLOYMENT_TYPES, LEAVE_STATUS, MONTHS, PAYROLL_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { LineEditor } from "@/components/ui/line-editor";
import { EmployeeFields, type Employee } from "../employee-fields";
import { decideLeave, giveAdvance, requestLeave, savePayItems, updateEmployee } from "../actions";

export const metadata: Metadata = { title: "Employee" };

type Details = {
  employee: Employee & { department: string | null; position: string | null; location: string | null; login: string | null };
  can_see_pay: boolean;
  pay_items: { component_id: string; name: string; kind: string; amount: number }[] | null;
  leave: { leave_type_id: string; code: string; name: string; entitled: number; taken: number; pending: number; left: number | null }[];
  leave_requests: { id: string; request_no: string; type: string; from: string; to: string; days: number; status: string; reason: string | null }[];
  attendance_month: { present: number; half_day: number; absent: number; leave: number; ot_hours: number };
  advances: { advance_no: string; date: string; amount: number; installment: number; outstanding: number; status: string }[] | null;
  payslips: { id: string; run_no: string; year: number; month: number; gross: number; net: number; status: string }[] | null;
};

export default async function EmployeePage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["hr.view", "payroll.run", "payroll.approve"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("employee_details", { p_employee: id });
  if (error || !data) notFound();
  const d = data as Details;
  const e = d.employee;
  const [{ data: departments }, { data: positions }, { data: locations }, { data: logins }, { data: components }, { data: leaveTypes }, { data: money }] = await Promise.all([
    supabase.from("departments").select("id, name").eq("is_active", true).order("name"),
    supabase.from("positions").select("id, name").eq("is_active", true).order("name"),
    supabase.from("locations").select("id, name").eq("is_active", true).neq("location_type", "vehicle").order("name"),
    supabase.rpc("list_user_logins"),
    supabase.from("pay_components").select("id, name, kind").eq("is_active", true).order("sort_order"),
    supabase.from("leave_types").select("id, name").eq("is_active", true).order("name"),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).in("kind", ["cash", "petty_cash", "bank"]).order("is_default", { ascending: false }),
  ]);
  const manage = can(access, "hr.manage");
  const runPay = can(access, "payroll.run");
  const typeLabel = Object.fromEntries(EMPLOYMENT_TYPES);
  const hidden = { employee_id: e.id };

  return (
    <>
      <Link href="/hr" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Employees</Link>
      <PageHeader title={e.full_name}
        description={[e.emp_no, e.position, e.department, typeLabel[e.employment_type], `joined ${formatDate(e.join_date)}`].filter(Boolean).join(" · ")}
        actions={<div className="flex flex-wrap items-center gap-2">
          {e.status !== "active" && <Badge tone="neutral" className="capitalize">{e.status}{e.end_date && ` ${formatDate(e.end_date)}`}</Badge>}
          {manage && e.status === "active" && (
            <FormDialog trigger="Request leave" triggerSize="md" title={`Leave — ${e.full_name}`} description="Sundays and public holidays are not counted."
              submitLabel="Save request" action={requestLeave} hidden={hidden}>
              <Field label="Type" htmlFor="lv-t"><Select id="lv-t" name="leave_type_id">{leaveTypes?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</Select></Field>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="From" htmlFor="lv-f" required><Input id="lv-f" name="from_date" type="date" required /></Field>
                <Field label="To" htmlFor="lv-to" hint="Leave empty for one day"><Input id="lv-to" name="to_date" type="date" /></Field>
              </div>
              <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="half_day" /> Half day</label>
              <Field label="Reason" htmlFor="lv-r"><Input id="lv-r" name="reason" /></Field>
            </FormDialog>
          )}
          {runPay && e.status === "active" && (
            <FormDialog trigger="Salary advance" triggerSize="md" title={`Salary advance — ${e.full_name}`} description="Recovered from the coming payrolls."
              submitLabel="Give advance" action={giveAdvance} hidden={hidden}>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Amount (Rs.)" htmlFor="ad-a" required><Input id="ad-a" name="amount" type="number" min={1} step="0.01" required /></Field>
                <Field label="Recover per month (Rs.)" htmlFor="ad-i" required><Input id="ad-i" name="installment" type="number" min={1} step="0.01" required /></Field>
              </div>
              <Field label="Paid from" htmlFor="ad-m"><Select id="ad-m" name="money_account_id">{money?.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
              <Field label="Reason" htmlFor="ad-r"><Input id="ad-r" name="reason" /></Field>
            </FormDialog>
          )}
          {manage && (
            <FormDialog trigger="Edit" triggerVariant="primary" triggerSize="md" title={`Edit ${e.full_name}`} submitLabel="Save" action={updateEmployee}
              hidden={{ id: e.id, emp_no: e.emp_no }} wide>
              <EmployeeFields e={e} departments={departments ?? []} positions={positions ?? []} locations={locations ?? []} logins={logins ?? []} canPay={d.can_see_pay} />
            </FormDialog>
          )}
        </div>} />

      <div className="grid gap-6 lg:grid-cols-3">
        <Card>
          <CardHeader title="Details" />
          <CardBody className="space-y-1.5 text-sm">
            <p><span className="text-muted">NIC:</span> {e.nic_no ?? "—"}</p>
            <p><span className="text-muted">Date of birth:</span> {e.date_of_birth ? formatDate(e.date_of_birth) : "—"}</p>
            <p><span className="text-muted">Phone:</span> {e.phone ? formatPhone(e.phone) : "—"}</p>
            <p><span className="text-muted">Email:</span> {e.email ?? "—"}</p>
            <p><span className="text-muted">Address:</span> {e.address ?? "—"}</p>
            <p><span className="text-muted">Emergency:</span> {e.emergency_contact ?? "—"}</p>
            <p><span className="text-muted">Works at:</span> {e.location ?? "—"}</p>
            <p><span className="text-muted">System login:</span> {e.login ?? "None"}</p>
            <p><span className="text-muted">EPF no.:</span> {e.epf_no ?? <span className="text-amber-700">Missing</span>}</p>
            <p><span className="text-muted">Bank:</span> {[e.bank_name, e.bank_branch, e.bank_account_no].filter(Boolean).join(", ") || "—"}</p>
            {d.can_see_pay && <p><span className="text-muted">Pay:</span> {e.pay_basis === "daily" ? `${formatLKR(e.daily_rate)} per day` : `${formatLKR(e.basic_salary)} a month`}
              {" · "}{[e.epf_applicable && "EPF", e.etf_applicable && "ETF", e.apit_applicable && "APIT"].filter(Boolean).join(", ") || "no statutory deductions"}</p>}
            {e.notes && <p className="text-muted">{e.notes}</p>}
          </CardBody>
        </Card>

        <Card>
          <CardHeader title="Leave this year" />
          <Table>
            <thead><tr><Th>Type</Th><Th className="text-right">Taken</Th><Th className="text-right">Left</Th></tr></thead>
            <tbody>{d.leave.map((l) => (
              <tr key={l.code}><Td>{l.name}{l.pending > 0 && <span className="block text-xs text-amber-700">{formatQty(l.pending)} waiting</span>}</Td>
                <Td className="num text-right">{formatQty(l.taken)}</Td><Td className="num text-right">{l.left === null ? "—" : formatQty(l.left)}</Td></tr>))}</tbody>
          </Table>
          <p className="px-5 py-3 text-xs text-muted">This month: {d.attendance_month.present} present · {d.attendance_month.half_day} half · {d.attendance_month.absent} absent ·
            {" "}{d.attendance_month.leave} leave · {formatQty(d.attendance_month.ot_hours)} h overtime</p>
        </Card>

        {d.can_see_pay && (
          <Card>
            <CardHeader title="Fixed allowances & deductions" description="Added to every payroll."
              actions={runPay && (
                <FormDialog trigger="Edit" title={`Fixed pay items — ${e.full_name}`} submitLabel="Save" action={savePayItems} hidden={hidden} wide>
                  <LineEditor name="lines" items={(components ?? []).map((c) => ({ id: c.id, name: `${c.name} (${c.kind === "earning" ? "+" : "−"})` }))}
                    itemLabel="Allowance / deduction" addLabel="Add" columns={[{ key: "amount", label: "Rs. a month", type: "number", step: "0.01", min: 0 }]}
                    initial={(d.pay_items ?? []).map((i) => ({ item_id: i.component_id, amount: String(Number(i.amount)) }))} />
                  <Field label="Reason" htmlFor="pi-r"><Input id="pi-r" name="reason" placeholder="e.g. Increment from January" /></Field>
                </FormDialog>
              )} />
            {(d.pay_items ?? []).length === 0 ? <p className="px-5 py-4 text-sm text-muted">None.</p> : (
              <ul className="divide-y divide-line text-sm">{d.pay_items!.map((i) => (
                <li key={i.component_id} className="flex justify-between px-5 py-2"><span>{i.name}</span>
                  <span className={`num ${i.kind === "deduction" ? "text-red-700" : ""}`}>{i.kind === "deduction" ? "− " : ""}{formatLKR(i.amount)}</span></li>))}</ul>
            )}
          </Card>
        )}

        <Card className="lg:col-span-2">
          <CardHeader title="Leave requests" />
          {d.leave_requests.length === 0 ? <p className="px-5 py-4 text-sm text-muted">None.</p> : (
            <Table>
              <thead><tr><Th>Request</Th><Th>Type</Th><Th>Dates</Th><Th className="text-right">Days</Th><Th>Status</Th><Th /></tr></thead>
              <tbody>{d.leave_requests.map((r) => { const st = statusBadge(LEAVE_STATUS, r.status); return (
                <tr key={r.id}><Td className="font-mono text-xs">{r.request_no}</Td><Td>{r.type}{r.reason && <span className="block text-xs text-muted">{r.reason}</span>}</Td>
                  <Td className="whitespace-nowrap">{formatDate(r.from)}{r.to !== r.from && ` – ${formatDate(r.to)}`}</Td>
                  <Td className="num text-right">{formatQty(r.days)}</Td><Td><Badge tone={st.tone}>{st.label}</Badge></Td>
                  <Td className="space-x-1 whitespace-nowrap text-right">
                    {manage && r.status === "pending" && <>
                      <ReasonDialog trigger="Approve" triggerVariant="primary" title="Approve leave" confirmLabel="Approve" reasonRequired={false} action={decideLeave}
                        hidden={{ request_id: r.id, decision: "approve", employee_id: e.id }} />
                      <ReasonDialog trigger="Reject" triggerVariant="dangerOutline" title="Reject leave" confirmLabel="Reject" confirmVariant="danger" action={decideLeave}
                        hidden={{ request_id: r.id, decision: "reject", employee_id: e.id }} />
                    </>}
                    {manage && r.status === "approved" && (
                      <ReasonDialog trigger="Cancel" triggerVariant="ghost" title="Cancel approved leave" description="The days are taken off the attendance record."
                        confirmLabel="Cancel leave" action={decideLeave} hidden={{ request_id: r.id, decision: "cancel", employee_id: e.id }} />
                    )}
                  </Td></tr>); })}</tbody>
            </Table>
          )}
        </Card>

        {d.can_see_pay && (
          <Card>
            <CardHeader title="Advances" />
            {(d.advances ?? []).length === 0 ? <p className="px-5 py-4 text-sm text-muted">None.</p> : (
              <ul className="divide-y divide-line text-sm">{d.advances!.map((a) => (
                <li key={a.advance_no} className="px-5 py-2"><span className="font-mono text-xs">{a.advance_no}</span> · {formatDate(a.date)} · {formatLKR(a.amount)}
                  <span className="block text-xs text-muted">{a.status === "settled" ? "Settled" : `${formatLKR(a.outstanding)} left · ${formatLKR(a.installment)} a month`}</span></li>))}</ul>
            )}
          </Card>
        )}

        {d.can_see_pay && (
          <Card className="lg:col-span-3">
            <CardHeader title="Payslips" />
            {(d.payslips ?? []).length === 0 ? <p className="px-5 py-4 text-sm text-muted">No payroll yet.</p> : (
              <Table>
                <thead><tr><Th>Month</Th><Th>Payroll</Th><Th className="text-right">Gross</Th><Th className="text-right">Net</Th><Th>Status</Th><Th /></tr></thead>
                <tbody>{d.payslips!.map((p) => { const st = statusBadge(PAYROLL_STATUS, p.status); return (
                  <tr key={p.id}><Td>{MONTHS[p.month - 1]} {p.year}</Td><Td className="font-mono text-xs">{p.run_no}</Td>
                    <Td className="num text-right">{formatLKR(p.gross)}</Td><Td className="num text-right font-medium">{formatLKR(p.net)}</Td>
                    <Td><Badge tone={st.tone}>{st.label}</Badge></Td>
                    <Td className="text-right"><a href={`/print/payslip/${p.id}`} target="_blank" rel="noreferrer" className="text-ola-700 hover:underline">Payslip</a></Td></tr>); })}</tbody>
              </Table>
            )}
          </Card>
        )}
      </div>
      <div className="mt-6"><DocumentsCard access={access} entityType="employee" entityId={id} categories={["employee"]} returnTo={`/hr/${id}`} /></div>
    </>
  );
}
