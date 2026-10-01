import type { Metadata } from "next";
import Link from "next/link";
import { Factory, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatQty, todayISO } from "@/lib/format";
import { BATCH_STATUS, SHIFTS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { planBatch, saveLine } from "./actions";

export const metadata: Metadata = { title: "Production" };

const FILTERS: [string, string, string[]][] = [
  ["active", "In progress", ["planned", "in_production", "qc_hold"]],
  ["released", "Released", ["released"]],
  ["problems", "Failed / recalled", ["failed", "recalled"]],
  ["all", "All", []],
];

type Batch = { id: string; batch_no: string; production_date: string; shift: string; status: string; planned_qty: number; produced_qty: number | null;
  rejected_qty: number | null; unit_cost: number | null; expiry_date: string | null; product: { name: string } | null; line: { code: string } | null };

export default async function ProductionPage({ searchParams }: { searchParams: Promise<{ show?: string }> }) {
  const access = await requirePermission(["production.view", "qc.view"]);
  const show = (await searchParams).show ?? "active";
  const filter = FILTERS.find((x) => x[0] === show) ?? FILTERS[0];
  const supabase = await createClient();
  let q = supabase.from("production_batches")
    .select("id, batch_no, production_date, shift, status, planned_qty, produced_qty, rejected_qty, unit_cost, expiry_date, product:products(name), line:production_lines(code)")
    .order("production_date", { ascending: false }).order("batch_no", { ascending: false }).limit(150);
  if (filter[2].length) q = q.in("status", filter[2]);
  const [{ data: batches }, { data: lines }, { data: products }, { data: locations }, { data: ops }] = await Promise.all([
    q,
    supabase.from("production_lines").select("id, code, name, location_id, notes, is_active").order("code"),
    supabase.from("products").select("id, name").eq("item_type", "finished_good").eq("is_active", true).order("sort_order"),
    supabase.from("locations").select("id, name").eq("location_type", "warehouse").eq("is_active", true).order("name"),
    supabase.rpc("operations_summary"),
  ]);
  const p = (ops as { production?: Record<string, number> } | null)?.production;
  const manage = can(access, "production.manage");
  const activeLines = (lines ?? []).filter((l) => l.is_active);
  const locName = Object.fromEntries((locations ?? []).map((l) => [l.id, l.name]));

  return (
    <>
      <PageHeader title="Production" description="Plan a batch, record the process, the materials used and the output. New output waits on QC hold until Quality releases it."
        actions={<>
          {manage && (
            <FormDialog trigger="Production lines" triggerSize="md" title="Production lines" description="Each line belongs to the store it fills into." submitLabel="Add line" action={saveLine}>
              {(lines ?? []).length > 0 && (
                <ul className="divide-y divide-line rounded-lg border border-line text-sm">
                  {lines?.map((l) => <li key={l.id} className="flex justify-between px-3 py-2"><span><span className="font-medium">{l.code}</span> {l.name}</span><span className="text-muted">{locName[l.location_id] ?? ""}{!l.is_active && " · inactive"}</span></li>)}
                </ul>
              )}
              <p className="text-sm font-medium">Add a line</p>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Code" htmlFor="ln-code" required><Input id="ln-code" name="code" required placeholder="L1-19L" /></Field>
                <Field label="Name" htmlFor="ln-name" required><Input id="ln-name" name="name" required placeholder="19L filling line" /></Field>
              </div>
              <Field label="Fills into store" htmlFor="ln-loc"><Select id="ln-loc" name="location_id">{locations?.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
            </FormDialog>
          )}
          {manage && (
            <FormDialog trigger={<><Plus className="h-4 w-4" /> New batch</>} triggerVariant="primary" triggerSize="md" title="Plan a production batch"
              description="A batch number is given now. Materials and output are recorded when the batch is finished." submitLabel="Plan batch" action={planBatch}>
              {activeLines.length === 0 ? <p className="text-sm text-red-700">Add a production line first.</p> : (
                <>
                  <Field label="Product" htmlFor="pb-prod" required><Select id="pb-prod" name="product_id" required>{products?.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
                  <div className="grid gap-4 sm:grid-cols-2">
                    <Field label="Line" htmlFor="pb-line" required><Select id="pb-line" name="line_id" required>{activeLines.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}</Select></Field>
                    <Field label="Planned quantity" htmlFor="pb-qty" required><Input id="pb-qty" name="planned_qty" type="number" min={1} required /></Field>
                    <Field label="Production date" htmlFor="pb-date"><Input id="pb-date" name="production_date" type="date" defaultValue={todayISO()} /></Field>
                    <Field label="Shift" htmlFor="pb-shift"><Select id="pb-shift" name="shift" defaultValue="day">{SHIFTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
                  </div>
                  <Field label="Operator" htmlFor="pb-op"><Input id="pb-op" name="operator_name" /></Field>
                  <Field label="Notes" htmlFor="pb-notes"><Textarea id="pb-notes" name="notes" /></Field>
                </>
              )}
            </FormDialog>
          )}
        </>} />

      {p && (
        <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Stat label="Produced today" value={formatQty(p.today_produced)} />
          <Stat label="Batches in production" value={p.in_production} />
          <Stat label="On QC hold" value={`${p.qc_hold} batch(es)`} hint={`${formatQty(p.qc_hold_qty)} units waiting for QC`} />
          <Stat label="Rejected this month" value={formatQty(p.month_rejected)}
            hint={Number(p.month_produced) + Number(p.month_rejected) > 0 ? `${((100 * Number(p.month_rejected)) / (Number(p.month_produced) + Number(p.month_rejected))).toFixed(1)}% of units made` : undefined} />
        </div>
      )}

      <Card>
        <CardHeader title="Batches" actions={<div className="flex flex-wrap gap-1">
          {FILTERS.map(([k, l]) => <Link key={k} href={`/production?show=${k}`} className={buttonVariants({ variant: k === filter[0] ? "primary" : "secondary", size: "sm" })}>{l}</Link>)}
        </div>} />
        {(batches ?? []).length === 0 ? <EmptyState icon={Factory} title="No batches here" description={manage ? "Plan one with New batch." : undefined} /> : (
          <Table>
            <thead><tr><Th>Batch</Th><Th>Product</Th><Th>Date</Th><Th className="text-right">Planned</Th><Th className="text-right">Good</Th>
              <Th className="text-right">Rejected</Th><Th className="text-right">Unit cost</Th><Th>Expires</Th><Th>Status</Th></tr></thead>
            <tbody>
              {((batches ?? []) as unknown as Batch[]).map((b) => {
                const s = statusBadge(BATCH_STATUS, b.status);
                return (
                  <tr key={b.id} className="hover:bg-ola-50/40">
                    <Td><Link href={`/production/${b.id}`} className="font-medium text-ola-700 hover:underline">{b.batch_no}</Link>
                      <span className="block text-xs text-muted">{b.line?.code} · {b.shift}</span></Td>
                    <Td>{b.product?.name}</Td>
                    <Td className="whitespace-nowrap">{formatDate(b.production_date)}</Td>
                    <Td className="num text-right">{b.planned_qty}</Td>
                    <Td className="num text-right">{b.produced_qty ?? "—"}</Td>
                    <Td className="num text-right">{b.rejected_qty ?? "—"}</Td>
                    <Td className="num text-right">{b.unit_cost !== null ? formatLKR(b.unit_cost) : "—"}</Td>
                    <Td className="whitespace-nowrap">{b.expiry_date ? formatDate(b.expiry_date) : "—"}</Td>
                    <Td><Badge tone={s.tone}>{s.label}</Badge></Td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
