import type { Metadata } from "next";
import { DocumentsCard } from "@/components/documents/documents-card";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR, formatQty, humanize } from "@/lib/format";
import { BATCH_STATUS, PRODUCTION_STAGES, STOCK_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { CompleteForm } from "./complete-form";
import { QcTestFields, type QcTemplate } from "./qc-test-fields";
import { cancelBatch, disposeStock, recallBatch, recordQcTest, recordStage, rejectBatch, releaseBatch, startBatch } from "../actions";

export const metadata: Metadata = { title: "Production batch" };

type Details = {
  batch: { id: string; batch_no: string; status: string; production_date: string; shift: string; planned_qty: number; produced_qty: number | null;
    rejected_qty: number | null; wastage_qty: number | null; wastage_note: string | null; operator_name: string | null; started_at: string | null;
    ended_at: string | null; expiry_date: string | null; material_cost: number | null; unit_cost: number | null; bottles_scanned: number;
    released_at: string | null; release_override: boolean; decision_note: string | null; notes: string | null };
  product: { id: string; name: string; is_returnable: boolean; shelf_life_days: number | null };
  line: { code: string; name: string }; location: string; created_by: string | null; released_by: string | null;
  stages: { stage: string; recorded_at: string; reading: string | null; notes: string | null; by: string | null }[];
  materials: { name: string; unit: string; qty: number; unit_cost: number; value: number }[];
  bom: { material_id: string; name: string; unit: string; qty_per_unit: number; available: number }[];
  tests: { id: string; test_no: string; tested_at: string; result: string; template: string; lab_name: string | null; sample_ref: string | null;
    notes: string | null; certificate_path: string | null; by: string | null;
    results: { name: string; unit: string | null; min: number | null; max: number | null; value: string | null; passed: boolean; required: boolean }[] }[];
  stock: { location_id: string; location: string; location_type: string; status: string; qty: number }[];
  sold: number; disposed: number;
  bottles: { code: string; holder: string; still_from_batch: boolean }[];
  recalls: { id: string; recall_no: string; status: string; created_at: string }[];
  journals: { entry_no: string; entry_date: string; event_type: string; total: number }[];
};

const stageName = Object.fromEntries(PRODUCTION_STAGES.map(([k, v]) => [k, v]));

export default async function BatchPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["production.view", "qc.view", "inventory.view"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("batch_details", { p_batch: id });
  if (error || !data) notFound();
  const d = data as Details;
  const b = d.batch;
  const [{ data: tpls }, { data: prms }] = await Promise.all([
    supabase.from("qc_templates").select("id, name, product_id").eq("is_active", true).order("name"),
    supabase.from("qc_template_parameters").select("id, template_id, name, unit, value_type, min_value, max_value, is_required, sort_order").order("sort_order"),
  ]);
  const templates: QcTemplate[] = (tpls ?? []).filter((t) => !t.product_id || t.product_id === d.product.id)
    .map((t) => ({ id: t.id, name: t.name, parameters: (prms ?? []).filter((p) => p.template_id === t.id) }));
  const certs: Record<string, string> = {};
  for (const t of d.tests.filter((x) => x.certificate_path)) {
    const { data: u } = await supabase.storage.from("qc-certificates").createSignedUrl(t.certificate_path!, 3600);
    if (u?.signedUrl) certs[t.id] = u.signedUrl;
  }

  const s = statusBadge(BATCH_STATUS, b.status);
  const manage = can(access, "production.manage");
  const qc = can(access, "qc.manage");
  const release = can(access, "qc.release");
  const latest = d.tests[0];
  const quarantine = d.stock.filter((x) => x.status === "quarantine");
  const hidden = { batch_id: b.id };
  const running = b.status === "planned" || b.status === "in_production";

  return (
    <>
      <Link href="/production" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Production</Link>
      <PageHeader title={`Batch ${b.batch_no}`}
        description={`${d.product.name} · ${d.line.code} ${d.line.name} · ${formatDate(b.production_date)} (${b.shift} shift) · fills into ${d.location}`}
        actions={<div className="flex flex-wrap items-center gap-2">
          <Badge tone={s.tone} className="text-sm">{s.label}</Badge>
          {manage && b.status === "planned" && (
            <FormDialog trigger="Start production" triggerVariant="primary" title="Start production" submitLabel="Start" action={startBatch} hidden={hidden}>
              <Field label="Operator" htmlFor="sb-op"><Input id="sb-op" name="operator_name" defaultValue={b.operator_name ?? ""} /></Field>
            </FormDialog>
          )}
          {manage && running && (
            <FormDialog trigger="Record stage" title="Record a process stage" submitLabel="Record" action={recordStage} hidden={hidden}>
              <Field label="Stage" htmlFor="rs-st"><Select id="rs-st" name="stage">{PRODUCTION_STAGES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
              <Field label="Reading" htmlFor="rs-rd" hint="e.g. TDS 12 ppm, UV lamp OK, ozone 0.3 mg/L"><Input id="rs-rd" name="reading" /></Field>
              <Field label="Notes" htmlFor="rs-n"><Input id="rs-n" name="notes" /></Field>
            </FormDialog>
          )}
          {manage && running && (
            <ReasonDialog trigger="Cancel batch" triggerVariant="dangerOutline" title="Cancel this batch" description="Nothing has been taken from stock yet."
              confirmLabel="Cancel batch" confirmVariant="danger" action={cancelBatch} hidden={hidden} />
          )}
          {qc && b.status === "qc_hold" && latest?.result === "pass" && (
            <ReasonDialog trigger="Release for sale" triggerVariant="primary" title="Release batch for sale" reasonRequired={false}
              description={`QC test ${latest.test_no} passed. ${b.produced_qty} unit(s) become available for sale.`} confirmLabel="Release" action={releaseBatch} hidden={hidden} />
          )}
          {qc && b.status === "qc_hold" && (
            <ReasonDialog trigger="Fail batch" triggerVariant="dangerOutline" title="Fail this batch" description="All units go to quarantine and cannot be sold."
              confirmLabel="Fail batch" confirmVariant="danger" action={rejectBatch} hidden={hidden} />
          )}
          {release && (b.status === "failed" || (b.status === "qc_hold" && latest?.result !== "pass")) && Number(b.produced_qty) > 0 && (
            <ReasonDialog trigger="Override release" triggerVariant="dangerOutline" title="Release without a passed QC test"
              description="Only for exceptional cases (e.g. a lab error). The override and your reason are recorded in the audit trail."
              confirmLabel="Release anyway" confirmVariant="danger" action={releaseBatch} hidden={{ ...hidden, override: "1" }} />
          )}
          {release && (b.status === "released" || b.status === "qc_hold") && (
            <ReasonDialog trigger="Recall batch" triggerVariant="danger" title={`Recall batch ${b.batch_no}`}
              description="All stock of this batch is moved to quarantine and everyone who received it is listed for follow-up."
              confirmLabel="Start recall" confirmVariant="danger" action={recallBatch} hidden={hidden} />
          )}
        </div>} />

      {b.release_override && <Alert tone="warning" className="mb-4">Released by authorised override: {b.decision_note}</Alert>}
      {b.status === "failed" && <Alert tone="error" className="mb-4">This batch failed QC{b.decision_note ? `: ${b.decision_note}` : ""}. Its stock is in quarantine and cannot be sold.</Alert>}
      {d.recalls.filter((r) => r.status === "open").map((r) => (
        <Alert key={r.id} tone="error" className="mb-4">Recall <Link href={`/quality/recalls/${r.id}`} className="font-semibold underline">{r.recall_no}</Link> is open.</Alert>
      ))}

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Card className="p-5"><p className="text-sm text-muted">Planned / good / rejected</p>
          <p className="num mt-1 text-2xl font-semibold">{b.planned_qty} / {b.produced_qty ?? "—"} / {b.rejected_qty ?? "—"}</p>
          {b.wastage_qty !== null && <p className="text-xs text-muted">{formatQty(b.wastage_qty)} L wasted{b.wastage_note ? ` — ${b.wastage_note}` : ""}</p>}</Card>
        <Card className="p-5"><p className="text-sm text-muted">Material cost</p><p className="num mt-1 text-2xl font-semibold">{formatLKR(b.material_cost)}</p>
          <p className="text-xs text-muted">{b.unit_cost !== null ? `${formatLKR(b.unit_cost)} per unit` : "Recorded when finished"}</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">Expiry</p><p className="num mt-1 text-2xl font-semibold">{b.expiry_date ? formatDate(b.expiry_date) : "—"}</p>
          <p className="text-xs text-muted">{d.product.shelf_life_days ? `${d.product.shelf_life_days} days shelf life` : "No shelf life set on the product"}</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">Where it went</p>
          <p className="num mt-1 text-2xl font-semibold">{formatQty(d.sold)} sold</p>
          <p className="text-xs text-muted">{formatQty(d.stock.reduce((a, x) => a + Number(x.qty), 0))} still in stock · {formatQty(d.disposed)} destroyed</p></Card>
      </div>

      {manage && running && (
        <Card className="mb-6"><CardHeader title="Finish production" description="Enter the output and what was used. The output goes on QC hold." />
          <CardBody><CompleteForm batchId={b.id} planned={b.planned_qty} bom={d.bom} returnable={d.product.is_returnable} operator={b.operator_name} /></CardBody></Card>
      )}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card className="lg:col-span-2">
          <CardHeader title="Quality control" description="Every test is kept. Values outside the limits fail the test automatically."
            actions={qc && !running && b.status !== "cancelled" && (
              <FormDialog trigger="Record QC test" triggerVariant="primary" title={`QC test — ${b.batch_no}`} submitLabel="Save result" action={recordQcTest} hidden={hidden} wide>
                <QcTestFields templates={templates} />
              </FormDialog>
            )} />
          {d.tests.length === 0 ? <CardBody><p className="text-sm text-muted">{running ? "Tests are recorded once production is finished." : "No test recorded yet."}</p></CardBody> : (
            <div className="divide-y divide-line">
              {d.tests.map((t) => (
                <div key={t.id} className="px-5 py-4">
                  <div className="mb-2 flex flex-wrap items-center gap-2 text-sm">
                    <Badge tone={t.result === "pass" ? "green" : "red"}>{t.result === "pass" ? "PASS" : "FAIL"}</Badge>
                    <span className="font-medium">{t.test_no}</span><span className="text-muted">{t.template} · {formatDateTime(t.tested_at)} · {t.by}{t.lab_name && ` · ${t.lab_name}`}{t.sample_ref && ` · sample ${t.sample_ref}`}</span>
                    {certs[t.id] && <a href={certs[t.id]} target="_blank" rel="noreferrer" className="text-ola-700 hover:underline">Certificate</a>}
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {t.results.map((r) => (
                      <span key={r.name} className={`rounded-lg px-2.5 py-1 text-xs ring-1 ring-inset ${r.passed ? "bg-emerald-50 text-emerald-900 ring-emerald-200" : "bg-red-50 text-red-900 ring-red-200"}`}>
                        <span className="font-semibold">{r.name}</span> {r.value ?? "—"}{r.unit ? ` ${r.unit}` : ""}
                        {(r.min !== null || r.max !== null) && <span className="opacity-70"> ({r.min ?? "…"}–{r.max ?? "…"})</span>}
                      </span>
                    ))}
                  </div>
                  {t.notes && <p className="mt-2 text-sm text-muted">{t.notes}</p>}
                </div>
              ))}
            </div>
          )}
        </Card>

        <Card>
          <CardHeader title="Stock of this batch" actions={release || can(access, "inventory.adjust") ? (quarantine.length > 0 && (
            <ReasonDialog trigger="Destroy quarantined stock" triggerVariant="dangerOutline" title="Destroy quarantined stock"
              description="Written off at the batch cost. Returnable bottles go back to the empties." confirmLabel="Destroy" confirmVariant="danger" action={disposeStock} hidden={hidden}>
              <Field label="Where" htmlFor="ds-loc"><Select id="ds-loc" name="location_id">{quarantine.map((q) => <option key={q.location_id} value={q.location_id}>{q.location} ({formatQty(q.qty)} in quarantine)</option>)}</Select></Field>
              <Field label="Quantity destroyed" htmlFor="ds-q" required><Input id="ds-q" name="qty" type="number" min={1} required /></Field>
            </ReasonDialog>
          )) : null} />
          {d.stock.length === 0 ? <CardBody><p className="text-sm text-muted">None in stock.</p></CardBody> : (
            <Table>
              <thead><tr><Th>Where</Th><Th>Status</Th><Th className="text-right">Qty</Th></tr></thead>
              <tbody>{d.stock.map((x, i) => { const st = statusBadge(STOCK_STATUS, x.status); return (
                <tr key={i}><Td>{x.location}</Td><Td><Badge tone={st.tone}>{st.label}</Badge></Td><Td className="num text-right">{formatQty(x.qty)}</Td></tr>); })}</tbody>
            </Table>
          )}
        </Card>

        <Card>
          <CardHeader title="Materials used" />
          {d.materials.length === 0 ? <CardBody><p className="text-sm text-muted">{running ? "Recorded when production is finished." : "No materials recorded."}</p></CardBody> : (
            <Table>
              <thead><tr><Th>Material</Th><Th className="text-right">Qty</Th><Th className="text-right">Cost</Th></tr></thead>
              <tbody>{d.materials.map((m) => (
                <tr key={m.name}><Td>{m.name}</Td><Td className="num text-right">{formatQty(m.qty)} {m.unit}</Td><Td className="num text-right">{formatLKR(m.value)}</Td></tr>))}</tbody>
            </Table>
          )}
        </Card>

        <Card>
          <CardHeader title="Process record" />
          {d.stages.length === 0 && !b.started_at ? <CardBody><p className="text-sm text-muted">Nothing recorded yet.</p></CardBody> : (
            <ul className="divide-y divide-line text-sm">
              {b.started_at && <li className="px-5 py-2.5">Started {formatDateTime(b.started_at)}{b.operator_name && ` · ${b.operator_name}`}</li>}
              {d.stages.map((x, i) => (
                <li key={i} className="px-5 py-2.5"><span className="font-medium">{stageName[x.stage] ?? humanize(x.stage)}</span>
                  {x.reading && <span> — {x.reading}</span>}<span className="block text-xs text-muted">{formatDateTime(x.recorded_at)} · {x.by}{x.notes && ` · ${x.notes}`}</span></li>
              ))}
              {b.ended_at && <li className="px-5 py-2.5">Finished {formatDateTime(b.ended_at)}</li>}
              {b.released_at && <li className="px-5 py-2.5">Released {formatDateTime(b.released_at)} by {d.released_by}</li>}
            </ul>
          )}
        </Card>

        <Card>
          <CardHeader title="Bottles filled (traced)" description={`${b.bottles_scanned} scanned at filling`} />
          {d.bottles.length === 0 ? <CardBody><p className="text-sm text-muted">No bottle labels were scanned for this batch.</p></CardBody> : (
            <ul className="max-h-72 divide-y divide-line overflow-y-auto text-sm">
              {d.bottles.map((x) => <li key={x.code} className="flex justify-between px-5 py-2"><span className="font-mono">{x.code}</span>
                <span className="text-muted">{x.still_from_batch ? x.holder : "refilled since"}</span></li>)}
            </ul>
          )}
        </Card>

        {d.journals.length > 0 && (
          <Card className="lg:col-span-2">
            <CardHeader title="Accounting entries" />
            <Table>
              <thead><tr><Th>Entry</Th><Th>Date</Th><Th>Type</Th><Th className="text-right">Amount</Th></tr></thead>
              <tbody>{d.journals.map((j) => <tr key={j.entry_no}><Td className="font-mono text-xs">{j.entry_no}</Td><Td>{formatDate(j.entry_date)}</Td>
                <Td>{humanize(j.event_type.replace(".", " "))}</Td><Td className="num text-right">{formatLKR(j.total)}</Td></tr>)}</tbody>
            </Table>
          </Card>
        )}
      </div>
      <div className="mt-6"><DocumentsCard access={access} entityType="batch" entityId={id} categories={["lab_report","qc_certificate"]} returnTo={`/production/${id}`} /></div>
      <BatchComplaints batchId={id} />
    </>
  );
}

async function BatchComplaints({ batchId }: { batchId: string }) {
  const supabase = await createClient();
  const { data } = await supabase.from("complaints").select("id, complaint_no, subject, status, created_at, qc_review_status").eq("batch_id", batchId)
    .order("created_at", { ascending: false });
  if (!data?.length) return null;
  return (
    <div className="mt-6 rounded-xl border border-line bg-white p-5 shadow-xs">
      <h2 className="mb-2 text-base font-semibold text-navy-900">Customer complaints about this batch</h2>
      <ul className="space-y-1 text-sm">{data.map((c) => (
        <li key={c.id}><Link href={`/complaints/${c.id}`} className="text-ola-700 hover:underline">{c.complaint_no}</Link> — {c.subject}
          <span className="text-muted"> ({c.status.replace("_", " ")}{c.qc_review_status === "requested" ? ", QC review needed" : ""})</span></li>))}</ul>
    </div>
  );
}
