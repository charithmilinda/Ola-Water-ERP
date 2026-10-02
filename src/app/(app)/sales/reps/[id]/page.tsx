import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR } from "@/lib/format";
import { COMMISSION_STATUS, LEAD_STATUS, MONTHS, VISIT_OUTCOMES, VISIT_PURPOSES, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { DocumentsCard } from "@/components/documents/documents-card";
import { Progress } from "../../progress";
import { assignCustomers, cashHandover, saveRep } from "../../actions";

export const metadata: Metadata = { title: "Sales rep" };

type H = { year: number; month: number; sales_net: number; collections: number; new_customers: number; visits: number; sales_target: number;
  collection_target: number; new_customers_target: number; visits_target: number };
type D = {
  rep: { id: string; code: string; full_name: string; email: string | null; phone: string | null; territory: string | null; territory_id: string | null;
    plan_name: string | null; commission_plan_id: string | null; employee_id: string | null; employee_name: string | null; emp_no: string | null; is_active: boolean };
  history: H[]; cash_with_rep: number;
  customers: { id: string; name: string; customer_no: string; customer_type: string; outstanding: number; sales_90d: number | null; last_visit: string | null }[];
  visits: { id: string; checkin_at: string; checkout_at: string | null; purpose: string; outcome: string | null; notes: string | null; distance_m: number | null;
    who: string; customer_id: string | null; lead_id: string | null; order_no: string | null; payment_no: string | null; payment_amount: number | null }[];
  collections: { id: string; payment_no: string; received_at: string; method: string; amount: number; customer: string }[];
  handovers: { handover_no: string; created_at: string; amount: number; account: string; reference: string | null }[];
  commissions: { id: string; statement_no: string; period_year: number; period_month: number; total: number; status: string; paid_via: string | null }[];
  leads: { id: string; lead_no: string; name: string; status: string; next_follow_up: string | null }[];
};

const label = (list: readonly (readonly [string, string])[], k: string | null) => (k ? (Object.fromEntries(list) as Record<string, string>)[k] ?? k : "—");

export default async function RepPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["sales_reps.manage", "payments.manage"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [{ data }, { data: territories }, { data: plans }, { data: employees }, { data: money }] = await Promise.all([
    supabase.rpc("rep_details", { p_rep: id }),
    supabase.from("territories").select("id, name").eq("is_active", true).order("name"),
    supabase.from("commission_plans").select("id, name").eq("is_active", true).order("name"),
    supabase.rpc("employee_directory"),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).in("kind", ["cash", "bank"]).order("kind"),
  ]);
  if (!data) notFound();
  const d = data as D;
  const r = d.rep;
  const manage = can(access, "sales_reps.manage");
  const mine = new Set(d.customers.map((c) => c.id));
  const { data: others } = manage ? await supabase.from("customers").select("id, name, customer_no, sales_rep_id").eq("status", "active").eq("is_walk_in", false)
    .order("name").limit(400) : { data: [] };
  const assignable = (others ?? []).filter((c) => !mine.has(c.id));
  const now = d.history[0];
  const emps = ((employees ?? []) as { id: string; full_name: string; emp_no: string; status: string }[]).filter((e) => e.status === "active");

  return (
    <>
      <Link href="/sales" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Sales Team</Link>
      <PageHeader title={r.full_name} description={[r.code, r.territory, r.plan_name && `Plan: ${r.plan_name}`, r.employee_name && `Payroll: ${r.emp_no}`, r.phone].filter(Boolean).join(" · ")}
        actions={<div className="flex flex-wrap gap-2">
          {!r.is_active && <Badge tone="neutral">Inactive</Badge>}
          {can(access, "payments.manage") && Number(d.cash_with_rep) > 0 && (
            <FormDialog trigger="Cash handed in" triggerVariant="primary" triggerSize="md" title={`Cash from ${r.full_name}`}
              description={`The rep holds ${formatLKR(d.cash_with_rep)} collected from customers.`} submitLabel="Record" action={cashHandover} hidden={{ rep_id: r.id }}>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Amount (Rs.)" htmlFor="ch-a" required><Input id="ch-a" name="amount" type="number" min={0.01} step="0.01" max={Number(d.cash_with_rep)} defaultValue={Number(d.cash_with_rep)} required /></Field>
                <Field label="Into" htmlFor="ch-m"><Select id="ch-m" name="money_account_id">{money?.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
              </div>
              <Field label="Bank deposit reference" htmlFor="ch-r"><Input id="ch-r" name="reference" /></Field>
              <Field label="Notes" htmlFor="ch-n"><Input id="ch-n" name="notes" /></Field>
            </FormDialog>)}
          {manage && (
            <FormDialog trigger="Edit" triggerSize="md" title={`Edit ${r.full_name}`} submitLabel="Save" action={saveRep} hidden={{ id: r.id }}>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Rep code" htmlFor="re-c"><Input id="re-c" name="code" defaultValue={r.code} /></Field>
                <Field label="Mobile" htmlFor="re-p"><Input id="re-p" name="phone" defaultValue={r.phone ?? ""} /></Field>
                <Field label="Territory" htmlFor="re-t"><Select id="re-t" name="territory_id" defaultValue={r.territory_id ?? ""}><option value="">—</option>
                  {(territories ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</Select></Field>
                <Field label="Commission plan" htmlFor="re-cp"><Select id="re-cp" name="commission_plan_id" defaultValue={r.commission_plan_id ?? ""}><option value="">No commission</option>
                  {(plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</Select></Field>
              </div>
              <Field label="Employee record (for payroll)" htmlFor="re-e"><Select id="re-e" name="employee_id" defaultValue={r.employee_id ?? ""}><option value="">Not on our payroll</option>
                {emps.map((e) => <option key={e.id} value={e.id}>{e.full_name} ({e.emp_no})</option>)}</Select></Field>
              <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={r.is_active} /> Active</label>
            </FormDialog>)}
        </div>} />

      {now && (
        <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Card className="p-5"><p className="mb-2 text-sm font-medium text-muted">Sales this month</p><Progress actual={Number(now.sales_net)} target={Number(now.sales_target)} /></Card>
          <Card className="p-5"><p className="mb-2 text-sm font-medium text-muted">Collections</p><Progress actual={Number(now.collections)} target={Number(now.collection_target)} /></Card>
          <Card className="p-5"><p className="mb-2 text-sm font-medium text-muted">New customers · visits</p><Progress actual={now.new_customers} target={now.new_customers_target} money={false} />
            <div className="mt-2"><Progress actual={now.visits} target={now.visits_target} money={false} /></div></Card>
          <Stat label="Cash held" value={formatLKR(d.cash_with_rep)} hint="Collected, not yet handed in" />
        </div>)}

      <div className="grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader title="Last 6 months" />
          <Table>
            <thead><tr><Th>Month</Th><Th className="text-right">Sales</Th><Th className="text-right">Target</Th><Th className="text-right">Collections</Th><Th className="text-right">New</Th><Th className="text-right">Visits</Th></tr></thead>
            <tbody>{d.history.map((h) => (
              <tr key={`${h.year}-${h.month}`}><Td>{MONTHS[h.month - 1].slice(0, 3)} {h.year}</Td><Td className="num text-right">{formatLKR(h.sales_net)}</Td>
                <Td className="num text-right text-muted">{Number(h.sales_target) ? formatLKR(h.sales_target) : "—"}</Td><Td className="num text-right">{formatLKR(h.collections)}</Td>
                <Td className="num text-right">{h.new_customers}</Td><Td className="num text-right">{h.visits}</Td></tr>))}</tbody>
          </Table>
        </Card>

        <Card>
          <CardHeader title={`Customers (${d.customers.length})`} actions={manage && (
            <FormDialog trigger="Assign customers" triggerSize="sm" title={`Give customers to ${r.full_name}`} description="Ticked customers move to this rep." submitLabel="Assign"
              action={assignCustomers} hidden={{ rep_id: r.id }} wide>
              <div className="max-h-80 overflow-y-auto rounded-lg border border-line p-2 text-sm">
                {assignable.map((c) => <label key={c.id} className="flex items-center gap-2 py-0.5"><input type="checkbox" name="customer_ids" value={c.id} />
                  {c.name} <span className="text-xs text-muted">{c.customer_no}{c.sales_rep_id ? " · has another rep" : ""}</span></label>)}
              </div>
              <Field label="Reason" htmlFor="ac-r"><Input id="ac-r" name="reason" /></Field>
            </FormDialog>)} />
          <Table>
            <thead><tr><Th>Customer</Th><Th className="text-right">Sales 90 days</Th><Th className="text-right">Owes</Th><Th>Last visit</Th></tr></thead>
            <tbody>{d.customers.slice(0, 50).map((c) => (
              <tr key={c.id}><Td><Link href={`/customers/${c.id}`} className="text-ola-700 hover:underline">{c.name}</Link><span className="block text-xs text-muted">{c.customer_no}</span></Td>
                <Td className="num text-right">{formatLKR(c.sales_90d ?? 0)}</Td><Td className="num text-right">{formatLKR(c.outstanding)}</Td>
                <Td>{c.last_visit ? formatDate(c.last_visit) : <span className="text-muted">Never</span>}</Td></tr>))}</tbody>
          </Table>
        </Card>

        <Card className="xl:col-span-2">
          <CardHeader title="Visits" />
          {d.visits.length === 0 ? <CardBody><p className="text-sm text-muted">No visits recorded.</p></CardBody> : (
            <Table>
              <thead><tr><Th>When</Th><Th>Who</Th><Th>Why</Th><Th>Outcome</Th><Th>Location</Th></tr></thead>
              <tbody>{d.visits.map((v) => (
                <tr key={v.id}><Td className="whitespace-nowrap">{formatDateTime(v.checkin_at)}{v.checkout_at && <span className="block text-xs text-muted">
                  {Math.max(1, Math.round((new Date(v.checkout_at).getTime() - new Date(v.checkin_at).getTime()) / 60000))} min</span>}</Td>
                  <Td>{v.customer_id ? <Link href={`/customers/${v.customer_id}`} className="hover:underline">{v.who}</Link> : v.lead_id ? <Link href={`/crm/leads/${v.lead_id}`} className="hover:underline">{v.who} (lead)</Link> : v.who}</Td>
                  <Td>{label(VISIT_PURPOSES, v.purpose)}</Td>
                  <Td>{label(VISIT_OUTCOMES, v.outcome)}{v.order_no && <span className="block text-xs">Order {v.order_no}</span>}
                    {v.payment_no && <span className="block text-xs">{v.payment_no} {formatLKR(v.payment_amount)}</span>}{v.notes && <span className="block text-xs text-muted">{v.notes}</span>}</Td>
                  <Td>{v.distance_m === null ? <span className="text-muted">No GPS</span> : v.distance_m > 300 ? <Badge tone="amber">{v.distance_m} m away</Badge> : `${v.distance_m} m`}</Td></tr>))}</tbody>
            </Table>)}
        </Card>

        <Card>
          <CardHeader title="Collections & hand-ins" />
          <CardBody className="space-y-1 text-sm">
            {d.collections.slice(0, 15).map((c) => <p key={c.id} className="flex justify-between"><span>{formatDate(c.received_at)} · {c.customer} · {c.method.replace("_", " ")}</span><span className="num">{formatLKR(c.amount)}</span></p>)}
            {d.handovers.length > 0 && <p className="pt-2 font-medium">Handed in</p>}
            {d.handovers.map((h) => <p key={h.handover_no} className="flex justify-between text-muted"><span>{formatDate(h.created_at)} · {h.handover_no} → {h.account}</span><span className="num">{formatLKR(h.amount)}</span></p>)}
            {d.collections.length === 0 && <p className="text-muted">None yet.</p>}
          </CardBody>
        </Card>

        <Card>
          <CardHeader title="Commission & leads" actions={<Link href="/sales/commissions" className="text-sm text-ola-700 hover:underline">Commissions</Link>} />
          <CardBody className="space-y-1 text-sm">
            {d.commissions.map((c) => { const st = statusBadge(COMMISSION_STATUS, c.status); return (
              <p key={c.id} className="flex items-center justify-between"><span>{MONTHS[c.period_month - 1]} {c.period_year} · {c.statement_no}</span>
                <span className="flex items-center gap-2"><span className="num">{formatLKR(c.total)}</span><Badge tone={st.tone}>{st.label}</Badge></span></p>); })}
            {d.leads.length > 0 && <p className="pt-2 font-medium">Open leads</p>}
            {d.leads.map((l) => <p key={l.id} className="flex justify-between"><Link href={`/crm/leads/${l.id}`} className="text-ola-700 hover:underline">{l.name}</Link>
              <span className="text-muted">{statusBadge(LEAD_STATUS, l.status).label}{l.next_follow_up ? ` · follow up ${formatDate(l.next_follow_up)}` : ""}</span></p>)}
          </CardBody>
        </Card>
      </div>
      {r.employee_id && <div className="mt-6"><DocumentsCard access={access} entityType="employee" entityId={r.employee_id} categories={["employee"]} returnTo={`/sales/reps/${r.id}`} /></div>}
    </>
  );
}
