"use client";

import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { formatPhone } from "@/lib/format";
import { assignRole, updateProfile } from "../actions";

type Location = { id: string; code: string; name: string };

export function ProfileForm({
  user,
  locations,
}: {
  user: { id: string; full_name: string; phone: string | null; employee_code: string | null; default_location_id: string | null; email: string | null };
  locations: Location[];
}) {
  return (
    <ActionForm action={updateProfile}>
      <input type="hidden" name="user_id" value={user.id} />
      <Field label="Full name" htmlFor="full_name" required>
        <Input id="full_name" name="full_name" defaultValue={user.full_name} required />
      </Field>
      <Field label="Email" htmlFor="email" hint="Sign-in email cannot be changed here.">
        <Input id="email" value={user.email ?? ""} disabled readOnly />
      </Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Mobile" htmlFor="phone" hint="e.g. 077 123 4567">
          <Input id="phone" name="phone" type="tel" defaultValue={user.phone ? formatPhone(user.phone) : ""} />
        </Field>
        <Field label="Employee code" htmlFor="employee_code">
          <Input id="employee_code" name="employee_code" defaultValue={user.employee_code ?? ""} />
        </Field>
      </div>
      <Field label="Default location" htmlFor="default_location_id">
        <Select id="default_location_id" name="default_location_id" defaultValue={user.default_location_id ?? ""}>
          <option value="">None</option>
          {locations.map((l) => (
            <option key={l.id} value={l.id}>
              {l.name} ({l.code})
            </option>
          ))}
        </Select>
      </Field>
      <Field label="Reason for change" htmlFor="profile-reason" hint="Optional. Recorded in the audit trail.">
        <Input id="profile-reason" name="reason" maxLength={500} />
      </Field>
      <SubmitButton>Save profile</SubmitButton>
    </ActionForm>
  );
}

export function AssignRoleForm({ userId, roles, locations }: { userId: string; roles: { id: string; name: string }[]; locations: Location[] }) {
  return (
    <ActionForm action={assignRole} resetOnSuccess>
      <input type="hidden" name="user_id" value={userId} />
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Add role" htmlFor="role_id" required>
          <Select id="role_id" name="role_id" required defaultValue="">
            <option value="" disabled>
              Choose a role
            </option>
            {roles.map((r) => (
              <option key={r.id} value={r.id}>
                {r.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Limited to location" htmlFor="location_id" hint="Optional, e.g. one water shop">
          <Select id="location_id" name="location_id" defaultValue="">
            <option value="">All locations</option>
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name} ({l.code})
              </option>
            ))}
          </Select>
        </Field>
      </div>
      <Field label="Reason" htmlFor="assign-reason">
        <Input id="assign-reason" name="reason" maxLength={500} />
      </Field>
      <SubmitButton variant="secondary">Assign role</SubmitButton>
    </ActionForm>
  );
}
