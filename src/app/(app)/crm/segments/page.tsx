import type { Metadata } from "next";
import { Plus, Users } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { CUSTOMER_TYPES } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { CrmTabs } from "../crm-tabs";
import { saveSegment } from "../actions";

export const metadata: Metadata = { title: "Customer segments" };

type Rules = { customer_types?: string[]; route_ids?: string[]; sales_rep_ids?: string[]; bottle_models?: string[]; cities?: string[]; min_days_since_order?: number;
  max_days_since_order?: number; has_overdue?: boolean; created_after?: string; min_monthly_sales?: number };
type Seg = { id: string; name: string; description: string | null; rules: Rules };
type Opt = { id: string; name: string };

function SegmentFields({ s, routes, reps }: { s?: Seg; routes: Opt[]; reps: Opt[] }) {
  const r = s?.rules ?? {};
  const k = s?.id ?? "new";
  const checks = (name: string, opts: readonly (readonly [string, string])[], sel: string[] = []) => (
    <div className="flex flex-wrap gap-x-4 gap-y-1 text-sm">{opts.map(([v, l]) => <label key={v} className="flex items-center gap-1.5">
      <input type="checkbox" name={name} value={v} defaultChecked={sel.includes(v)} /> {l}</label>)}</div>);
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Name" htmlFor={`sg-n-${k}`} required><Input id={`sg-n-${k}`} name="name" required defaultValue={s?.name} placeholder="e.g. Offices not ordered in 30 days" /></Field>
        <Field label="Description" htmlFor={`sg-d-${k}`}><Input id={`sg-d-${k}`} name="description" defaultValue={s?.description ?? ""} /></Field>
      </div>
      <p className="text-xs text-muted">Leave a part empty to include everyone. Customers must match every part you fill in.</p>
      <div><p className="mb-1 text-sm font-medium">Customer types</p>{checks("customer_types", CUSTOMER_TYPES, r.customer_types)}</div>
      <div><p className="mb-1 text-sm font-medium">Bottle model</p>{checks("bottle_models", [["deposit", "Deposit"], ["loan", "Loan"], ["none", "No bottles"]], r.bottle_models)}</div>
      {routes.length > 0 && <div><p className="mb-1 text-sm font-medium">Routes</p>{checks("route_ids", routes.map((x) => [x.id, x.name] as const), r.route_ids)}</div>}
      {reps.length > 0 && <div><p className="mb-1 text-sm font-medium">Sales rep</p>{checks("sales_rep_ids", reps.map((x) => [x.id, x.name] as const), r.sales_rep_ids)}</div>}
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Towns" htmlFor={`sg-c-${k}`} hint="Commas between"><Input id={`sg-c-${k}`} name="cities" defaultValue={(r.cities ?? []).join(", ")} /></Field>
        <Field label="No order for at least (days)" htmlFor={`sg-mi-${k}`} hint="Find customers who stopped buying"><Input id={`sg-mi-${k}`} name="min_days_since_order" type="number" min={1} defaultValue={r.min_days_since_order ?? ""} /></Field>
        <Field label="Ordered within (days)" htmlFor={`sg-ma-${k}`}><Input id={`sg-ma-${k}`} name="max_days_since_order" type="number" min={1} defaultValue={r.max_days_since_order ?? ""} /></Field>
        <Field label="Buys at least (Rs. a month)" htmlFor={`sg-s-${k}`}><Input id={`sg-s-${k}`} name="min_monthly_sales" type="number" min={0} step="1000" defaultValue={r.min_monthly_sales ?? ""} /></Field>
        <Field label="Overdue balance" htmlFor={`sg-o-${k}`}><Select id={`sg-o-${k}`} name="has_overdue" defaultValue={r.has_overdue === undefined ? "" : r.has_overdue ? "yes" : "no"}>
          <option value="">Either</option><option value="yes">Has overdue</option><option value="no">Nothing overdue</option></Select></Field>
        <Field label="Customer since" htmlFor={`sg-ca-${k}`}><Input id={`sg-ca-${k}`} name="created_after" type="date" defaultValue={r.created_after ?? ""} /></Field>
      </div>
    </>
  );
}

export default async function SegmentsPage() {
  await requirePermission("crm.manage");
  const supabase = await createClient();
  const [{ data: segs }, { data: routes }, { data: reps }, { data: staff }] = await Promise.all([
    supabase.from("customer_segments").select("id, name, description, rules").order("name"),
    supabase.from("routes").select("id, name").eq("is_active", true).order("name"),
    supabase.from("sales_reps").select("profile_id").eq("is_active", true),
    supabase.rpc("staff_directory"),
  ]);
  const names = Object.fromEntries(((staff ?? []) as { id: string; full_name: string }[]).map((s) => [s.id, s.full_name]));
  const repOpts = (reps ?? []).map((r) => ({ id: r.profile_id, name: names[r.profile_id] ?? "Rep" }));
  const list = (segs ?? []) as Seg[];
  const counts: Record<string, number> = {};
  for (const s of list) {
    const { data } = await supabase.rpc("segment_preview", { p_rules: s.rules, p_limit: 0 });
    counts[s.id] = (data as { count: number } | null)?.count ?? 0;
  }
  const describe = (r: Rules) => [
    r.customer_types?.length ? r.customer_types.join(", ") : null, r.bottle_models?.length ? r.bottle_models.join("/") : null,
    r.cities?.length ? `in ${r.cities.join(", ")}` : null, r.min_days_since_order ? `no order for ${r.min_days_since_order}+ days` : null,
    r.max_days_since_order ? `ordered within ${r.max_days_since_order} days` : null, r.min_monthly_sales ? `buys ≥ Rs. ${r.min_monthly_sales}/month` : null,
    r.has_overdue === true ? "has overdue" : r.has_overdue === false ? "nothing overdue" : null, r.route_ids?.length ? `${r.route_ids.length} route(s)` : null,
    r.sales_rep_ids?.length ? `${r.sales_rep_ids.length} rep(s)` : null, r.created_after ? `since ${r.created_after}` : null,
  ].filter(Boolean).join(" · ") || "All active customers";

  return (
    <>
      <PageHeader title="Leads & CRM" description="Customer segments — groups of customers for campaign messages and promotions. Membership is worked out fresh each time."
        actions={<FormDialog trigger={<><Plus className="h-4 w-4" /> New segment</>} triggerVariant="primary" triggerSize="md" title="New segment" submitLabel="Save" action={saveSegment} wide>
          <SegmentFields routes={routes ?? []} reps={repOpts} /></FormDialog>} />
      <CrmTabs active="/crm/segments" />
      <Card>
        <CardHeader title="Segments" />
        {list.length === 0 ? <EmptyState icon={Users} title="No segments yet" /> : (
          <Table>
            <thead><tr><Th>Segment</Th><Th>Who</Th><Th className="text-right">Customers now</Th><Th /></tr></thead>
            <tbody>{list.map((s) => (
              <tr key={s.id}><Td className="font-medium">{s.name}{s.description && <span className="block text-xs font-normal text-muted">{s.description}</span>}</Td>
                <Td className="text-sm">{describe(s.rules)}</Td><Td className="num text-right">{counts[s.id]}</Td>
                <Td className="text-right"><FormDialog trigger="Edit" triggerVariant="ghost" title={s.name} submitLabel="Save" action={saveSegment} hidden={{ id: s.id }} wide>
                  <SegmentFields s={s} routes={routes ?? []} reps={repOpts} /></FormDialog></Td></tr>))}</tbody>
          </Table>)}
      </Card>
    </>
  );
}
