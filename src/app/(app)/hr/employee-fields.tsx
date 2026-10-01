import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { EMPLOYMENT_TYPES } from "@/lib/labels";

type Opt = { id: string; name: string };
export type Employee = {
  id: string; emp_no: string; full_name: string; name_with_initials: string | null; nic_no: string | null; date_of_birth: string | null; gender: string | null;
  phone: string | null; email: string | null; address: string | null; emergency_contact: string | null; department_id: string | null; position_id: string | null;
  location_id: string | null; employment_type: string; join_date: string; end_date: string | null; status: string; profile_id: string | null; epf_no: string | null;
  pay_basis: string; basic_salary?: number; daily_rate?: number; epf_applicable: boolean; etf_applicable: boolean; apit_applicable: boolean;
  bank_name: string | null; bank_branch: string | null; bank_account_no: string | null; notes: string | null;
};

export function EmployeeFields({ e, departments, positions, locations, logins, canPay }: {
  e?: Employee; departments: Opt[]; positions: Opt[]; locations: Opt[]; logins: { id: string; full_name: string; email: string | null }[]; canPay: boolean;
}) {
  const k = e?.id ?? "new";
  return (
    <>
      <p className="text-sm font-semibold text-navy-800">Personal</p>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Employee no." htmlFor={`en-${k}`} required><Input id={`en-${k}`} name="emp_no" defaultValue={e?.emp_no} required disabled={!!e} placeholder="E001" /></Field>
        <Field label="Full name" htmlFor={`fn-${k}`} required className="sm:col-span-2"><Input id={`fn-${k}`} name="full_name" defaultValue={e?.full_name} required /></Field>
        <Field label="Name with initials" htmlFor={`ni-${k}`}><Input id={`ni-${k}`} name="name_with_initials" defaultValue={e?.name_with_initials ?? ""} /></Field>
        <Field label="NIC no." htmlFor={`nic-${k}`}><Input id={`nic-${k}`} name="nic_no" defaultValue={e?.nic_no ?? ""} /></Field>
        <Field label="Date of birth" htmlFor={`dob-${k}`}><Input id={`dob-${k}`} name="date_of_birth" type="date" defaultValue={e?.date_of_birth ?? ""} /></Field>
        <Field label="Gender" htmlFor={`g-${k}`}><Select id={`g-${k}`} name="gender" defaultValue={e?.gender ?? ""}>
          <option value="">—</option><option value="male">Male</option><option value="female">Female</option><option value="other">Other</option></Select></Field>
        <Field label="Phone" htmlFor={`ph-${k}`}><Input id={`ph-${k}`} name="phone" defaultValue={e?.phone ?? ""} /></Field>
        <Field label="Email" htmlFor={`em-${k}`}><Input id={`em-${k}`} name="email" type="email" defaultValue={e?.email ?? ""} /></Field>
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Address" htmlFor={`ad-${k}`}><Input id={`ad-${k}`} name="address" defaultValue={e?.address ?? ""} /></Field>
        <Field label="Emergency contact" htmlFor={`ec-${k}`}><Input id={`ec-${k}`} name="emergency_contact" defaultValue={e?.emergency_contact ?? ""} placeholder="Name and phone" /></Field>
      </div>

      <p className="text-sm font-semibold text-navy-800">Job</p>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Department" htmlFor={`d-${k}`}><Select id={`d-${k}`} name="department_id" defaultValue={e?.department_id ?? ""}>
          <option value="">—</option>{departments.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="Position" htmlFor={`p-${k}`}><Select id={`p-${k}`} name="position_id" defaultValue={e?.position_id ?? ""}>
          <option value="">—</option>{positions.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="Works at" htmlFor={`l-${k}`}><Select id={`l-${k}`} name="location_id" defaultValue={e?.location_id ?? ""}>
          <option value="">—</option>{locations.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="Employment" htmlFor={`et-${k}`}><Select id={`et-${k}`} name="employment_type" defaultValue={e?.employment_type ?? "permanent"}>
          {EMPLOYMENT_TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
        <Field label="Joined" htmlFor={`jd-${k}`} required><Input id={`jd-${k}`} name="join_date" type="date" defaultValue={e?.join_date ?? ""} required /></Field>
        <Field label="System login" htmlFor={`pr-${k}`} hint="Links drivers and staff to their user"><Select id={`pr-${k}`} name="profile_id" defaultValue={e?.profile_id ?? ""}>
          <option value="">None</option>{logins.map((x) => <option key={x.id} value={x.id}>{x.full_name}{x.email ? ` (${x.email})` : ""}</option>)}</Select></Field>
      </div>
      {e && (
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Status" htmlFor={`s-${k}`}><Select id={`s-${k}`} name="status" defaultValue={e.status}>
            <option value="active">Active</option><option value="resigned">Resigned</option><option value="terminated">Terminated</option></Select></Field>
          <Field label="Last working day" htmlFor={`ed-${k}`} hint="Needed when someone leaves"><Input id={`ed-${k}`} name="end_date" type="date" defaultValue={e.end_date ?? ""} /></Field>
        </div>
      )}

      <p className="text-sm font-semibold text-navy-800">Pay and bank</p>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="EPF no." htmlFor={`epf-${k}`}><Input id={`epf-${k}`} name="epf_no" defaultValue={e?.epf_no ?? ""} /></Field>
        <Field label="Bank" htmlFor={`bn-${k}`}><Input id={`bn-${k}`} name="bank_name" defaultValue={e?.bank_name ?? ""} /></Field>
        <Field label="Branch" htmlFor={`bb-${k}`}><Input id={`bb-${k}`} name="bank_branch" defaultValue={e?.bank_branch ?? ""} /></Field>
        <Field label="Account no." htmlFor={`ba-${k}`}><Input id={`ba-${k}`} name="bank_account_no" defaultValue={e?.bank_account_no ?? ""} /></Field>
      </div>
      {canPay ? (
        <>
          <div className="grid gap-4 sm:grid-cols-3">
            <Field label="Paid" htmlFor={`pb-${k}`}><Select id={`pb-${k}`} name="pay_basis" defaultValue={e?.pay_basis ?? "monthly"}>
              <option value="monthly">Monthly salary</option><option value="daily">Daily wage</option></Select></Field>
            <Field label="Monthly basic (Rs.)" htmlFor={`bs-${k}`}><Input id={`bs-${k}`} name="basic_salary" type="number" min={0} step="0.01" defaultValue={e?.basic_salary ?? 0} /></Field>
            <Field label="Daily rate (Rs.)" htmlFor={`dr-${k}`} hint="Daily-paid workers only"><Input id={`dr-${k}`} name="daily_rate" type="number" min={0} step="0.01" defaultValue={e?.daily_rate ?? 0} /></Field>
          </div>
          <div className="flex flex-wrap gap-6 text-sm">
            <label className="flex items-center gap-2"><input type="checkbox" name="epf_applicable" defaultChecked={e?.epf_applicable ?? true} /> EPF</label>
            <label className="flex items-center gap-2"><input type="checkbox" name="etf_applicable" defaultChecked={e?.etf_applicable ?? true} /> ETF</label>
            <label className="flex items-center gap-2"><input type="checkbox" name="apit_applicable" defaultChecked={e?.apit_applicable ?? true} /> APIT (primary employment)</label>
          </div>
        </>
      ) : <p className="text-xs text-muted">Salary details are entered by payroll staff.</p>}
      <Field label="Notes" htmlFor={`no-${k}`}><Textarea id={`no-${k}`} name="notes" defaultValue={e?.notes ?? ""} /></Field>
      {e && <Field label="Reason for change" htmlFor={`r-${k}`}><Input id={`r-${k}`} name="reason" /></Field>}
    </>
  );
}
