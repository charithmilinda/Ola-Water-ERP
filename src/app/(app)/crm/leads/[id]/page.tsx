import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, CheckCircle2, Circle } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR, formatPhone } from "@/lib/format";
import { ACTIVITY_KINDS, CUSTOMER_TYPES, LEAD_SOURCES, LEAD_STATUS, OPP_STAGE, VISIT_OUTCOMES, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { LeadFields, type LeadValues } from "../../lead-fields";
import { completeActivity, convertLead, logActivity, saveOpportunity, updateLead } from "../../actions";

export const metadata: Metadata = { title: "Lead" };

type D = {
  lead: LeadValues & { id: string; name: string; lead_no: string; status: string; source: string; owner: string | null; campaign: string | null; territory: string | null;
    customer_id: string | null; customer_name: string | null; converted_at: string | null; created_at: string };
  activities: { id: string; kind: string; subject: string; notes: string | null; due_on: string | null; done_at: string | null; outcome: string | null; owner: string | null; created_at: string }[];
  opportunities: { id: string; opp_no: string; title: string; stage: string; monthly_value: number; probability: number; expected_close: string | null; lost_reason: string | null; notes: string | null }[];
  visits: { checkin_at: string; outcome: string | null; notes: string | null; rep: string }[];
};

const lbl = (list: readonly (readonly [string, string])[], k: string | null | undefined) => (k ? (Object.fromEntries(list) as Record<string, string>)[k] ?? k : "—");

function OppFields({ o }: { o?: D["opportunities"][number] }) {
  return (
    <>
      <Field label="What" htmlFor={`op-t-${o?.id ?? "n"}`} required><Input id={`op-t-${o?.id ?? "n"}`} name="title" required defaultValue={o?.title} placeholder="e.g. Office supply — 3 floors, 6 dispensers" /></Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Stage" htmlFor={`op-s-${o?.id ?? "n"}`}><Select id={`op-s-${o?.id ?? "n"}`} name="stage" defaultValue={o?.stage ?? "prospecting"}>
          {Object.entries(OPP_STAGE).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}</Select></Field>
        <Field label="Worth a month (Rs.)" htmlFor={`op-v-${o?.id ?? "n"}`}><Input id={`op-v-${o?.id ?? "n"}`} name="monthly_value" type="number" min={0} step="100" defaultValue={o?.monthly_value ?? ""} /></Field>
        <Field label="Chance of winning (%)" htmlFor={`op-p-${o?.id ?? "n"}`} hint="Blank = usual for the stage"><Input id={`op-p-${o?.id ?? "n"}`} name="probability" type="number" min={0} max={100} defaultValue={o?.probability ?? ""} /></Field>
        <Field label="Expected by" htmlFor={`op-e-${o?.id ?? "n"}`}><Input id={`op-e-${o?.id ?? "n"}`} name="expected_close" type="date" defaultValue={o?.expected_close ?? ""} /></Field>
      </div>
      <Field label="If lost — why" htmlFor={`op-l-${o?.id ?? "n"}`}><Input id={`op-l-${o?.id ?? "n"}`} name="lost_reason" defaultValue={o?.lost_reason ?? ""} /></Field>
      <Field label="Notes" htmlFor={`op-n-${o?.id ?? "n"}`}><Textarea id={`op-n-${o?.id ?? "n"}`} name="notes" defaultValue={o?.notes ?? ""} /></Field>
    </>
  );
}

export default async function LeadPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [{ data }, { data: staff }, { data: campaigns }, { data: territories }] = await Promise.all([
    supabase.rpc("lead_details", { p_id: id }), supabase.rpc("staff_directory"),
    supabase.from("campaigns").select("id, name").order("start_date", { ascending: false }),
    supabase.from("territories").select("id, name").eq("is_active", true).order("name"),
  ]);
  if (!data) notFound();
  const d = data as D;
  const l = d.lead;
  const manage = can(access, "crm.manage");
  const open = !["won", "lost"].includes(l.status);
  const st = statusBadge(LEAD_STATUS, l.status);
  const staffOpts = ((staff ?? []) as { id: string; full_name: string }[]).map((s) => ({ id: s.id, name: s.full_name }));
  const hidden = { lead_id: l.id };
  const pending = d.activities.filter((a) => !a.done_at);

  return (
    <>
      <Link href="/crm" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Leads</Link>
      <PageHeader title={l.name} description={[l.lead_no, l.company_name, l.city, l.phone && formatPhone(l.phone), lbl(LEAD_SOURCES, l.source), l.campaign && `Campaign: ${l.campaign}`].filter(Boolean).join(" · ")}
        actions={<div className="flex flex-wrap items-center gap-2">
          <Badge tone={st.tone} className="text-sm">{st.label}</Badge>
          {manage && open && <>
            <FormDialog trigger="Log a call / visit" triggerVariant="primary" triggerSize="md" title="What happened" submitLabel="Save" action={logActivity} hidden={{ ...hidden, mode: "done" }}>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Type" htmlFor="la-k"><Select id="la-k" name="kind" defaultValue="call">{ACTIVITY_KINDS.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
                <Field label="Result" htmlFor="la-o"><Input id="la-o" name="outcome" placeholder="e.g. Interested, call back Monday" /></Field>
              </div>
              <Field label="About" htmlFor="la-s" required><Input id="la-s" name="subject" required /></Field>
              <Field label="Notes" htmlFor="la-n"><Textarea id="la-n" name="notes" /></Field>
            </FormDialog>
            <FormDialog trigger="Plan a follow-up" triggerSize="md" title="Plan a follow-up" submitLabel="Plan" action={logActivity} hidden={{ ...hidden, mode: "plan" }}>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Type" htmlFor="lp-k"><Select id="lp-k" name="kind" defaultValue="visit">{ACTIVITY_KINDS.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
                <Field label="On" htmlFor="lp-d" required><Input id="lp-d" name="due_on" type="date" required /></Field>
              </div>
              <Field label="What to do" htmlFor="lp-s" required><Input id="lp-s" name="subject" required placeholder="e.g. Bring samples and price list" /></Field>
            </FormDialog>
            <FormDialog trigger="Edit" triggerSize="md" title={`Edit ${l.name}`} submitLabel="Save" action={updateLead} hidden={{ id: l.id }} wide>
              <LeadFields v={l} staff={staffOpts} campaigns={campaigns ?? []} territories={territories ?? []} withStatus />
            </FormDialog>
            {can(access, "customers.manage") && (
              <FormDialog trigger="Make customer" triggerVariant="primary" triggerSize="md" title="Make this lead a customer"
                description="Creates the customer with the lead's details. A credit limit goes to Finance for approval." submitLabel="Create customer" action={convertLead} hidden={hidden}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field label="Name" htmlFor="cv-n"><Input id="cv-n" name="name" defaultValue={l.name} /></Field>
                  <Field label="Phone" htmlFor="cv-p" required><Input id="cv-p" name="phone" required defaultValue={l.phone ?? ""} /></Field>
                  <Field label="Customer type" htmlFor="cv-t" required><Select id="cv-t" name="customer_type" required defaultValue={l.customer_type ?? ""}>
                    <option value="" disabled>Choose…</option>{CUSTOMER_TYPES.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
                  <Field label="Credit limit (Rs.)" htmlFor="cv-c" hint="0 = pays on delivery"><Input id="cv-c" name="credit_limit" type="number" min={0} step="1000" defaultValue={0} /></Field>
                  <Field label="Payment terms (days)" htmlFor="cv-d" hint="Blank = usual for the type"><Input id="cv-d" name="payment_terms_days" type="number" min={0} /></Field>
                </div>
              </FormDialog>)}
          </>}
        </div>} />

      {l.status === "won" && l.customer_id && <Alert tone="success" className="mb-4">Became a customer {l.converted_at ? formatDate(l.converted_at) : ""}: <Link href={`/customers/${l.customer_id}`} className="font-semibold underline">{l.customer_name}</Link>.</Alert>}
      {l.status === "lost" && <Alert tone="info" className="mb-4">Lost — {l.lost_reason}</Alert>}

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          {pending.length > 0 && (
            <Card>
              <CardHeader title="Planned follow-ups" />
              <CardBody className="space-y-2">{pending.map((a) => (
                <div key={a.id} className="flex items-center justify-between gap-2 text-sm">
                  <span><Circle className="mr-1 inline h-3.5 w-3.5 text-amber-600" /><span className="font-medium">{formatDate(a.due_on)}</span> · {lbl(ACTIVITY_KINDS, a.kind)} · {a.subject}{a.owner ? ` (${a.owner})` : ""}</span>
                  {manage && <ReasonDialog trigger="Done" triggerVariant="ghost" title="Follow-up done" reasonRequired={false} confirmLabel="Mark done"
                    action={completeActivity} hidden={{ activity_id: a.id, lead_id: l.id }} />}
                </div>))}</CardBody>
            </Card>)}
          <Card>
            <CardHeader title="History" />
            <CardBody>
              <ol className="space-y-3 text-sm">
                {d.activities.filter((a) => a.done_at).map((a) => (
                  <li key={a.id} className="flex gap-2"><CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-600" />
                    <div><p><span className="font-medium">{lbl(ACTIVITY_KINDS, a.kind)}: {a.subject}</span> <span className="text-xs text-muted">{a.owner} · {formatDateTime(a.done_at)}</span></p>
                      {a.outcome && <p className="text-navy-800">{a.outcome}</p>}{a.notes && <p className="text-muted">{a.notes}</p>}</div></li>))}
                {d.visits.map((v, i) => (
                  <li key={`v${i}`} className="flex gap-2"><CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-ola-600" />
                    <div><p><span className="font-medium">Visit by {v.rep}</span> <span className="text-xs text-muted">{formatDateTime(v.checkin_at)}</span></p>
                      <p className="text-muted">{lbl(VISIT_OUTCOMES, v.outcome)}{v.notes ? ` — ${v.notes}` : ""}</p></div></li>))}
                <li className="text-xs text-muted">Lead added {formatDateTime(l.created_at)}</li>
              </ol>
            </CardBody>
          </Card>
        </div>
        <div className="space-y-6">
          <Card>
            <CardHeader title="Details" />
            <CardBody className="space-y-1.5 text-sm">
              <p><span className="text-muted">Owner:</span> {l.owner ?? "—"}</p>
              <p><span className="text-muted">Would be:</span> {lbl(CUSTOMER_TYPES, l.customer_type)}</p>
              <p><span className="text-muted">Estimate:</span> {l.est_monthly_bottles ? `${l.est_monthly_bottles} bottles · ` : ""}{l.est_monthly_value ? `${formatLKR(l.est_monthly_value)} a month` : "—"}</p>
              <p><span className="text-muted">Territory:</span> {l.territory ?? "—"}</p>
              <p><span className="text-muted">Contact:</span> {[l.contact_person, l.email].filter(Boolean).join(" · ") || "—"}</p>
              <p><span className="text-muted">Address:</span> {[l.address_line, l.city].filter(Boolean).join(", ") || "—"}</p>
              {l.next_follow_up && <p><span className="text-muted">Next follow-up:</span> {formatDate(l.next_follow_up)}</p>}
              {l.notes && <p className="whitespace-pre-line pt-2">{l.notes}</p>}
            </CardBody>
          </Card>
          <Card>
            <CardHeader title="Opportunities" actions={manage && (
              <FormDialog trigger="Add" triggerSize="sm" title="New opportunity" submitLabel="Save" action={saveOpportunity} hidden={hidden}><OppFields /></FormDialog>)} />
            <CardBody className="space-y-3 text-sm">
              {d.opportunities.length === 0 && <p className="text-muted">None.</p>}
              {d.opportunities.map((o) => { const os = statusBadge(OPP_STAGE, o.stage); return (
                <div key={o.id} className="flex items-start justify-between gap-2">
                  <div><p className="font-medium">{o.title}</p><p className="text-xs text-muted">{o.opp_no} · {formatLKR(o.monthly_value)} a month · {o.probability}%{o.expected_close ? ` · by ${formatDate(o.expected_close)}` : ""}</p></div>
                  <div className="flex items-center gap-1"><Badge tone={os.tone}>{os.label}</Badge>
                    {manage && <FormDialog trigger="Edit" triggerVariant="ghost" title={o.title} submitLabel="Save" action={saveOpportunity} hidden={{ ...hidden, id: o.id }}><OppFields o={o} /></FormDialog>}</div>
                </div>); })}
            </CardBody>
          </Card>
        </div>
      </div>
    </>
  );
}
