"use client";

import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { createUser } from "./actions";

export function CreateUserForm({
  roles,
  locations,
}: {
  roles: { id: string; name: string }[];
  locations: { id: string; code: string; name: string }[];
}) {
  return (
    <ActionForm action={createUser}>
      <Field label="Full name" htmlFor="full_name" required>
        <Input id="full_name" name="full_name" required autoComplete="off" />
      </Field>
      <Field label="Email" htmlFor="email" required>
        <Input id="email" name="email" type="email" required autoComplete="off" />
      </Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Mobile" htmlFor="phone" hint="e.g. 077 123 4567">
          <Input id="phone" name="phone" type="tel" inputMode="tel" />
        </Field>
        <Field label="Employee code" htmlFor="employee_code">
          <Input id="employee_code" name="employee_code" />
        </Field>
      </div>
      <Field label="Role" htmlFor="role_id" hint="More roles can be added afterwards.">
        <Select id="role_id" name="role_id" defaultValue="">
          <option value="">No role yet</option>
          {roles.map((r) => (
            <option key={r.id} value={r.id}>
              {r.name}
            </option>
          ))}
        </Select>
      </Field>
      <Field label="Default location" htmlFor="default_location_id">
        <Select id="default_location_id" name="default_location_id" defaultValue="">
          <option value="">None</option>
          {locations.map((l) => (
            <option key={l.id} value={l.id}>
              {l.name} ({l.code})
            </option>
          ))}
        </Select>
      </Field>
      <Field label="Temporary password" htmlFor="password" required hint="At least 10 characters with a letter and a number.">
        <Input id="password" name="password" type="text" required minLength={10} autoComplete="new-password" />
      </Field>
      <SubmitButton pendingText="Creating…">Create user</SubmitButton>
    </ActionForm>
  );
}
