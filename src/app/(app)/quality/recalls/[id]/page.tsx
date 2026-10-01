import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatPhone, formatQty } from "@/lib/format";
import { STOCK_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { closeRecall, secureRecall, updateRecallCustomer } from "../../actions";

export const metadata: Metadata = { title: "Recall" };

type Details = {
  recall: { id: string; recall_no: string; reason: string; status: string; created_at: string; created_by_name: string | null; closed_at: string | null;
    closed_by_name: string | null; close_note: string | null };
  batch: { id: string; batch_no: string; production_date: string; produced_qty: number; expiry_date: string | null; product: string };
  locations: { location_id: string; location: string; type: string; status: string; qty: number }[];
  customers: { id: string; customer_id: string; name: string; customer_no: string; phone: string | null; is_walk_in: boolean; address: string | null;
    qty_supplied: number; bottles_held: number; qty_recovered: number; status: string; note: string | null }[];
  totals: { produced: number; sold: number; in_circulation: number; quarantined: number; recovered: number; disposed: number };
};

const FOLLOW: Record<string, { label: string; tone: "red" | "amber" | "green" | "neutral" }> = {
  open: { label: "To contact", tone: "red" },
  contacted: { label: "Contacted", tone: "amber" },
  recovered: { label: "Recovered", tone: "green" },
  not_recoverable: { label: "Not recoverable", tone: "neutral" },
};

export default async function RecallPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission("qc.view");
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("recall_details", { p_recall: id });
  if (error || !data) notFound();
  const d = data as Details;
  const r = d.recall;
  const open = r.status === "open";
  const act = can(access, ["qc.manage", "qc.release"]) && open;
  const hidden = { recall_id: r.id };
  const onVehicles = d.locations.filter((l) => l.type === "vehicle" && l.status === "available");

  return (
    <>
      <Link href="/quality" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Quality Control</Link>
      <PageHeader title={`Recall ${r.recall_no}`}
        description={`${d.batch.product} · batch ${d.batch.batch_no} made ${formatDate(d.batch.production_date)} · started ${formatDateTime(r.created_at)} by ${r.created_by_name ?? "—"}`}
        actions={<div className="flex flex-wrap items-center gap-2">
          <Badge tone={open ? "red" : "neutral"} className="text-sm">{open ? "Open" : "Closed"}</Badge>
          <Link href={`/production/${d.batch.id}`} className="text-sm text-ola-700 hover:underline">Batch record</Link>
          {act && (
            <FormDialog trigger="Secure stock again" title="Secure remaining stock" description="Moves any of this batch still available (for example brought back from a vehicle) into quarantine."
              submitLabel="Secure now" action={secureRecall} hidden={hidden}><p className="text-sm">Vehicles are skipped — the stock is caught after check-in.</p></FormDialog>
          )}
          {can(access, "qc.release") && open && (
            <ReasonDialog trigger="Close recall" triggerVariant="primary" title="Close this recall" description="Summarise the outcome. The record stays available."
              confirmLabel="Close recall" action={closeRecall} hidden={hidden} />
          )}
        </div>} />

      <Alert tone={open ? "error" : "info"} className="mb-6"><strong>Reason:</strong> {r.reason}
        {!open && <span className="block">Closed {r.closed_at ? formatDateTime(r.closed_at) : ""} by {r.closed_by_name}: {r.close_note}</span>}</Alert>

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Produced" value={formatQty(d.totals.produced)} />
        <Stat label="Sold to customers" value={formatQty(d.totals.sold)} hint={`${formatQty(d.totals.recovered)} recovered so far`} />
        <Stat label="Still in circulation" value={formatQty(d.totals.in_circulation)} hint={d.totals.in_circulation > 0 ? "Sellable stock — on vehicles or not yet secured" : "None"} />
        <Stat label="In quarantine" value={formatQty(d.totals.quarantined)} hint={`${formatQty(d.totals.disposed)} destroyed`} />
      </div>

      {onVehicles.length > 0 && <Alert tone="warning" className="mb-6">Stock is still on {onVehicles.map((v) => v.location).join(", ")}. Ask the driver(s) not to sell it and bring it back; then press “Secure stock again”.</Alert>}

      <div className="space-y-6">
        <Card>
          <CardHeader title="Where the stock is" />
          {d.locations.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No stock of this batch left anywhere.</p> : (
            <Table>
              <thead><tr><Th>Location</Th><Th>Status</Th><Th className="text-right">Units</Th></tr></thead>
              <tbody>{d.locations.map((l, i) => { const st = statusBadge(STOCK_STATUS, l.status); return (
                <tr key={i}><Td>{l.location}<span className="block text-xs capitalize text-muted">{l.type.replace("_", " ")}</span></Td>
                  <Td><Badge tone={st.tone}>{st.label}</Badge></Td><Td className="num text-right">{formatQty(l.qty)}</Td></tr>); })}</tbody>
            </Table>
          )}
        </Card>

        <Card>
          <CardHeader title="Customers to contact" description="Everyone who bought from this batch, plus anyone holding a traced bottle filled in it." />
          {d.customers.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No customer received this batch.</p> : (
            <Table>
              <thead><tr><Th>Customer</Th><Th>Contact</Th><Th className="text-right">Supplied</Th><Th className="text-right">Traced bottles</Th>
                <Th className="text-right">Recovered</Th><Th>Follow-up</Th><Th /></tr></thead>
              <tbody>{d.customers.map((c) => { const f = FOLLOW[c.status] ?? FOLLOW.open; return (
                <tr key={c.id}>
                  <Td>{c.is_walk_in ? <span className="font-medium">Walk-in customers ({c.name})</span> :
                    <Link href={`/customers/${c.customer_id}`} className="font-medium text-ola-700 hover:underline">{c.name}</Link>}
                    <span className="block text-xs text-muted">{c.customer_no}</span></Td>
                  <Td>{c.phone ? formatPhone(c.phone) : "—"}{c.address && <span className="block text-xs text-muted">{c.address}</span>}</Td>
                  <Td className="num text-right">{formatQty(c.qty_supplied)}</Td>
                  <Td className="num text-right">{c.bottles_held || "—"}</Td>
                  <Td className="num text-right">{formatQty(c.qty_recovered)}</Td>
                  <Td><Badge tone={f.tone}>{f.label}</Badge>{c.note && <span className="block text-xs text-muted">{c.note}</span>}</Td>
                  <Td className="text-right">{act && (
                    <FormDialog trigger="Update" triggerVariant="ghost" title={`Follow-up — ${c.name}`} submitLabel="Save" action={updateRecallCustomer}
                      hidden={{ ...hidden, item_id: c.id }}>
                      <Field label="Units collected now" htmlFor={`rq-${c.id}`} hint="They go into quarantine at the plant"><Input id={`rq-${c.id}`} name="qty" type="number" min={0} defaultValue={0} /></Field>
                      <Field label="Status" htmlFor={`rs-${c.id}`}><Select id={`rs-${c.id}`} name="status" defaultValue={c.status === "open" ? "contacted" : c.status}>
                        {Object.entries(FOLLOW).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}</Select></Field>
                      <Field label="Note" htmlFor={`rn-${c.id}`}><Input id={`rn-${c.id}`} name="note" defaultValue={c.note ?? ""} placeholder="e.g. Called, collected tomorrow" /></Field>
                    </FormDialog>
                  )}</Td>
                </tr>); })}</tbody>
            </Table>
          )}
        </Card>
      </div>
    </>
  );
}
