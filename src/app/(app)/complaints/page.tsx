import type { Metadata } from "next";
import Link from "next/link";
import { MessageSquareWarning, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDateTime, todayISO } from "@/lib/format";
import { COMPLAINT_STATUS, PRIORITY, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Input } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { ComplaintFields, loadComplaintFormData } from "./complaint-fields";
import { logComplaint } from "./actions";

export const metadata: Metadata = { title: "Complaints" };

const FILTERS = [["open", "Open"], ["overdue", "Overdue"], ["mine", "Mine"], ["new", "Not assigned"], ["qc", "QC review"], ["resolved", "Resolved"], ["all", "All"]] as const;

type Row = { id: string; complaint_no: string; subject: string; status: string; priority: string; channel: string; due_at: string; created_at: string;
  resolved_at: string | null; qc_review_status: string | null; contact_name: string | null;
  category: { name: string } | null; customer: { id: string; name: string } | null };

export default async function ComplaintsPage({ searchParams }: { searchParams: Promise<{ show?: string; q?: string }> }) {
  const access = await requirePermission(["complaints.view", "complaints.manage", "qc.manage"]);
  const sp = await searchParams;
  const show = FILTERS.some(([k]) => k === sp.show) ? sp.show! : "open";
  const supabase = await createClient();
  const today = todayISO();
  const monthAgo = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  let q = supabase.from("complaints").select("id, complaint_no, subject, status, priority, channel, due_at, created_at, resolved_at, qc_review_status, contact_name, assigned_to, category:complaint_categories(name), customer:customers(id, name)")
    .order("created_at", { ascending: false }).limit(200);
  if (show === "open") q = q.not("status", "in", "(resolved,closed)");
  if (show === "overdue") q = q.not("status", "in", "(resolved,closed)").lt("due_at", new Date().toISOString());
  if (show === "mine") q = q.not("status", "in", "(resolved,closed)").eq("assigned_to", access.user_id);
  if (show === "new") q = q.eq("status", "new");
  if (show === "qc") q = q.eq("qc_review_status", "requested");
  if (show === "resolved") q = q.in("status", ["resolved", "closed"]);
  if (sp.q?.trim()) q = q.or(`complaint_no.ilike.%${sp.q.trim().replace(/[,()%]/g, "")}%,subject.ilike.%${sp.q.trim().replace(/[,()%]/g, "")}%`);
  const [{ data: rows }, { data: summary }, form, { data: staff }] = await Promise.all([
    q, supabase.rpc("complaints_summary", { p_from: monthAgo, p_to: today }),
    can(access, ["complaints.manage", "complaints.view"]) ? loadComplaintFormData(supabase) : Promise.resolve(null),
    supabase.rpc("staff_directory"),
  ]);
  const names = Object.fromEntries(((staff ?? []) as { id: string; full_name: string }[]).map((s) => [s.id, s.full_name]));
  const list = (rows ?? []) as unknown as (Row & { assigned_to: string | null })[];
  const who = Object.fromEntries(list.map((a) => [a.id, a.assigned_to ? names[a.assigned_to] ?? "—" : null]));
  const s = (summary ?? {}) as { open?: number; overdue?: number; unassigned?: number; qc_review?: number; resolved?: number; within_sla_pct?: number | null;
    avg_hours_to_resolve?: number | null; by_category?: { category: string; count: number }[] };
  const now = Date.now();

  return (
    <>
      <PageHeader title="Complaints" description="Every customer complaint from first call to closure, with a due time by priority. Quality complaints about a batch go to QC for review."
        actions={form && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> Log a complaint</>} triggerVariant="primary" triggerSize="md" title="Log a complaint" submitLabel="Save complaint" action={logComplaint} wide>
            <ComplaintFields data={form} />
          </FormDialog>)} />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Open" value={s.open ?? 0} hint={`${s.unassigned ?? 0} not assigned yet`} />
        <Stat label="Past due time" value={s.overdue ?? 0} hint={`${s.qc_review ?? 0} waiting for QC review`} />
        <Stat label="Resolved in 30 days" value={s.resolved ?? 0} hint={s.within_sla_pct !== null && s.within_sla_pct !== undefined ? `${s.within_sla_pct}% within the due time` : undefined} />
        <Stat label="Average time to resolve" value={s.avg_hours_to_resolve ? `${s.avg_hours_to_resolve} h` : "—"}
          hint={(s.by_category ?? []).slice(0, 2).map((c) => `${c.category.split(" (")[0]}: ${c.count}`).join(" · ") || undefined} />
      </div>

      <Card>
        <CardHeader title="Complaints" actions={<div className="flex flex-wrap items-center gap-1">
          {FILTERS.map(([k, l]) => <Link key={k} href={`/complaints?show=${k}`} className={buttonVariants({ variant: k === show ? "primary" : "secondary", size: "sm" })}>{l}</Link>)}
          <form className="flex items-center gap-1"><input type="hidden" name="show" value={show} />
            <Input name="q" defaultValue={sp.q} placeholder="Number or words" className="h-8 w-44" aria-label="Search" /></form></div>} />
        {list.length === 0 ? <EmptyState icon={MessageSquareWarning} title="No complaints here" /> : (
          <Table>
            <thead><tr><Th>Complaint</Th><Th>Customer</Th><Th>Priority</Th><Th>Handled by</Th><Th>Due</Th><Th>Status</Th></tr></thead>
            <tbody>{list.map((c) => {
              const st = statusBadge(COMPLAINT_STATUS, c.status); const pr = statusBadge(PRIORITY, c.priority);
              const open = !["resolved", "closed"].includes(c.status); const late = open && new Date(c.due_at).getTime() < now;
              return (
                <tr key={c.id} className="hover:bg-ola-50/40">
                  <Td><Link href={`/complaints/${c.id}`} className="font-medium text-ola-700 hover:underline">{c.subject}</Link>
                    <span className="block text-xs text-muted"><span className="font-mono">{c.complaint_no}</span> · {c.category?.name} · {formatDateTime(c.created_at)}</span></Td>
                  <Td>{c.customer ? <Link href={`/customers/${c.customer.id}`} className="hover:underline">{c.customer.name}</Link> : c.contact_name ?? "—"}</Td>
                  <Td><Badge tone={pr.tone}>{pr.label}</Badge></Td>
                  <Td>{who[c.id] ?? <span className="text-muted">Not assigned</span>}</Td>
                  <Td className={`whitespace-nowrap ${late ? "font-semibold text-red-700" : ""}`}>{open ? formatDateTime(c.due_at) : c.resolved_at ? `Done ${formatDateTime(c.resolved_at)}` : "—"}</Td>
                  <Td><Badge tone={st.tone}>{st.label}</Badge>{c.qc_review_status === "requested" && <Badge tone="amber" className="ml-1">QC review</Badge>}</Td>
                </tr>); })}</tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
