import type { Metadata } from "next";
import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatQty, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Alert } from "@/components/ui/alert";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { addHoliday, decideLeave, requestLeave, saveAttendance } from "../actions";

export const metadata: Metadata = { title: "Attendance & Leave" };

type Sheet = { employee_id: string; emp_no: string; full_name: string; department: string | null; status: string | null; leave_type: string | null;
  time_in: string | null; time_out: string | null; ot_hours: number; notes: string | null; locked: boolean };

const shift = (iso: string, days: number) => {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
};

export default async function AttendancePage({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
  const access = await requirePermission("hr.view");
  const today = todayISO();
  const raw = (await searchParams).date;
  const date = raw && /^\d{4}-\d{2}-\d{2}$/.test(raw) && raw <= today ? raw : today;
  const supabase = await createClient();
  const [{ data: sheet }, { data: pending }, { data: holidays }, { data: employees }, { data: leaveTypes }] = await Promise.all([
    supabase.rpc("attendance_sheet", { p_date: date }),
    supabase.from("leave_requests").select("id, request_no, from_date, to_date, days, reason, employee:employees(id, full_name), type:leave_types(name)")
      .eq("status", "pending").order("from_date"),
    supabase.from("holidays").select("holiday_date, name").gte("holiday_date", `${today.slice(0, 4)}-01-01`).order("holiday_date"),
    supabase.from("employees").select("id, full_name").eq("status", "active").order("full_name"),
    supabase.from("leave_types").select("id, name").eq("is_active", true).order("name"),
  ]);
  const rows = (sheet ?? []) as Sheet[];
  const manage = can(access, "hr.manage");
  const locked = rows[0]?.locked ?? false;
  const holiday = holidays?.find((h) => h.holiday_date === date);
  const sunday = new Date(`${date}T00:00:00Z`).getUTCDay() === 0;
  type Pending = { id: string; request_no: string; from_date: string; to_date: string; days: number; reason: string | null;
    employee: { id: string; full_name: string } | null; type: { name: string } | null };

  return (
    <>
      <PageHeader title="Attendance & Leave" description="Mark attendance each day; approved leave fills itself in. Absent days and no-pay leave reduce pay; overtime is paid at the payroll."
        actions={manage && <>
          <FormDialog trigger="New leave request" triggerSize="md" title="Leave request" description="Sundays and public holidays are not counted." submitLabel="Save request"
            action={requestLeave}>
            <Field label="Employee" htmlFor="nl-e"><Select id="nl-e" name="employee_id">{employees?.map((x) => <option key={x.id} value={x.id}>{x.full_name}</option>)}</Select></Field>
            <Field label="Type" htmlFor="nl-t"><Select id="nl-t" name="leave_type_id">{leaveTypes?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</Select></Field>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="From" htmlFor="nl-f" required><Input id="nl-f" name="from_date" type="date" required /></Field>
              <Field label="To" htmlFor="nl-to"><Input id="nl-to" name="to_date" type="date" /></Field>
            </div>
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="half_day" /> Half day</label>
            <Field label="Reason" htmlFor="nl-r"><Input id="nl-r" name="reason" /></Field>
          </FormDialog>
          <FormDialog trigger="Public holidays" triggerSize="md" title="Public holidays" description="Holidays are skipped when leave days are counted." submitLabel="Add holiday"
            action={addHoliday}>
            <ul className="max-h-48 overflow-y-auto text-sm">{(holidays ?? []).map((h) => <li key={h.holiday_date}>{formatDate(h.holiday_date)} — {h.name}</li>)}
              {(holidays ?? []).length === 0 && <li className="text-muted">None entered for this year.</li>}</ul>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Date" htmlFor="hd-d" required><Input id="hd-d" name="holiday_date" type="date" required /></Field>
              <Field label="Name" htmlFor="hd-n" required><Input id="hd-n" name="name" required placeholder="e.g. Vesak Full Moon Poya Day" /></Field>
            </div>
          </FormDialog>
        </>} />

      {(pending ?? []).length > 0 && (
        <Card className="mb-6">
          <CardHeader title="Leave waiting for approval" />
          <Table>
            <thead><tr><Th>Employee</Th><Th>Type</Th><Th>Dates</Th><Th className="text-right">Days</Th><Th /></tr></thead>
            <tbody>{((pending ?? []) as unknown as Pending[]).map((r) => (
              <tr key={r.id}><Td><Link href={`/hr/${r.employee?.id}`} className="font-medium text-ola-700 hover:underline">{r.employee?.full_name}</Link>
                <span className="block font-mono text-xs text-muted">{r.request_no}</span></Td>
                <Td>{r.type?.name}{r.reason && <span className="block text-xs text-muted">{r.reason}</span>}</Td>
                <Td className="whitespace-nowrap">{formatDate(r.from_date)}{r.to_date !== r.from_date && ` – ${formatDate(r.to_date)}`}</Td>
                <Td className="num text-right">{formatQty(r.days)}</Td>
                <Td className="space-x-1 whitespace-nowrap text-right">{manage && <>
                  <ReasonDialog trigger="Approve" triggerVariant="primary" title="Approve leave" confirmLabel="Approve" reasonRequired={false} action={decideLeave}
                    hidden={{ request_id: r.id, decision: "approve" }} />
                  <ReasonDialog trigger="Reject" triggerVariant="dangerOutline" title="Reject leave" confirmLabel="Reject" confirmVariant="danger" action={decideLeave}
                    hidden={{ request_id: r.id, decision: "reject" }} />
                </>}</Td></tr>))}</tbody>
          </Table>
        </Card>
      )}

      <Card>
        <CardHeader title={`Attendance — ${formatDate(date)}`} description={holiday ? `Public holiday: ${holiday.name}` : sunday ? "Sunday" : undefined}
          actions={<div className="flex items-center gap-1">
            <Link href={`/hr/attendance?date=${shift(date, -1)}`} className={buttonVariants({ variant: "secondary", size: "sm" })} aria-label="Previous day"><ChevronLeft className="h-4 w-4" /></Link>
            <form className="flex items-center gap-1"><Input type="date" name="date" defaultValue={date} max={today} className="h-8 w-40" aria-label="Date" />
              <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Go</button></form>
            {date < today && <Link href={`/hr/attendance?date=${shift(date, 1)}`} className={buttonVariants({ variant: "secondary", size: "sm" })} aria-label="Next day"><ChevronRight className="h-4 w-4" /></Link>}
          </div>} />
        {locked && <Alert tone="info" className="m-4">The payroll for this month is approved — attendance can no longer change.</Alert>}
        {rows.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No employees on this date.</p> : (
          <ActionForm key={date} action={saveAttendance} className="space-y-0">
            <input type="hidden" name="work_date" value={date} />
            <Table>
              <thead><tr><Th>Employee</Th><Th>Status</Th><Th>In</Th><Th>Out</Th><Th>OT hours</Th><Th>Note</Th></tr></thead>
              <tbody>{rows.map((r) => (
                <tr key={r.employee_id}>
                  <Td><span className="font-medium">{r.full_name}</span><span className="block text-xs text-muted">{r.emp_no}{r.department && ` · ${r.department}`}</span></Td>
                  <Td>{r.status === "leave" ? <span className="text-sm text-ola-800">On leave ({r.leave_type})</span> : (
                    <Select aria-label={`${r.full_name} status`} name={`st:${r.employee_id}`} defaultValue={r.status ?? ""} disabled={!manage || locked} className="w-36">
                      <option value="">Not marked</option><option value="present">Present</option><option value="half_day">Half day</option>
                      <option value="absent">Absent</option><option value="holiday">Holiday</option><option value="off">Day off</option></Select>)}</Td>
                  <Td><Input aria-label={`${r.full_name} time in`} type="time" name={`in:${r.employee_id}`} defaultValue={r.time_in?.slice(0, 5) ?? ""} disabled={!manage || locked || r.status === "leave"} className="w-28" /></Td>
                  <Td><Input aria-label={`${r.full_name} time out`} type="time" name={`out:${r.employee_id}`} defaultValue={r.time_out?.slice(0, 5) ?? ""} disabled={!manage || locked || r.status === "leave"} className="w-28" /></Td>
                  <Td><Input aria-label={`${r.full_name} overtime`} type="number" min={0} max={24} step="0.5" name={`ot:${r.employee_id}`} defaultValue={Number(r.ot_hours) || ""} disabled={!manage || locked || r.status === "leave"} className="w-20" /></Td>
                  <Td><Input aria-label={`${r.full_name} note`} name={`note:${r.employee_id}`} defaultValue={r.notes ?? ""} disabled={!manage || locked || r.status === "leave"} /></Td>
                </tr>))}</tbody>
            </Table>
            {manage && !locked && <div className="p-4"><SubmitButton>Save attendance</SubmitButton></div>}
          </ActionForm>
        )}
      </Card>
    </>
  );
}
