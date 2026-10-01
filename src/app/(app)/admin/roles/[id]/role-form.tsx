"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { saveRole } from "../actions";

type Permission = { code: string; module: string; description: string };

export function RoleForm({
  role,
  permissions,
  granted,
}: {
  role: { id: string; code: string; name: string; description: string | null; is_system: boolean } | null;
  permissions: Permission[];
  granted: string[];
}) {
  const [selected, setSelected] = useState<Set<string>>(new Set(granted));
  const modules = useMemo(() => {
    const map = new Map<string, Permission[]>();
    permissions.forEach((p) => map.set(p.module, [...(map.get(p.module) ?? []), p]));
    return [...map.entries()];
  }, [permissions]);

  const toggle = (code: string, on: boolean) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (on) next.add(code);
      else next.delete(code);
      return next;
    });

  return (
    <ActionForm action={saveRole}>
      <input type="hidden" name="role_id" value={role?.id ?? ""} />
      <input type="hidden" name="code" value={role?.code ?? ""} />
      {[...selected].map((c) => (
        <input key={c} type="hidden" name="permissions" value={c} />
      ))}
      <div className="grid gap-4 md:grid-cols-2">
        <Field label="Role name" htmlFor="name" required>
          <Input id="name" name="name" defaultValue={role?.name ?? ""} required maxLength={80} />
        </Field>
        <Field label="Description" htmlFor="description">
          <Input id="description" name="description" defaultValue={role?.description ?? ""} maxLength={300} />
        </Field>
      </div>

      <div>
        <div className="mb-2 flex items-center justify-between">
          <p className="text-sm font-medium text-navy-800">Permissions</p>
          <p className="num text-sm text-muted">
            {selected.size} of {permissions.length} selected
          </p>
        </div>
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {modules.map(([module, perms]) => {
            const all = perms.every((p) => selected.has(p.code));
            return (
              <fieldset key={module} className="rounded-lg border border-line p-3">
                <legend className="flex w-full items-center justify-between px-1">
                  <span className="text-sm font-semibold text-navy-900">{module}</span>
                </legend>
                <label className="mb-1 flex items-center gap-2 text-xs text-muted">
                  <input type="checkbox" checked={all} onChange={(e) => perms.forEach((p) => toggle(p.code, e.target.checked))} />
                  Select all
                </label>
                <div className="space-y-1.5">
                  {perms.map((p) => (
                    <label key={p.code} className="flex items-start gap-2 text-sm">
                      <input
                        type="checkbox"
                        className="mt-0.5 h-4 w-4"
                        checked={selected.has(p.code)}
                        onChange={(e) => toggle(p.code, e.target.checked)}
                      />
                      <span>
                        {p.description}
                        <span className="block font-mono text-[11px] text-muted">{p.code}</span>
                      </span>
                    </label>
                  ))}
                </div>
              </fieldset>
            );
          })}
        </div>
      </div>

      {role && (
        <Field label="Reason for change" htmlFor="reason" required hint="Recorded in the audit trail.">
          <Input id="reason" name="reason" required maxLength={500} />
        </Field>
      )}
      <SubmitButton>{role ? "Save changes" : "Create role"}</SubmitButton>
    </ActionForm>
  );
}
