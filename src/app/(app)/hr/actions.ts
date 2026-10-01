"use server";

import { redirect } from "next/navigation";
import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";
import { parseLines, num } from "@/lib/lines";

const P = (id?: string) => ["/hr", "/hr/attendance", "/payroll", ...(id ? [`/hr/${id}`] : [])];

function employeePayload(f: FormData) {
  const b = (k: string) => f.get(k) === "on";
  return {
    emp_no: str(f, "emp_no"), full_name: str(f, "full_name"), name_with_initials: str(f, "name_with_initials"), nic_no: str(f, "nic_no"),
    date_of_birth: str(f, "date_of_birth") || null, gender: str(f, "gender") || null, phone: str(f, "phone"), email: str(f, "email"),
    address: str(f, "address"), emergency_contact: str(f, "emergency_contact"), department_id: str(f, "department_id") || null,
    position_id: str(f, "position_id") || null, location_id: str(f, "location_id") || null, employment_type: str(f, "employment_type"),
    join_date: str(f, "join_date") || null, end_date: str(f, "end_date") || null, status: str(f, "status") || "active",
    profile_id: str(f, "profile_id") || null, epf_no: str(f, "epf_no"), pay_basis: str(f, "pay_basis") || "monthly",
    basic_salary: num(str(f, "basic_salary")), daily_rate: num(str(f, "daily_rate")),
    epf_applicable: f.has("pay_basis") ? b("epf_applicable") : undefined, etf_applicable: f.has("pay_basis") ? b("etf_applicable") : undefined,
    apit_applicable: f.has("pay_basis") ? b("apit_applicable") : undefined,
    bank_name: str(f, "bank_name"), bank_branch: str(f, "bank_branch"), bank_account_no: str(f, "bank_account_no"), notes: str(f, "notes"),
  };
}

export async function createEmployee(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<string>("save_employee", { p_id: null, p: employeePayload(f), p_reason: "New employee" }, "Employee added.", P());
  if (!res.ok) return res;
  redirect(`/hr/${res.data}`);
}

export async function updateEmployee(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id");
  return runRpc("save_employee", { p_id: id, p: employeePayload(f), p_reason: str(f, "reason") || null }, "Saved.", P(id));
}

export async function saveDepartment(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_department", { p_id: null, p: { code: str(f, "code"), name: str(f, "name") }, p_reason: "New department" }, "Department added.", P());
}

export async function savePosition(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_position", { p_id: null, p: { name: str(f, "name"), department_id: str(f, "department_id") || null }, p_reason: "New position" },
    "Position added.", P());
}

export async function savePayItems(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "employee_id");
  const lines = parseLines(f.get("lines")).map((l) => ({ component_id: l.item_id, amount: num(l.amount) }));
  return runRpc<number>("set_employee_pay_items", { p_employee: id, p_lines: lines, p_reason: str(f, "reason") || null },
    (n) => `${n} fixed allowance(s) / deduction(s) saved. They apply from the next payroll you prepare or recalculate.`, P(id));
}

export async function requestLeave(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "employee_id");
  return runRpc<{ request_no: string; days: number; balance_after: number | null }>("request_leave", {
    p: { employee_id: id, leave_type_id: str(f, "leave_type_id"), from_date: str(f, "from_date"), to_date: str(f, "to_date") || null,
      half_day: f.get("half_day") === "on", reason: str(f, "reason") },
  }, (d) => `${d.request_no}: ${d.days} day(s) requested.${d.balance_after !== null ? ` ${d.balance_after} day(s) would be left.` : ""}`, P(id));
}

export async function decideLeave(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = str(f, "decision");
  return runRpc<{ status: string }>("decide_leave", { p_id: str(f, "request_id"), p_decision: d, p_note: str(f, "reason") },
    (r) => `Leave ${r.status}.`, P(str(f, "employee_id") || undefined));
}

export async function giveAdvance(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "employee_id");
  return runRpc<{ advance_no: string }>("give_salary_advance", {
    p: { employee_id: id, amount: num(str(f, "amount")), installment: num(str(f, "installment")), money_account_id: str(f, "money_account_id"),
      reason: str(f, "reason") },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Advance ${d.advance_no} given. It is recovered from the coming payrolls.`, [...P(id), "/accounting"]);
}

/** Fields per employee: st:<id>, in:<id>, out:<id>, ot:<id>, note:<id>. */
export async function saveAttendance(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const date = str(f, "work_date");
  const ids = [...new Set([...f.keys()].filter((k) => k.startsWith("st:")).map((k) => k.slice(3)))];
  const rows = ids.map((id) => ({ employee_id: id, status: str(f, `st:${id}`) || null, time_in: str(f, `in:${id}`) || null, time_out: str(f, `out:${id}`) || null,
    ot_hours: Number(str(f, `ot:${id}`) || 0), notes: str(f, `note:${id}`) || null })).filter((r) => r.status);
  return runRpc<number>("record_attendance", { p_date: date, p_rows: rows }, (n) => `Attendance saved for ${n} employee(s).`, P());
}

export async function addHoliday(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_holiday", { p_date: str(f, "holiday_date"), p_name: str(f, "name") }, "Holiday added.", P());
}
