import type { Metadata } from "next";
import Link from "next/link";
import { IdCard, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatPhone } from "@/lib/format";
import { EMPLOYMENT_TYPES } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { EmployeeFields } from "./employee-fields";
import { createEmployee, saveDepartment, savePosition } from "./actions";

export const metadata: Metadata = { title: "Employees" };

type Row = { id: string; emp_no: string; full_name: string; phone: string | null; employment_type: string; join_date: string; status: string;
  pay_basis: string; basic_salary?: number; daily_rate?: number; epf_no: string | null;
  department: { name: string } | null; position: { name: string } | null; login: { full_name: string } | null };

export default async function EmployeesPage({ searchParams }: { searchParams: Promise<{ show?: string }> }) {
  const access = await requirePermission(["hr.view", "payroll.run", "payroll.approve"]);
  const show = (await searchParams).show ?? "active";
  const canPay = can(access, ["payroll.run", "payroll.approve"]);
  const supabase = await createClient();
  let q = supabase.from("employees").select(`id, emp_no, full_name, phone, employment_type, join_date, status, pay_basis, epf_no${canPay ? ", basic_salary, daily_rate" : ""}, department:departments(name), position:positions(name)`)
    .order("emp_no");
  if (show !== "all") q = q.eq("status", "active");
  const [{ data }, { data: departments }, { data: positions }, { data: locations }, { data: logins }, { data: overview }] = await Promise.all([
    q,
    supabase.from("departments").select("id, name").eq("is_active", true).order("name"),
    supabase.from("positions").select("id, name").eq("is_active", true).order("name"),
    supabase.from("locations").select("id, name").eq("is_active", true).neq("location_type", "vehicle").order("name"),
    supabase.rpc("list_user_logins"),
    can(access, "hr.view") ? supabase.rpc("hr_overview") : Promise.resolve({ data: null }),
  ]);
  const rows = (data ?? []) as unknown as Row[];
  const o = overview as { headcount: number; pending_leave: number; on_leave_today: { name: string; type: string }[]; advances_outstanding: number;
    without_epf_no: number; attendance_today: number } | null;
  const manage = can(access, "hr.manage");
  const typeLabel = Object.fromEntries(EMPLOYMENT_TYPES);

  return (
    <>
      <PageHeader title="Employees" description="Staff records, contracts and bank details. Salary details are visible only to payroll."
        actions={manage && <>
          <FormDialog trigger="Departments & positions" triggerSize="md" title="Add a department" submitLabel="Add department" action={saveDepartment}>
            <p className="text-sm text-muted">{departments?.map((d) => d.name).join(" · ")}</p>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Code" htmlFor="dp-c" required><Input id="dp-c" name="code" required placeholder="MAINT" /></Field>
              <Field label="Name" htmlFor="dp-n" required className="sm:col-span-2"><Input id="dp-n" name="name" required /></Field>
            </div>
          </FormDialog>
          <FormDialog trigger="Add position" triggerSize="md" title="Add a position" submitLabel="Add position" action={savePosition}>
            <p className="text-sm text-muted">{positions?.map((d) => d.name).join(" · ") || "None yet"}</p>
            <Field label="Position" htmlFor="ps-n" required><Input id="ps-n" name="name" required placeholder="Lorry driver" /></Field>
            <Field label="Department" htmlFor="ps-d"><Select id="ps-d" name="department_id"><option value="">—</option>{departments?.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</Select></Field>
          </FormDialog>
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New employee</>} triggerVariant="primary" triggerSize="md" title="New employee" submitLabel="Add employee"
            action={createEmployee} wide>
            <EmployeeFields departments={departments ?? []} positions={positions ?? []} locations={locations ?? []} logins={logins ?? []} canPay={canPay} />
          </FormDialog>
        </>} />

      {o && (
        <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Stat label="Active staff" value={o.headcount} hint={o.without_epf_no ? `${o.without_epf_no} without an EPF number` : undefined} />
          <Stat label="On leave today" value={o.on_leave_today.length} hint={o.on_leave_today.map((x) => x.name).join(", ") || undefined} />
          <Stat label="Leave requests waiting" value={o.pending_leave} />
          <Stat label="Advances outstanding" value={formatLKR(o.advances_outstanding)} hint={`Attendance marked today: ${o.attendance_today}`} />
        </div>
      )}

      <Card>
        <CardHeader title={show === "all" ? "All employees" : "Active employees"} actions={
          <Link href={show === "all" ? "/hr" : "/hr?show=all"} className={buttonVariants({ variant: "secondary", size: "sm" })}>{show === "all" ? "Active only" : "Show former staff"}</Link>} />
        {rows.length === 0 ? <EmptyState icon={IdCard} title="No employees yet" description={manage ? "Add staff with New employee." : undefined} /> : (
          <Table>
            <thead><tr><Th>Employee</Th><Th>Department</Th><Th>Employment</Th><Th>Joined</Th><Th>EPF no.</Th>{canPay && <Th className="text-right">Pay</Th>}</tr></thead>
            <tbody>{rows.map((e) => (
              <tr key={e.id} className={e.status === "active" ? "hover:bg-ola-50/40" : "opacity-60"}>
                <Td><Link href={`/hr/${e.id}`} className="font-medium text-ola-700 hover:underline">{e.full_name}</Link>
                  <span className="block text-xs text-muted">{e.emp_no}{e.phone && ` · ${formatPhone(e.phone)}`}</span>
                  {e.status !== "active" && <Badge tone="neutral" className="mt-1 capitalize">{e.status}</Badge>}</Td>
                <Td>{e.department?.name ?? "—"}<span className="block text-xs text-muted">{e.position?.name}</span></Td>
                <Td>{typeLabel[e.employment_type] ?? e.employment_type}</Td>
                <Td>{formatDate(e.join_date)}</Td>
                <Td>{e.epf_no ?? <span className="text-amber-700">Missing</span>}</Td>
                {canPay && <Td className="num text-right">{e.pay_basis === "daily" ? `${formatLKR(e.daily_rate)} / day` : formatLKR(e.basic_salary)}</Td>}
              </tr>
            ))}</tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
