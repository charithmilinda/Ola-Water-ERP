import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Camera, CheckCircle2, CircleDot, FlaskConical, MessageSquare, RotateCcw, UserRound } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDateTime, formatLKR, formatPhone } from "@/lib/format";
import { COMPLAINT_STATUS, PRIORITY, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { addComplaintNote, assignComplaint, closeComplaint, completeQcReview, reopenComplaint, requestQcReview, resolveComplaint, updateComplaint } from "../actions";

export const metadata: Metadata = { title: "Complaint" };

type Ref = { id: string; no?: string; name?: string; code?: string; status?: string; product?: string; run_id?: string } | null;
type Details = {
  complaint: { id: string; complaint_no: string; subject: string; description: string | null; status: string; priority: string; channel: string;
    category_code: string; category: string; due_at: string; created_at: string; first_response_at: string | null; resolved_at: string | null; closed_at: string | null;
    resolution: string | null; root_cause: string | null; qc_review_status: string | null; qc_finding: string | null; contact_name: string | null;
    contact_phone: string | null; assigned_to: string | null; assigned_name: string | null; created_by_name: string | null; overdue: boolean };
  customer: { id: string; name: string; customer_no: string; phone: string; outstanding: number; complaints: number } | null;
  links: { order: Ref; delivery: Ref; invoice: Ref; batch: Ref; bottle: Ref; product: Ref; driver: Ref; location: Ref };
  events: { id: string; event: string; from_status: string | null; to_status: string | null; note: string | null; photo_path: string | null; created_at: string; by: string | null }[];
};

const ICON: Record<string, typeof CircleDot> = { created: CircleDot, assigned: UserRound, note: MessageSquare, photo: Camera, resolved: CheckCircle2,
  closed: CheckCircle2, reopened: RotateCcw, qc_review: FlaskConical, status: CircleDot };

export default async function ComplaintPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [{ data }, { data: staff }, { data: cats }] = await Promise.all([
    supabase.rpc("complaint_details", { p_id: id }), supabase.rpc("staff_directory"),
    supabase.from("complaint_categories").select("code, name").eq("is_active", true).order("sort_order"),
  ]);
  if (!data) notFound();
  const d = data as Details;
  const c = d.complaint;
  const manage = can(access, "complaints.manage");
  const open = !["resolved", "closed"].includes(c.status);
  const hidden = { complaint_id: c.id };
  const st = statusBadge(COMPLAINT_STATUS, c.status);
  const pr = statusBadge(PRIORITY, c.priority);
  const photos: Record<string, string> = {};
  for (const e of d.events.filter((x) => x.photo_path).slice(0, 30)) {
    const { data: u } = await supabase.storage.from("complaint-photos").createSignedUrl(e.photo_path!, 3600);
    if (u?.signedUrl) photos[e.id] = u.signedUrl;
  }
  const L = d.links;

  return (
    <>
      <Link href="/complaints" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Complaints</Link>
      <PageHeader title={c.subject} description={`${c.complaint_no} · ${c.category} · logged ${formatDateTime(c.created_at)}${c.created_by_name ? ` by ${c.created_by_name}` : ""}`}
        actions={<div className="flex flex-wrap items-center gap-2">
          <Badge tone={pr.tone} className="text-sm">{pr.label}</Badge><Badge tone={st.tone} className="text-sm">{st.label}</Badge>
          {manage && open && <>
            <FormDialog trigger="Assign" triggerSize="sm" title="Who handles this complaint" submitLabel="Assign" action={assignComplaint} hidden={hidden}>
              <Field label="Person" htmlFor="as-u"><Select id="as-u" name="user_id" defaultValue={c.assigned_to ?? ""}>
                {((staff ?? []) as { id: string; full_name: string }[]).map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</Select></Field>
              <Field label="Note" htmlFor="as-n"><Input id="as-n" name="note" /></Field>
            </FormDialog>
            <FormDialog trigger="Update" triggerSize="sm" title="Status, priority or type" submitLabel="Save" action={updateComplaint} hidden={hidden}>
              <div className="grid gap-4 sm:grid-cols-3">
                <Field label="Status" htmlFor="up-s"><Select id="up-s" name="status" defaultValue={c.status}>
                  <option value="new">New</option><option value="assigned">Assigned</option><option value="in_progress">In progress</option></Select></Field>
                <Field label="Priority" htmlFor="up-p"><Select id="up-p" name="priority" defaultValue={c.priority}>
                  <option value="urgent">Urgent</option><option value="high">High</option><option value="normal">Normal</option><option value="low">Low</option></Select></Field>
                <Field label="About" htmlFor="up-c"><Select id="up-c" name="category_code" defaultValue={c.category_code}>
                  {(cats ?? []).map((x) => <option key={x.code} value={x.code}>{x.name}</option>)}</Select></Field>
              </div>
              <Field label="Note" htmlFor="up-n"><Input id="up-n" name="note" /></Field>
            </FormDialog>
            <FormDialog trigger="Resolve" triggerVariant="primary" triggerSize="sm" title="Resolve the complaint" submitLabel="Mark resolved" action={resolveComplaint} hidden={hidden}>
              <Field label="What was done" htmlFor="rs-r" required><Textarea id="rs-r" name="resolution" required placeholder="e.g. Replaced 2 bottles free of charge" /></Field>
              <Field label="Cause (for the record)" htmlFor="rs-c"><Input id="rs-c" name="root_cause" placeholder="e.g. Cap seal faulty" /></Field>
            </FormDialog>
          </>}
          {manage && c.status === "resolved" && (
            <ReasonDialog trigger="Close" triggerVariant="primary" title="Close the complaint" description="Close once the customer is satisfied." reasonRequired={false}
              confirmLabel="Close" action={closeComplaint} hidden={hidden} />)}
          {manage && !open && <ReasonDialog trigger="Reopen" title="Reopen the complaint" confirmLabel="Reopen" action={reopenComplaint} hidden={hidden} />}
        </div>} />

      {open && c.overdue && <Alert tone="error" className="mb-4">Past its due time ({formatDateTime(c.due_at)}).</Alert>}
      {c.qc_review_status === "requested" && (
        <Alert tone="warning" className="mb-4">Waiting for quality control to review batch {L.batch?.no}. It cannot be resolved until QC records its finding.</Alert>)}

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          <Card>
            <CardHeader title="Timeline" actions={manage && open && (
              <FormDialog trigger="Add note / photo" triggerSize="sm" title="Add to the timeline" submitLabel="Add" action={addComplaintNote} hidden={hidden}>
                <Field label="Note" htmlFor="nt-n"><Textarea id="nt-n" name="note" /></Field>
                <Field label="Photos" htmlFor="nt-p" hint="Up to 5"><Input id="nt-p" name="photos" type="file" accept="image/*" multiple className="py-1.5" /></Field>
              </FormDialog>)} />
            <CardBody>
              {c.description && <p className="mb-4 whitespace-pre-line text-sm">{c.description}</p>}
              <ol className="space-y-4">
                {d.events.map((e) => { const Icon = ICON[e.event] ?? CircleDot; return (
                  <li key={e.id} className="flex gap-3">
                    <Icon className="mt-0.5 h-4 w-4 shrink-0 text-ola-600" />
                    <div className="min-w-0 text-sm">
                      <p className="font-medium text-navy-900">
                        {e.event === "created" ? "Logged" : e.event === "status" ? `${statusBadge(COMPLAINT_STATUS, e.from_status ?? "").label} → ${statusBadge(COMPLAINT_STATUS, e.to_status ?? "").label}`
                          : e.event === "photo" ? "Photo added" : e.event === "qc_review" ? "Quality control" : e.event.charAt(0).toUpperCase() + e.event.slice(1)}
                        <span className="ml-2 text-xs font-normal text-muted">{e.by ?? ""} · {formatDateTime(e.created_at)}</span></p>
                      {e.note && <p className="whitespace-pre-line text-navy-800">{e.note}</p>}
                      {photos[e.id] && (
                        <a href={photos[e.id]} target="_blank" rel="noreferrer" className="mt-1 block w-40 overflow-hidden rounded-lg ring-1 ring-line">
                          {/* eslint-disable-next-line @next/next/no-img-element */}
                          <img src={photos[e.id]} alt="Complaint photo" className="h-28 w-40 object-cover" /></a>)}
                    </div>
                  </li>); })}
              </ol>
            </CardBody>
          </Card>
          {(c.resolution || c.qc_finding) && (
            <Card>
              <CardHeader title="Outcome" />
              <CardBody className="space-y-2 text-sm">
                {c.qc_finding && <p><span className="font-medium">QC finding:</span> {c.qc_finding}</p>}
                {c.resolution && <p><span className="font-medium">Resolution:</span> {c.resolution}</p>}
                {c.root_cause && <p><span className="font-medium">Cause:</span> {c.root_cause}</p>}
                {c.resolved_at && <p className="text-muted">Resolved {formatDateTime(c.resolved_at)}{new Date(c.resolved_at) <= new Date(c.due_at) ? " — within the due time" : " — after the due time"}.</p>}
              </CardBody>
            </Card>)}
        </div>

        <div className="space-y-6">
          <Card>
            <CardHeader title="Details" />
            <CardBody className="space-y-2 text-sm">
              <p><span className="text-muted">Handled by:</span> {c.assigned_name ?? "Not assigned"}</p>
              <p><span className="text-muted">Due:</span> {formatDateTime(c.due_at)}</p>
              <p><span className="text-muted">First response:</span> {c.first_response_at ? formatDateTime(c.first_response_at) : "—"}</p>
              <p><span className="text-muted">Received by:</span> {c.channel.replace("_", " ")}</p>
              {d.customer ? (
                <div className="border-t border-line pt-2">
                  <Link href={`/customers/${d.customer.id}`} className="font-medium text-ola-700 hover:underline">{d.customer.name}</Link>
                  <p className="text-muted">{d.customer.customer_no} · {formatPhone(d.customer.phone)}</p>
                  <p className="text-muted">Owes {formatLKR(d.customer.outstanding)} · {d.customer.complaints} complaint(s) in total</p>
                </div>
              ) : (c.contact_name || c.contact_phone) && <p className="border-t border-line pt-2">{c.contact_name} {c.contact_phone && formatPhone(c.contact_phone)}</p>}
            </CardBody>
          </Card>
          <Card>
            <CardHeader title="Linked to" />
            <CardBody className="space-y-1.5 text-sm">
              {L.order && <p>Order <Link href={`/orders/${L.order.id}`} className="font-mono text-ola-700 hover:underline">{L.order.no}</Link></p>}
              {L.delivery && <p>Delivery <Link href={`/dispatch/${L.delivery.run_id}`} className="font-mono text-ola-700 hover:underline">{L.delivery.no}</Link></p>}
              {L.invoice && <p>Invoice <span className="font-mono">{L.invoice.no}</span></p>}
              {L.batch && <p>Batch <Link href={`/production/${L.batch.id}`} className="font-mono text-ola-700 hover:underline">{L.batch.no}</Link> · {L.batch.product} ({L.batch.status?.replace("_", " ")})</p>}
              {L.bottle && <p>Bottle <span className="font-mono">{L.bottle.code}</span></p>}
              {L.product && <p>Product {L.product.name}</p>}
              {L.driver && <p>Driver {L.driver.name}</p>}
              {L.location && <p>At {L.location.name}</p>}
              {!Object.values(L).some(Boolean) && <p className="text-muted">Nothing linked.</p>}
              <div className="flex flex-wrap gap-2 pt-2">
                {manage && open && c.qc_review_status !== "requested" && (
                  <FormDialog trigger="Ask QC to review" triggerSize="sm" title="Quality control review" description="QC checks the batch (retained samples, re-test, hold or recall)." submitLabel="Ask QC" action={requestQcReview} hidden={hidden}>
                    <Field label="Batch no. (from the label)" htmlFor="qr-b"><Input id="qr-b" name="batch_no" defaultValue={L.batch?.no ?? ""} required /></Field>
                    <Field label="Note for QC" htmlFor="qr-n"><Input id="qr-n" name="note" /></Field>
                  </FormDialog>)}
                {can(access, "qc.manage") && c.qc_review_status === "requested" && (
                  <FormDialog trigger="Record QC finding" triggerVariant="primary" triggerSize="sm" title={`QC review — batch ${L.batch?.no ?? ""}`}
                    description="Hold, re-test or recall the batch from Quality Control if needed." submitLabel="Save finding" action={completeQcReview} hidden={hidden}>
                    <Field label="What QC found and did" htmlFor="qf-f" required><Textarea id="qf-f" name="finding" required /></Field>
                  </FormDialog>)}
              </div>
            </CardBody>
          </Card>
        </div>
      </div>
    </>
  );
}
