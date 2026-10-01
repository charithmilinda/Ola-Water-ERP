import type { Metadata } from "next";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { changeSetting } from "./actions";

export const metadata: Metadata = { title: "System Settings" };

type Setting = {
  key: string;
  module: string;
  label: string;
  description: string | null;
  value_type: "text" | "number" | "integer" | "money" | "percent" | "boolean" | "choice";
  choices: string[] | null;
  current_value: unknown;
  current_from: string | null;
  scheduled_value: unknown;
  scheduled_from: string | null;
};

function display(s: Setting, v: unknown): string {
  if (v === null || v === undefined) return "Not set";
  if (s.value_type === "money") return formatLKR(Number(v));
  if (s.value_type === "percent") return `${v}%`;
  if (s.value_type === "boolean") return v ? "Yes" : "No";
  if (s.value_type === "choice") return String(v).replace(/_/g, " ");
  if (v === "") return "Not set";
  return String(v);
}

function ValueInput({ s }: { s: Setting }) {
  const id = `value-${s.key}`;
  const current = s.current_value ?? "";
  if (s.value_type === "choice")
    return (
      <Select id={id} name="value" defaultValue={String(current)}>
        {s.choices?.map((c) => (
          <option key={c} value={c}>
            {c.replace(/_/g, " ")}
          </option>
        ))}
      </Select>
    );
  if (s.value_type === "boolean")
    return (
      <Select id={id} name="value" defaultValue={String(current)}>
        <option value="true">Yes</option>
        <option value="false">No</option>
      </Select>
    );
  if (s.value_type === "text") return <Input id={id} name="value" defaultValue={String(current)} maxLength={300} />;
  return (
    <Input
      id={id}
      name="value"
      type="number"
      inputMode="decimal"
      step={s.value_type === "integer" ? 1 : "any"}
      min={s.value_type === "percent" || s.value_type === "money" ? 0 : undefined}
      max={s.value_type === "percent" ? 100 : undefined}
      defaultValue={String(current)}
      required
    />
  );
}

export default async function SettingsPage() {
  await requirePermission("settings.manage");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("list_settings");
  const settings = (data ?? []) as Setting[];
  const groups = new Map<string, Setting[]>();
  settings.forEach((s) => groups.set(s.module, [...(groups.get(s.module) ?? []), s]));
  const today = todayISO();

  return (
    <>
      <PageHeader
        title="System Settings"
        description="Business rules and thresholds. Changes take effect from a chosen date and the full history is kept — past values are never overwritten."
      />
      {error && <Alert tone="error" className="mb-4">{error.message}</Alert>}
      <div className="space-y-6">
        {[...groups.entries()].map(([module, items]) => (
          <Card key={module}>
            <CardHeader title={module} />
            <ul className="divide-y divide-line">
              {items.map((s) => (
                <li key={s.key} className="flex flex-wrap items-center justify-between gap-4 px-5 py-4">
                  <div className="min-w-60 flex-1">
                    <p className="text-sm font-medium text-navy-900">{s.label}</p>
                    {s.description && <p className="text-xs text-muted">{s.description}</p>}
                  </div>
                  <div className="min-w-48 text-sm">
                    <p className="num font-medium capitalize text-navy-900">{display(s, s.current_value)}</p>
                    {s.current_from && <p className="text-xs text-muted">since {formatDate(s.current_from)}</p>}
                    {s.scheduled_from && (
                      <Badge tone="amber" className="mt-1">
                        {display(s, s.scheduled_value)} from {formatDate(s.scheduled_from)}
                      </Badge>
                    )}
                  </div>
                  <ReasonDialog
                    trigger="Change"
                    title={s.label}
                    description={s.description ?? undefined}
                    confirmLabel="Save change"
                    action={changeSetting}
                    hidden={{ key: s.key }}
                  >
                    <Field label="New value" htmlFor={`value-${s.key}`} required>
                      <ValueInput s={s} />
                    </Field>
                    <Field label="Takes effect from" htmlFor={`eff-${s.key}`} required hint="Today or a future date.">
                      <Input id={`eff-${s.key}`} name="effective_from" type="date" min={today} defaultValue={today} required />
                    </Field>
                  </ReasonDialog>
                </li>
              ))}
            </ul>
          </Card>
        ))}
      </div>
    </>
  );
}
