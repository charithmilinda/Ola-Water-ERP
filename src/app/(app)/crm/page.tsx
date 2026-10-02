import type { Metadata } from "next";
import Link from "next/link";
import { Plus, Target } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatPhone, todayISO } from "@/lib/format";
import { LEAD_SOURCES, LEAD_STATUS, OPP_STAGE, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Input } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { CrmTabs } from "./crm-tabs";
import { LeadFields } from "./lead-fields";
import { createLead } from "./actions";

export const metadata: Metadata = { title: "Leads & CRM" };

const FILTERS = [["open", "Open"], ["mine", "Mine"], ["due", "Follow-up due"], ["won", "Won"], ["lost", "Lost"], ["all", "All"]] as const;
type Lead = { id: string; lead_no: string; name: string; company_name: string | null; phone: string | null; city: string | null; status: string; source: string;
  est_monthly_value: number | null; next_follow_up: string | null; owner_id: string | null; created_at: string };
type Overview = { pipeline: Record<string, { count: number; value: number }>; opportunities: Record<string, { count: number; value: number; weighted: number }>;
  follow_ups_due: number; my_follow_ups: number; conversion_90d: { leads: number; won: number; lost: number; rate: number | null };
  by_source: { source: string; leads: number; won: number }[] };

export default async function CrmPage({ searchParams }: { searchParams: Promise<{ show?: string; q?: string }> }) {
  const access = await getAccess();
  if (!can(access, ["crm.manage", "sales_reps.manage"])) redirect("/forbidden");
  const sp = await searchParams;
  const show = FILTERS.some(([k]) => k === sp.show) ? sp.show! : "open";
  const today = todayISO();
  const supabase = await createClient();
  let q = supabase.from("leads").select("id, lead_no, name, company_name, phone, city, status, source, est_monthly_value, next_follow_up, owner_id, created_at")
    .order("next_follow_up", { ascending: true, nullsFirst: false }).order("created_at", { ascending: false }).limit(300);
  if (show === "open") q = q.not("status", "in", "(won,lost)");
  if (show === "mine") q = q.not("status", "in", "(won,lost)").eq("owner_id", access.user_id);
  if (show === "due") q = q.not("status", "in", "(won,lost)").lte("next_follow_up", today);
  if (show === "won" || show === "lost") q = q.eq("status", show);
  if (sp.q?.trim()) { const t = sp.q.trim().replace(/[,()%]/g, ""); q = q.or(`name.ilike.%${t}%,company_name.ilike.%${t}%,lead_no.ilike.%${t}%,city.ilike.%${t}%`); }
  const [{ data: leads }, { data: ov }, { data: staff }, { data: campaigns }, { data: territories }, { data: opps }] = await Promise.all([
    q, supabase.rpc("crm_overview"), supabase.rpc("staff_directory"),
    supabase.from("campaigns").select("id, name").in("status", ["planned", "active"]).order("start_date", { ascending: false }),
    supabase.from("territories").select("id, name").eq("is_active", true).order("name"),
    supabase.from("opportunities").select("id, opp_no, title, stage, monthly_value, probability, expected_close, lead_id, customer_id, owner_id")
      .not("stage", "in", "(won,lost)").order("expected_close", { nullsFirst: false }).limit(50),
  ]);
  const o = (ov ?? null) as Overview | null;
  const names = Object.fromEntries(((staff ?? []) as { id: string; full_name: string }[]).map((s) => [s.id, s.full_name]));
  const staffOpts = ((staff ?? []) as { id: string; full_name: string }[]).map((s) => ({ id: s.id, name: s.full_name }));
  const list = (leads ?? []) as Lead[];
  const stageCount = (k: string) => o?.pipeline?.[k]?.count ?? 0;
  const srcLabel = Object.fromEntries(LEAD_SOURCES) as Record<string, string>;
  const openOpps = Object.entries(o?.opportunities ?? {}).filter(([k]) => !["won", "lost"].includes(k));

  return (
    <>
      <PageHeader title="Leads & CRM" description="Possible customers from calls, walk-ins, referrals and campaigns — follow them up until they order, then make them customers."
        actions={can(access, "crm.manage") && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New lead</>} triggerVariant="primary" triggerSize="md" title="New lead" submitLabel="Save lead" action={createLead} wide>
            <LeadFields staff={staffOpts} campaigns={campaigns ?? []} territories={territories ?? []} />
          </FormDialog>)} />
      <CrmTabs active="/crm" />

      {o && (
        <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Stat label="Open leads" value={stageCount("new") + stageCount("contacted") + stageCount("qualified") + stageCount("proposal")}
            hint={`${stageCount("new")} new · ${stageCount("contacted")} contacted · ${stageCount("qualified")} prospects · ${stageCount("proposal")} offers`} />
          <Stat label="Follow-ups due" value={o.follow_ups_due} hint={`${o.my_follow_ups} for you`} />
          <Stat label="Won in 90 days" value={o.conversion_90d.won} hint={o.conversion_90d.rate !== null ? `${o.conversion_90d.rate}% of closed leads won` : `${o.conversion_90d.leads} new leads`} />
          <Stat label="Open opportunities" value={formatLKR(openOpps.reduce((a, [, v]) => a + Number(v.weighted), 0))}
            hint={`a month, weighted by chance · ${openOpps.reduce((a, [, v]) => a + v.count, 0)} open`} />
        </div>)}

      <Card className="mb-6">
        <CardHeader title="Leads" actions={<div className="flex flex-wrap items-center gap-1">
          {FILTERS.map(([k, l]) => <Link key={k} href={`/crm?show=${k}`} className={buttonVariants({ variant: k === show ? "primary" : "secondary", size: "sm" })}>{l}</Link>)}
          <form className="flex items-center gap-1"><input type="hidden" name="show" value={show} /><Input name="q" defaultValue={sp.q} placeholder="Search" className="h-8 w-40" aria-label="Search" /></form>
        </div>} />
        {list.length === 0 ? <EmptyState icon={Target} title="No leads here" /> : (
          <Table>
            <thead><tr><Th>Lead</Th><Th>Stage</Th><Th>From</Th><Th className="text-right">Worth a month</Th><Th>Owner</Th><Th>Follow up</Th></tr></thead>
            <tbody>{list.map((l) => { const st = statusBadge(LEAD_STATUS, l.status); const due = l.next_follow_up && l.next_follow_up <= today; return (
              <tr key={l.id} className="hover:bg-ola-50/40">
                <Td><Link href={`/crm/leads/${l.id}`} className="font-medium text-ola-700 hover:underline">{l.name}</Link>
                  <span className="block text-xs text-muted">{[l.lead_no, l.company_name, l.city, l.phone && formatPhone(l.phone)].filter(Boolean).join(" · ")}</span></Td>
                <Td><Badge tone={st.tone}>{st.label}</Badge></Td>
                <Td className="text-sm">{srcLabel[l.source] ?? l.source}</Td>
                <Td className="num text-right">{l.est_monthly_value ? formatLKR(l.est_monthly_value) : "—"}</Td>
                <Td className="text-sm">{l.owner_id ? names[l.owner_id] ?? "—" : "—"}</Td>
                <Td className={due ? "font-semibold text-red-700" : ""}>{l.next_follow_up ? formatDate(l.next_follow_up) : "—"}</Td>
              </tr>); })}</tbody>
          </Table>)}
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Open opportunities" description="Bigger deals (offices, hotels, dispensers) with a value and a chance of winning." />
          <Table><tbody>{(opps ?? []).map((x) => { const st = statusBadge(OPP_STAGE, x.stage); return (
            <tr key={x.id}><Td><Link href={x.lead_id ? `/crm/leads/${x.lead_id}` : `/customers/${x.customer_id}`} className="font-medium text-ola-700 hover:underline">{x.title}</Link>
              <span className="block text-xs text-muted">{x.opp_no}{x.owner_id ? ` · ${names[x.owner_id] ?? ""}` : ""}{x.expected_close ? ` · close by ${formatDate(x.expected_close)}` : ""}</span></Td>
              <Td><Badge tone={st.tone}>{st.label}</Badge></Td><Td className="num text-right">{formatLKR(x.monthly_value)}<span className="block text-xs text-muted">{x.probability}%</span></Td></tr>); })}
            {(opps ?? []).length === 0 && <tr><Td className="text-muted">None open.</Td></tr>}</tbody></Table>
        </Card>
        <Card>
          <CardHeader title="Where leads come from (6 months)" />
          <Table><tbody>{(o?.by_source ?? []).map((s) => (
            <tr key={s.source}><Td>{srcLabel[s.source] ?? s.source}</Td><Td className="num text-right">{s.leads} leads</Td>
              <Td className="num text-right">{s.won} won{s.leads ? ` (${Math.round((s.won / s.leads) * 100)}%)` : ""}</Td></tr>))}
            {(o?.by_source ?? []).length === 0 && <tr><Td className="text-muted">No leads yet.</Td></tr>}</tbody></Table>
        </Card>
      </div>
    </>
  );
}
