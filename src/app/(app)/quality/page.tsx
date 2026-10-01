import type { Metadata } from "next";
import Link from "next/link";
import { FlaskConical, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatDateTime, formatQty } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { TemplateEditor, type Param } from "./template-editor";
import { saveTemplate } from "./actions";

export const metadata: Metadata = { title: "Quality Control" };

type HeldBatch = { id: string; batch_no: string; production_date: string; status: string; produced_qty: number | null; product: { name: string } | null;
  tests: { result: string; tested_at: string }[]; lots: { stock_status: string; qty: number }[] };

export default async function QualityPage() {
  const access = await requirePermission("qc.view");
  const supabase = await createClient();
  const [{ data: held }, { data: recalls }, { data: tpls }, { data: prms }, { data: products }, { data: expiring }, { data: ops }] = await Promise.all([
    supabase.from("production_batches")
      .select("id, batch_no, production_date, status, produced_qty, product:products(name), tests:qc_tests(result, tested_at), lots:inventory_lots(stock_status, qty)")
      .in("status", ["qc_hold", "failed", "recalled"]).order("production_date").limit(100),
    supabase.from("batch_recalls").select("id, recall_no, status, reason, created_at, closed_at, batch:production_batches(batch_no, product:products(name))")
      .order("created_at", { ascending: false }).limit(30),
    supabase.from("qc_templates").select("id, code, name, product_id, description, is_active").order("name"),
    supabase.from("qc_template_parameters").select("template_id, name, unit, value_type, min_value, max_value, is_required, sort_order").order("sort_order"),
    supabase.from("products").select("id, name").eq("item_type", "finished_good").eq("is_active", true).order("sort_order"),
    supabase.rpc("expiring_stock", { p_days: null }),
    supabase.rpc("operations_summary"),
  ]);
  const p = (ops as { production?: Record<string, number> } | null)?.production;
  const rows = (held ?? []) as unknown as HeldBatch[];
  const waiting = rows.filter((b) => b.status === "qc_hold");
  const quarantined = rows.filter((b) => b.status !== "qc_hold" && b.lots.some((l) => l.stock_status === "quarantine" && Number(l.qty) > 0));
  const manage = can(access, "qc.manage");
  const prodName = Object.fromEntries((products ?? []).map((x) => [x.id, x.name]));
  type Recall = { id: string; recall_no: string; status: string; reason: string; created_at: string; closed_at: string | null;
    batch: { batch_no: string; product: { name: string } | null } | null };

  const templateFields = (t?: { id: string; code: string; name: string; product_id: string | null; description: string | null; is_active: boolean }) => {
    const params: Param[] = (prms ?? []).filter((x) => x.template_id === t?.id).map((x) => ({
      name: x.name, unit: x.unit ?? "", value_type: x.value_type, min_value: x.min_value === null ? "" : String(x.min_value),
      max_value: x.max_value === null ? "" : String(x.max_value), is_required: x.is_required }));
    const k = t?.id ?? "new";
    return (
      <>
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Code" htmlFor={`tc-${k}`} required><Input id={`tc-${k}`} name="code" defaultValue={t?.code} required disabled={!!t} placeholder="BW-STD" /></Field>
          <Field label="Name" htmlFor={`tn-${k}`} required className="sm:col-span-2"><Input id={`tn-${k}`} name="name" defaultValue={t?.name} required /></Field>
        </div>
        <Field label="For product" htmlFor={`tp-${k}`}><Select id={`tp-${k}`} name="product_id" defaultValue={t?.product_id ?? ""}>
          <option value="">Any product</option>{products?.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <TemplateEditor initial={params} />
        {t && <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={t.is_active} /> Active</label>}
        {t && <Field label="Reason for change" htmlFor={`tr-${k}`}><Input id={`tr-${k}`} name="reason" /></Field>}
      </>
    );
  };

  const { data: reviews } = await supabase.from("complaints")
    .select("id, complaint_no, subject, created_at, batch:production_batches(batch_no), customer:customers(name)")
    .eq("qc_review_status", "requested").order("created_at");
  type Review = { id: string; complaint_no: string; subject: string; created_at: string; batch: { batch_no: string } | null; customer: { name: string } | null };

  return (
    <>
      <PageHeader title="Quality Control" description="New production waits here until it passes QC. Failed and recalled stock stays in quarantine until it is destroyed."
        actions={manage && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New template</>} triggerVariant="primary" triggerSize="md" title="New QC template"
            description="The tests and the acceptable range for each." submitLabel="Save template" action={saveTemplate} wide>
            {templateFields()}
          </FormDialog>
        )} />

      {(reviews ?? []).length > 0 && (
        <Card className="mb-6">
          <CardHeader title="Customer complaints to review" description="Check retained samples, re-test, hold or recall the batch, then record your finding on the complaint." />
          <Table>
            <thead><tr><Th>Complaint</Th><Th>Batch</Th><Th>Customer</Th><Th>Logged</Th></tr></thead>
            <tbody>{((reviews ?? []) as unknown as Review[]).map((r) => (
              <tr key={r.id}><Td><Link href={`/complaints/${r.id}`} className="font-medium text-ola-700 hover:underline">{r.subject}</Link>
                <span className="block font-mono text-xs text-muted">{r.complaint_no}</span></Td>
                <Td className="font-mono">{r.batch?.batch_no ?? "—"}</Td><Td>{r.customer?.name ?? "—"}</Td><Td>{formatDateTime(r.created_at)}</Td></tr>))}</tbody>
          </Table>
        </Card>
      )}

      {p && (
        <div className="mb-6 grid gap-4 sm:grid-cols-3">
          <Stat label="Batches waiting for QC" value={p.qc_hold} hint={`${formatQty(p.qc_hold_qty)} units on hold`} />
          <Stat label="In quarantine" value={formatQty(p.quarantine_qty)} hint="Failed or recalled units not yet destroyed" />
          <Stat label="Open recalls" value={p.open_recalls} />
        </div>
      )}

      <div className="space-y-6">
        <Card>
          <CardHeader title="Waiting for QC" />
          {waiting.length === 0 ? <EmptyState icon={FlaskConical} title="Nothing waiting" description="Finished batches appear here until they are released or failed." /> : (
            <Table>
              <thead><tr><Th>Batch</Th><Th>Product</Th><Th>Made</Th><Th className="text-right">Units</Th><Th>Latest test</Th></tr></thead>
              <tbody>{waiting.map((b) => {
                const last = [...b.tests].sort((a, c) => c.tested_at.localeCompare(a.tested_at))[0];
                return (
                  <tr key={b.id}>
                    <Td><Link href={`/production/${b.id}`} className="font-medium text-ola-700 hover:underline">{b.batch_no}</Link></Td>
                    <Td>{b.product?.name}</Td><Td>{formatDate(b.production_date)}</Td><Td className="num text-right">{b.produced_qty}</Td>
                    <Td>{last ? <Badge tone={last.result === "pass" ? "green" : "red"}>{last.result === "pass" ? "Passed — release it" : "Failed"}</Badge> : <span className="text-muted">Not tested</span>}</Td>
                  </tr>
                );
              })}</tbody>
            </Table>
          )}
        </Card>

        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader title="In quarantine" description="Destroy it from the batch page." />
            {quarantined.length === 0 ? <p className="px-5 py-4 text-sm text-muted">Nothing in quarantine.</p> : (
              <Table>
                <thead><tr><Th>Batch</Th><Th>Product</Th><Th className="text-right">Units</Th></tr></thead>
                <tbody>{quarantined.map((b) => (
                  <tr key={b.id}><Td><Link href={`/production/${b.id}`} className="font-medium text-ola-700 hover:underline">{b.batch_no}</Link>
                    <Badge tone="red" className="ml-2">{b.status === "recalled" ? "Recalled" : "Failed"}</Badge></Td>
                    <Td>{b.product?.name}</Td>
                    <Td className="num text-right">{formatQty(b.lots.filter((l) => l.stock_status === "quarantine").reduce((a, l) => a + Number(l.qty), 0))}</Td></tr>
                ))}</tbody>
              </Table>
            )}
          </Card>

          <Card>
            <CardHeader title="Expiring soon" description="Stock of batches near or past their expiry date." />
            {(expiring ?? []).length === 0 ? <p className="px-5 py-4 text-sm text-muted">Nothing expiring soon.</p> : (
              <Table>
                <thead><tr><Th>Batch</Th><Th>Where</Th><Th className="text-right">Units</Th><Th>Expires</Th></tr></thead>
                <tbody>{(expiring as { batch_id: string; batch_no: string; product: string; location: string; qty: number; expiry_date: string; days_left: number }[]).map((x, i) => (
                  <tr key={i}><Td><Link href={`/production/${x.batch_id}`} className="font-medium text-ola-700 hover:underline">{x.batch_no}</Link>
                    <span className="block text-xs text-muted">{x.product}</span></Td><Td>{x.location}</Td><Td className="num text-right">{formatQty(x.qty)}</Td>
                    <Td><Badge tone={x.days_left < 0 ? "red" : "amber"}>{x.days_left < 0 ? `Expired ${formatDate(x.expiry_date)}` : `${formatDate(x.expiry_date)} (${x.days_left} days)`}</Badge></Td></tr>
                ))}</tbody>
              </Table>
            )}
          </Card>
        </div>

        <Card>
          <CardHeader title="Recalls" description="Start a recall from the batch page." />
          {(recalls ?? []).length === 0 ? <p className="px-5 py-4 text-sm text-muted">No recalls.</p> : (
            <Table>
              <thead><tr><Th>Recall</Th><Th>Batch</Th><Th>Reason</Th><Th>Started</Th><Th>Status</Th></tr></thead>
              <tbody>{((recalls ?? []) as unknown as Recall[]).map((r) => (
                <tr key={r.id}><Td><Link href={`/quality/recalls/${r.id}`} className="font-medium text-ola-700 hover:underline">{r.recall_no}</Link></Td>
                  <Td>{r.batch?.batch_no}<span className="block text-xs text-muted">{r.batch?.product?.name}</span></Td>
                  <Td className="max-w-sm">{r.reason}</Td><Td className="whitespace-nowrap">{formatDateTime(r.created_at)}</Td>
                  <Td><Badge tone={r.status === "open" ? "red" : "neutral"}>{r.status === "open" ? "Open" : `Closed ${r.closed_at ? formatDate(r.closed_at) : ""}`}</Badge></Td></tr>
              ))}</tbody>
            </Table>
          )}
        </Card>

        <Card>
          <CardHeader title="QC templates" description="A template is the list of tests for a product and the acceptable range of each." />
          {(tpls ?? []).length === 0 ? <p className="px-5 py-4 text-sm text-muted">No templates yet — create one with New template.</p> : (
            <Table>
              <thead><tr><Th>Template</Th><Th>For</Th><Th>Tests</Th><Th /></tr></thead>
              <tbody>{tpls?.map((t) => (
                <tr key={t.id} className={t.is_active ? "" : "opacity-50"}>
                  <Td><span className="font-medium">{t.name}</span><span className="block font-mono text-xs text-muted">{t.code}</span></Td>
                  <Td>{t.product_id ? prodName[t.product_id] ?? "—" : "Any product"}</Td>
                  <Td>{(prms ?? []).filter((x) => x.template_id === t.id).map((x) => (
                    <span key={x.name} className="mr-2 inline-block text-xs">{x.name}{x.value_type === "number" && (x.min_value !== null || x.max_value !== null) ? ` ${x.min_value ?? "…"}–${x.max_value ?? "…"}` : ""}{x.unit ? ` ${x.unit}` : ""}</span>))}</Td>
                  <Td className="text-right">{manage && (
                    <FormDialog trigger="Edit" triggerVariant="ghost" title={`Edit ${t.name}`} description="Past test results keep the limits that applied when they were recorded."
                      submitLabel="Save" action={saveTemplate} hidden={{ id: t.id, code: t.code }} wide>
                      {templateFields(t)}
                    </FormDialog>
                  )}</Td>
                </tr>
              ))}</tbody>
            </Table>
          )}
        </Card>
      </div>
    </>
  );
}
