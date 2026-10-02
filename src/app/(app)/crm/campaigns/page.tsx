import type { Metadata } from "next";
import { Megaphone, Plus } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { CAMPAIGN_CHANNELS, CAMPAIGN_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { CrmTabs } from "../crm-tabs";
import { saveCampaign, sendCampaignMessage } from "../actions";

export const metadata: Metadata = { title: "Campaigns" };

type Row = { id: string; code: string; name: string; channel: string; status: string; start_date: string; end_date: string | null; budget: number; spent: number;
  segment: string | null; segment_size: number | null; promotion: string | null; leads: number; won: number; new_customers: number; revenue: number;
  messages_sent: number; messages_failed: number; promo_discount: number; cost_per_customer: number | null };
type Camp = { id: string; code: string; name: string; channel: string; objective: string | null; segment_id: string | null; promotion_id: string | null;
  start_date: string; end_date: string | null; budget: number; spent: number; status: string; notes: string | null };
type Opt = { id: string; name: string };

function CampaignFields({ c, segments, promos, today }: { c?: Camp; segments: Opt[]; promos: Opt[]; today: string }) {
  const k = c?.id ?? "new";
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Code" htmlFor={`cg-c-${k}`} required><Input id={`cg-c-${k}`} name="code" required defaultValue={c?.code} placeholder="AVURUDU26" /></Field>
        <Field label="Name" htmlFor={`cg-n-${k}`} required className="sm:col-span-2"><Input id={`cg-n-${k}`} name="name" required defaultValue={c?.name} /></Field>
        <Field label="Channel" htmlFor={`cg-ch-${k}`}><Select id={`cg-ch-${k}`} name="channel" defaultValue={c?.channel ?? "sms"}>{CAMPAIGN_CHANNELS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
        <Field label="From" htmlFor={`cg-f-${k}`}><Input id={`cg-f-${k}`} name="start_date" type="date" defaultValue={c?.start_date ?? today} /></Field>
        <Field label="Until" htmlFor={`cg-u-${k}`}><Input id={`cg-u-${k}`} name="end_date" type="date" defaultValue={c?.end_date ?? ""} /></Field>
        <Field label="Customer segment" htmlFor={`cg-s-${k}`} hint="Who gets campaign messages"><Select id={`cg-s-${k}`} name="segment_id" defaultValue={c?.segment_id ?? ""}><option value="">—</option>{segments.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="Promotion" htmlFor={`cg-p-${k}`}><Select id={`cg-p-${k}`} name="promotion_id" defaultValue={c?.promotion_id ?? ""}><option value="">—</option>{promos.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        {c && <Field label="Status" htmlFor={`cg-st-${k}`}><Select id={`cg-st-${k}`} name="status" defaultValue={c.status}>{Object.entries(CAMPAIGN_STATUS).map(([v, s]) => <option key={v} value={v}>{s.label}</option>)}</Select></Field>}
        <Field label="Budget (Rs.)" htmlFor={`cg-b-${k}`}><Input id={`cg-b-${k}`} name="budget" type="number" min={0} step="100" defaultValue={c?.budget ?? ""} /></Field>
        <Field label="Spent so far (Rs.)" htmlFor={`cg-sp-${k}`}><Input id={`cg-sp-${k}`} name="spent" type="number" min={0} step="100" defaultValue={c?.spent ?? ""} /></Field>
      </div>
      <Field label="Goal" htmlFor={`cg-o-${k}`}><Input id={`cg-o-${k}`} name="objective" defaultValue={c?.objective ?? ""} placeholder="e.g. 50 new households in Kandy" /></Field>
      <Field label="Notes" htmlFor={`cg-no-${k}`}><Textarea id={`cg-no-${k}`} name="notes" defaultValue={c?.notes ?? ""} /></Field>
    </>
  );
}

export default async function CampaignsPage() {
  await requirePermission("crm.manage");
  const supabase = await createClient();
  const today = todayISO();
  const [{ data: perf }, { data: camps }, { data: segments }, { data: promos }] = await Promise.all([
    supabase.rpc("campaign_performance"), supabase.from("campaigns").select("*"),
    supabase.from("customer_segments").select("id, name").eq("is_active", true).order("name"),
    supabase.from("promotions").select("id, name").neq("status", "ended").order("name"),
  ]);
  const rows = (perf ?? []) as Row[];
  const byId = Object.fromEntries(((camps ?? []) as Camp[]).map((c) => [c.id, c]));

  return (
    <>
      <PageHeader title="Leads & CRM" description="Campaigns — what you did to win customers, what it cost and what it brought in. Leads and new customers are linked to the campaign that found them."
        actions={<FormDialog trigger={<><Plus className="h-4 w-4" /> New campaign</>} triggerVariant="primary" triggerSize="md" title="New campaign" submitLabel="Save" action={saveCampaign} wide>
          <CampaignFields segments={segments ?? []} promos={promos ?? []} today={today} /></FormDialog>} />
      <CrmTabs active="/crm/campaigns" />
      <div className="mb-6 grid gap-4 sm:grid-cols-3">
        <Stat label="Running" value={rows.filter((r) => r.status === "active").length} />
        <Stat label="New customers from campaigns" value={rows.reduce((a, r) => a + r.new_customers, 0)} hint={`${rows.reduce((a, r) => a + r.leads, 0)} leads`} />
        <Stat label="Sales from those customers" value={formatLKR(rows.reduce((a, r) => a + Number(r.revenue), 0))} hint={`Spent ${formatLKR(rows.reduce((a, r) => a + Number(r.spent), 0))}`} />
      </div>
      <Card>
        <CardHeader title="Campaigns" />
        {rows.length === 0 ? <EmptyState icon={Megaphone} title="No campaigns yet" /> : (
          <Table>
            <thead><tr><Th>Campaign</Th><Th>Reach</Th><Th className="text-right">Leads → won</Th><Th className="text-right">New customers</Th><Th className="text-right">Their sales</Th>
              <Th className="text-right">Spent</Th><Th>Status</Th><Th /></tr></thead>
            <tbody>{rows.map((r) => { const st = statusBadge(CAMPAIGN_STATUS, r.status); const c = byId[r.id]; return (
              <tr key={r.id}>
                <Td><span className="font-medium">{r.name}</span><span className="block text-xs text-muted">{r.code} · {CAMPAIGN_CHANNELS.find(([k]) => k === r.channel)?.[1]} · {formatDate(r.start_date)}{r.end_date ? ` – ${formatDate(r.end_date)}` : ""}</span>
                  {r.promotion && <span className="block text-xs text-muted">Promotion: {r.promotion}{Number(r.promo_discount) ? ` (${formatLKR(r.promo_discount)} given)` : ""}</span>}</Td>
                <Td className="text-sm">{r.segment ? `${r.segment} (${r.segment_size})` : "—"}{(r.messages_sent > 0 || r.messages_failed > 0) && <span className="block text-xs text-muted">{r.messages_sent} sent · {r.messages_failed} failed</span>}</Td>
                <Td className="num text-right">{r.leads} → {r.won}</Td>
                <Td className="num text-right">{r.new_customers}{r.cost_per_customer !== null && <span className="block text-xs text-muted">{formatLKR(r.cost_per_customer)} each</span>}</Td>
                <Td className="num text-right">{formatLKR(r.revenue)}</Td>
                <Td className="num text-right">{formatLKR(r.spent)}<span className="block text-xs text-muted">of {formatLKR(r.budget)}</span></Td>
                <Td><Badge tone={st.tone}>{st.label}</Badge></Td>
                <Td className="space-x-1 whitespace-nowrap text-right">
                  {c && <FormDialog trigger="Edit" triggerVariant="ghost" title={r.name} submitLabel="Save" action={saveCampaign} hidden={{ id: r.id }} wide>
                    <CampaignFields c={c} segments={segments ?? []} promos={promos ?? []} today={today} /></FormDialog>}
                  {r.segment && ["planned", "active"].includes(r.status) && (
                    <FormDialog trigger="Send message" triggerVariant="secondary" title={`Message — ${r.name}`}
                      description={`Goes once to each of the ${r.segment_size} customer(s) in "${r.segment}" who have not opted out. Customer messages must be on.`}
                      submitLabel="Queue messages" action={sendCampaignMessage} hidden={{ campaign_id: r.id }}>
                      <Field label="Message" htmlFor={`cm-${r.id}`} hint="{{customer_name}} and {{company_phone}} are filled in. 160 characters = 1 SMS.">
                        <Textarea id={`cm-${r.id}`} name="body" rows={4} maxLength={480} required defaultValue={"Dear {{customer_name}}, "} /></Field>
                    </FormDialog>)}
                </Td>
              </tr>); })}</tbody>
          </Table>)}
      </Card>
    </>
  );
}
