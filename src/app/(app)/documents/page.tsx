import type { Metadata } from "next";
import Link from "next/link";
import { FileText, Plus } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { formatDate } from "@/lib/format";
import { DOC_ENTITY_TYPES } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Input } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { DocumentUploadFields } from "@/components/documents/upload-fields";
import { uploadDocument } from "./actions";

export const metadata: Metadata = { title: "Documents" };

type Doc = { id: string; doc_no: string; title: string; reference_no: string | null; category_code: string; entity_type: string | null; entity_id: string | null;
  file_name: string; expires_on: string | null; status: string; created_at: string; category: { name: string } | null };
type Expiring = { source: string; id: string; title: string; category: string; reference_no: string | null; expires_on: string; days_left: number; href: string };

const VIEW_PERMS = ["documents.view", "hr.view", "fleet.manage", "qc.view", "procurement.view", "payments.view"];

export default async function DocumentsPage({ searchParams }: { searchParams: Promise<{ show?: string; cat?: string; q?: string }> }) {
  const access = await getAccess();
  if (!can(access, VIEW_PERMS)) redirect("/forbidden");
  const sp = await searchParams;
  const show = ["all", "expiring", "archived"].includes(sp.show ?? "") ? sp.show! : "all";
  const supabase = await createClient();
  const { data: cats } = await supabase.from("document_categories").select("code, name, has_expiry, view_permission, manage_permission").eq("is_active", true).order("sort_order");
  const visible = (cats ?? []).filter((c) => can(access, c.view_permission));
  const uploadable = (cats ?? []).filter((c) => can(access, c.manage_permission));
  let q = supabase.from("documents").select("id, doc_no, title, reference_no, category_code, entity_type, entity_id, file_name, expires_on, status, created_at, category:document_categories(name)")
    .order("created_at", { ascending: false }).limit(300);
  q = show === "archived" ? q.in("status", ["archived", "replaced"]) : q.eq("status", "active");
  if (sp.cat) q = q.eq("category_code", sp.cat);
  if (sp.q?.trim()) { const t = sp.q.trim().replace(/[,()%]/g, ""); q = q.or(`title.ilike.%${t}%,reference_no.ilike.%${t}%,doc_no.ilike.%${t}%`); }
  const [{ data: docs }, { data: expiring }, { data: suppliers }, { data: vehicles }, { data: assets }, { data: shops }, { data: employees }] = await Promise.all([
    q, supabase.rpc("expiring_documents", { p_days: 60 }),
    can(access, "procurement.manage") ? supabase.from("suppliers").select("id, name").eq("is_active", true).order("name") : Promise.resolve({ data: [] }),
    can(access, "fleet.manage") ? supabase.from("vehicles").select("id, registration_no").eq("is_active", true).order("registration_no") : Promise.resolve({ data: [] }),
    can(access, ["assets.manage", "documents.manage"]) ? supabase.from("fixed_assets").select("id, asset_no, name").eq("status", "active").order("asset_no") : Promise.resolve({ data: [] }),
    can(access, "documents.manage") ? supabase.from("water_shops").select("id, name").order("name") : Promise.resolve({ data: [] }),
    can(access, "hr.manage") ? supabase.rpc("employee_directory") : Promise.resolve({ data: [] }),
  ]);
  const exp = (expiring ?? []) as Expiring[];
  const list = (docs ?? []) as unknown as Doc[];
  const entities = [
    { type: "supplier", options: (suppliers ?? []).map((s: { id: string; name: string }) => ({ id: s.id, name: s.name })) },
    { type: "employee", options: ((employees ?? []) as { id: string; full_name: string; status: string }[]).filter((e) => e.status === "active").map((e) => ({ id: e.id, name: e.full_name })) },
    { type: "vehicle", options: (vehicles ?? []).map((v: { id: string; registration_no: string }) => ({ id: v.id, name: v.registration_no })) },
    { type: "asset", options: (assets ?? []).map((a: { id: string; asset_no: string; name: string }) => ({ id: a.id, name: `${a.asset_no} ${a.name}` })) },
    { type: "shop", options: (shops ?? []).map((s: { id: string; name: string }) => ({ id: s.id, name: s.name })) },
  ].filter((e) => e.options.length > 0);
  const entityLabel = Object.fromEntries(DOC_ENTITY_TYPES);
  const today = new Date().toISOString().slice(0, 10);
  const entityHref = (t: string | null, id: string | null) => !t || !id ? null
    : ({ customer: `/customers/${id}`, supplier: `/suppliers/${id}`, employee: `/hr/${id}`, vehicle: `/fleet/${id}`, asset: `/assets/${id}`, batch: `/production/${id}`, shop: `/shops/${id}` } as Record<string, string>)[t] ?? null;

  return (
    <>
      <PageHeader title="Documents" description="Contracts, licences, insurance, employee papers, lab reports and other files — private, visible only to the people allowed to see each type."
        actions={uploadable.length > 0 && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> Upload</>} triggerVariant="primary" triggerSize="md" title="Upload a document" submitLabel="Upload"
            action={uploadDocument} wide>
            <DocumentUploadFields categories={uploadable} defaultCategory={sp.cat} entities={entities} />
          </FormDialog>)} />

      <div className="mb-6 grid gap-4 sm:grid-cols-3">
        <Stat label="Expired" value={exp.filter((e) => e.days_left < 0).length} hint="Renew these now" />
        <Stat label="Expiring in 30 days" value={exp.filter((e) => e.days_left >= 0 && e.days_left <= 30).length} hint="Includes vehicle documents" />
        <Stat label="Documents" value={show === "all" ? list.length : "—"} hint={`${visible.length} type(s) you can see`} />
      </div>

      <div className="mb-4 flex flex-wrap items-center gap-1">
        {[["all", "Current"], ["expiring", "Expiring"], ["archived", "Old versions & archived"]].map(([k, l]) => (
          <Link key={k} href={`/documents?show=${k}`} className={buttonVariants({ variant: k === show ? "primary" : "secondary", size: "sm" })}>{l}</Link>))}
      </div>

      {show === "expiring" ? (
        <Card>
          <CardHeader title="Expired or expiring within 60 days" />
          {exp.length === 0 ? <EmptyState icon={FileText} title="Nothing expiring soon" /> : (
            <Table>
              <thead><tr><Th>Document</Th><Th>Type</Th><Th>Expires</Th><Th>Days left</Th></tr></thead>
              <tbody>{exp.map((e) => (
                <tr key={`${e.source}-${e.id}-${e.title}`}>
                  <Td><Link href={e.href} className="font-medium text-ola-700 hover:underline">{e.title}</Link>{e.reference_no && <span className="block text-xs text-muted">{e.reference_no}</span>}</Td>
                  <Td>{e.category}</Td><Td>{formatDate(e.expires_on)}</Td>
                  <Td>{e.days_left < 0 ? <Badge tone="red">Expired {-e.days_left} d ago</Badge> : e.days_left <= 30 ? <Badge tone="amber">{e.days_left} d</Badge> : `${e.days_left} d`}</Td>
                </tr>))}</tbody>
            </Table>)}
        </Card>
      ) : (
        <Card>
          <CardHeader title={show === "archived" ? "Old versions & archived" : "Documents"} actions={<form className="flex flex-wrap items-center gap-1">
            <input type="hidden" name="show" value={show} />
            <select name="cat" defaultValue={sp.cat ?? ""} className="h-8 rounded-lg border border-line bg-white px-2 text-sm" aria-label="Type">
              <option value="">All types</option>{visible.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</select>
            <Input name="q" defaultValue={sp.q} placeholder="Search" className="h-8 w-40" aria-label="Search" />
            <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Show</button></form>} />
          {list.length === 0 ? <EmptyState icon={FileText} title="No documents here" description={uploadable.length ? "Use Upload to add the first one." : undefined} /> : (
            <Table>
              <thead><tr><Th>Document</Th><Th>Type</Th><Th>Belongs to</Th><Th>Expires</Th><Th>Added</Th></tr></thead>
              <tbody>{list.map((d) => { const href = entityHref(d.entity_type, d.entity_id); return (
                <tr key={d.id}>
                  <Td><Link href={`/documents/${d.id}`} className="font-medium text-ola-700 hover:underline">{d.title}</Link>
                    <span className="block text-xs text-muted">{d.doc_no}{d.reference_no ? ` · ${d.reference_no}` : ""} · {d.file_name}</span></Td>
                  <Td>{d.category?.name}</Td>
                  <Td>{href ? <Link href={href} className="hover:underline">{entityLabel[d.entity_type!] ?? d.entity_type}</Link> : d.entity_type === "company" ? "Company" : "—"}</Td>
                  <Td className={d.expires_on && d.expires_on < today ? "font-semibold text-red-700" : ""}>{d.expires_on ? formatDate(d.expires_on) : "—"}</Td>
                  <Td className="whitespace-nowrap">{formatDate(d.created_at)}{d.status !== "active" && <Badge tone="neutral" className="ml-1">{d.status}</Badge>}</Td>
                </tr>); })}</tbody>
            </Table>)}
        </Card>
      )}
    </>
  );
}
