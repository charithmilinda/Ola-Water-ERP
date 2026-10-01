import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Download } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Textarea } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { DocumentUploadFields } from "@/components/documents/upload-fields";
import { archiveDocument, updateDocument, uploadDocument } from "../actions";

export const metadata: Metadata = { title: "Document" };

export default async function DocumentPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data: d } = await supabase.from("documents").select("*, category:document_categories(name, manage_permission, has_expiry)").eq("id", id).maybeSingle();
  if (!d) notFound();
  const cat = d.category as { name: string; manage_permission: string; has_expiry: boolean };
  const manage = can(access, cat.manage_permission) && d.status === "active";
  const [{ data: url }, { data: preview }, { data: older }, { data: newer }] = await Promise.all([
    supabase.storage.from("documents").createSignedUrl(d.file_path, 3600, { download: d.file_name }),
    supabase.storage.from("documents").createSignedUrl(d.file_path, 3600),
    d.replaces_id ? supabase.from("documents").select("id, doc_no, title, created_at, status").eq("id", d.replaces_id) : Promise.resolve({ data: [] }),
    supabase.from("documents").select("id, doc_no, title, created_at, status").eq("replaces_id", d.id),
  ]);
  const today = new Date().toISOString().slice(0, 10);
  const isImage = (d.mime_type ?? "").startsWith("image/");
  const isPdf = d.mime_type === "application/pdf";
  const hidden = { document_id: d.id };
  const entityHref = d.entity_type && d.entity_id ? ({ customer: `/customers/${d.entity_id}`, supplier: `/suppliers/${d.entity_id}`, employee: `/hr/${d.entity_id}`,
    vehicle: `/fleet/${d.entity_id}`, asset: `/assets/${d.entity_id}`, batch: `/production/${d.entity_id}`, shop: `/shops/${d.entity_id}` } as Record<string, string>)[d.entity_type] : null;

  return (
    <>
      <Link href="/documents" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Documents</Link>
      <PageHeader title={d.title} description={`${d.doc_no} · ${cat.name}${d.reference_no ? ` · ${d.reference_no}` : ""}`}
        actions={<div className="flex flex-wrap gap-2">
          {url?.signedUrl && <a href={url.signedUrl} className={buttonVariants({ variant: "primary", size: "md" })}><Download className="h-4 w-4" /> Download</a>}
          {manage && <>
            <FormDialog trigger="New version" triggerSize="md" title="Upload a new version" description="The current file is kept as an old version." submitLabel="Upload"
              action={uploadDocument} wide>
              <DocumentUploadFields categories={[]} replacing={{ id: d.id, category: d.category_code, title: d.title }} />
            </FormDialog>
            <FormDialog trigger="Edit" triggerSize="md" title="Edit details" submitLabel="Save" action={updateDocument} hidden={hidden}>
              <Field label="Title" htmlFor="de-t"><Input id="de-t" name="title" defaultValue={d.title} /></Field>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Reference no." htmlFor="de-r"><Input id="de-r" name="reference_no" defaultValue={d.reference_no ?? ""} /></Field>
                <Field label="Warn (days before)" htmlFor="de-a"><Input id="de-a" name="alert_days" type="number" min={0} max={365} defaultValue={d.alert_days} /></Field>
                <Field label="Issued on" htmlFor="de-i"><Input id="de-i" name="issued_on" type="date" defaultValue={d.issued_on ?? ""} /></Field>
                <Field label="Expires on" htmlFor="de-e"><Input id="de-e" name="expires_on" type="date" defaultValue={d.expires_on ?? ""} /></Field>
              </div>
              <Field label="Notes" htmlFor="de-n"><Textarea id="de-n" name="notes" defaultValue={d.notes ?? ""} /></Field>
              <Field label="Reason for change" htmlFor="de-rs"><Input id="de-rs" name="reason" /></Field>
            </FormDialog>
            <ReasonDialog trigger="Archive" triggerVariant="dangerOutline" triggerSize="md" title="Archive this document" description="It disappears from the current list but is kept."
              confirmLabel="Archive" confirmVariant="danger" action={archiveDocument} hidden={hidden} />
          </>}
        </div>} />

      {d.status !== "active" && <Alert tone="info" className="mb-4">This is {d.status === "replaced" ? "an old version" : "archived"}.</Alert>}
      {d.status === "active" && d.expires_on && d.expires_on < today && <Alert tone="error" className="mb-4">Expired on {formatDate(d.expires_on)} — upload the renewed document as a new version.</Alert>}

      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title={d.file_name} />
          <CardBody>
            {preview?.signedUrl && isImage && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={preview.signedUrl} alt={d.title} className="max-h-[70vh] rounded-lg ring-1 ring-line" />)}
            {preview?.signedUrl && isPdf && <iframe src={preview.signedUrl} title={d.title} className="h-[70vh] w-full rounded-lg ring-1 ring-line" />}
            {!isImage && !isPdf && <p className="text-sm text-muted">No preview for this type of file — use Download.</p>}
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="Details" />
          <CardBody className="space-y-2 text-sm">
            <p><span className="text-muted">Belongs to:</span> {entityHref ? <Link href={entityHref} className="text-ola-700 hover:underline">{d.entity_type}</Link> : d.entity_type === "company" ? "Company" : "—"}</p>
            <p><span className="text-muted">Issued:</span> {d.issued_on ? formatDate(d.issued_on) : "—"}</p>
            <p><span className="text-muted">Expires:</span> {d.expires_on ? formatDate(d.expires_on) : "—"} {d.expires_on && `(warn ${d.alert_days} days before)`}</p>
            <p><span className="text-muted">Added:</span> {formatDateTime(d.created_at)}</p>
            {d.notes && <p className="whitespace-pre-line">{d.notes}</p>}
            {(older ?? []).concat(newer ?? []).length > 0 && (
              <div className="border-t border-line pt-2">
                <p className="mb-1 font-medium">Other versions</p>
                {(newer ?? []).map((v) => <p key={v.id}><Link href={`/documents/${v.id}`} className="text-ola-700 hover:underline">{v.doc_no}</Link> newer <Badge tone="green">{v.status}</Badge></p>)}
                {(older ?? []).map((v) => <p key={v.id}><Link href={`/documents/${v.id}`} className="text-ola-700 hover:underline">{v.doc_no}</Link> older ({formatDate(v.created_at)})</p>)}
              </div>)}
          </CardBody>
        </Card>
      </div>
    </>
  );
}
