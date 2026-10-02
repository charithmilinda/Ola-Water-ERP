import type { Metadata } from "next";
import Link from "next/link";
import { MapPinned, Plus } from "lucide-react";
import { getAccess } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatPhone } from "@/lib/format";
import { PAYMENT_METHODS, VISIT_OUTCOMES, VISIT_PURPOSES } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { Progress } from "../progress";
import { GpsFields } from "./gps-fields";
import { checkIn, checkOut, collectPayment } from "../actions";

export const metadata: Metadata = { title: "My Day" };

type Day = {
  rep: { id: string; code: string; territory: string | null };
  month: { sales_net: number; collections: number; new_customers: number; visits: number; sales_target: number; collection_target: number;
    new_customers_target: number; visits_target: number };
  open_visit: { id: string; checkin_at: string; purpose: string; distance_m: number | null; customer_id: string | null; lead_id: string | null; who: string } | null;
  today: { id: string; checkin_at: string; checkout_at: string | null; purpose: string; outcome: string | null; who: string; order_no: string | null; payment: number | null }[];
  customers: { id: string; name: string; customer_no: string; phone: string; outstanding: number; address: string | null }[];
  leads: { id: string; name: string; lead_no: string; status: string; phone: string | null; city: string | null; next_follow_up: string | null }[];
  follow_ups: { id: string; subject: string; kind: string; due_on: string; who: string; lead_id: string | null; customer_id: string | null }[];
  cash_with_me: number; can_collect: boolean;
};

const time = (iso: string) => new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Colombo", hour: "numeric", minute: "2-digit", hour12: true }).format(new Date(iso));
const label = (list: readonly (readonly [string, string])[], k: string | null) => (k ? (Object.fromEntries(list) as Record<string, string>)[k] ?? k : "");

function CollectFields({ customers, customerId }: { customers?: Day["customers"]; customerId?: string }) {
  return (
    <>
      {customerId ? <input type="hidden" name="customer_id" value={customerId} /> : (
        <Field label="Customer" htmlFor="cl-c"><Select id="cl-c" name="customer_id">{customers?.map((c) => <option key={c.id} value={c.id}>{c.name} — owes {formatLKR(c.outstanding)}</option>)}</Select></Field>)}
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Amount (Rs.)" htmlFor="cl-a" required><Input id="cl-a" name="amount" type="number" inputMode="decimal" min={0.01} step="0.01" required /></Field>
        <Field label="How" htmlFor="cl-m"><Select id="cl-m" name="method" defaultValue="cash">
          {PAYMENT_METHODS.filter(([k]) => ["cash", "cheque", "bank_transfer"].includes(k)).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
      </div>
      <Field label="Cheque / transfer number" htmlFor="cl-r"><Input id="cl-r" name="reference" /></Field>
      <Field label="Note" htmlFor="cl-n"><Input id="cl-n" name="notes" /></Field>
    </>
  );
}

export default async function MyDayPage() {
  await getAccess();
  const supabase = await createClient();
  const { data } = await supabase.rpc("my_sales_day");
  if (!data) {
    return (<><PageHeader title="My Day" /><Card><EmptyState icon={MapPinned} title="You are not set up as a sales rep" description="Ask your sales manager to add you under Sales Team." /></Card></>);
  }
  const d = data as Day;
  const ov = d.open_visit;

  return (
    <>
      <PageHeader title="My Day" description={`${d.rep.code}${d.rep.territory ? ` · ${d.rep.territory}` : ""} · cash with you ${formatLKR(d.cash_with_me)}`}
        actions={<div className="flex flex-wrap gap-2">
          <Link href="/crm" className={buttonVariants({ variant: "secondary", size: "md" })}><Plus className="h-4 w-4" /> New lead</Link>
          <Link href="/customers/new" className={buttonVariants({ variant: "secondary", size: "md" })}><Plus className="h-4 w-4" /> New customer</Link>
        </div>} />

      <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Card className="p-4"><p className="mb-2 text-xs font-medium text-muted">Sales this month</p><Progress actual={Number(d.month.sales_net)} target={Number(d.month.sales_target)} /></Card>
        <Card className="p-4"><p className="mb-2 text-xs font-medium text-muted">Collections</p><Progress actual={Number(d.month.collections)} target={Number(d.month.collection_target)} /></Card>
        <Card className="p-4"><p className="mb-2 text-xs font-medium text-muted">New customers</p><Progress actual={d.month.new_customers} target={d.month.new_customers_target} money={false} /></Card>
        <Card className="p-4"><p className="mb-2 text-xs font-medium text-muted">Visits</p><Progress actual={d.month.visits} target={d.month.visits_target} money={false} /></Card>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        {ov ? (
          <Card className="border-ola-300">
            <CardHeader title={`At ${ov.who}`} description={`Since ${time(ov.checkin_at)} · ${label(VISIT_PURPOSES, ov.purpose)}${ov.distance_m !== null ? ` · ${ov.distance_m} m from saved location` : ""}`} />
            <CardBody className="space-y-4">
              {ov.customer_id && <div className="flex flex-wrap gap-2">
                <Link href={`/orders/new?customer=${ov.customer_id}`} className={buttonVariants({ size: "md" })}>Take an order</Link>
                {d.can_collect && <FormDialog trigger="Collect payment" triggerSize="md" title={`Payment from ${ov.who}`} submitLabel="Save payment" action={collectPayment}
                  hidden={{ visit_id: ov.id }}><CollectFields customerId={ov.customer_id} /></FormDialog>}
                <Link href={`/customers/${ov.customer_id}`} className={buttonVariants({ variant: "ghost", size: "md" })}>Customer details</Link>
              </div>}
              {ov.lead_id && <Link href={`/crm/leads/${ov.lead_id}`} className={buttonVariants({ variant: "secondary", size: "md" })}>Open the lead</Link>}
              <ActionForm action={checkOut}>
                <input type="hidden" name="visit_id" value={ov.id} />
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field label="How did it go" htmlFor="co-o" required><Select id="co-o" name="outcome" required defaultValue="">
                    <option value="" disabled>Choose…</option>{VISIT_OUTCOMES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
                  <Field label="Next visit / call on" htmlFor="co-n"><Input id="co-n" name="next_action_on" type="date" /></Field>
                </div>
                <Field label="Notes" htmlFor="co-no"><Input id="co-no" name="notes" /></Field>
                <SubmitButton>Check out</SubmitButton>
              </ActionForm>
            </CardBody>
          </Card>
        ) : (
          <Card>
            <CardHeader title="Check in at a customer" description="Your location is recorded with the visit." />
            <CardBody>
              <ActionForm action={checkIn}>
                <Field label="Who" htmlFor="ci-w" required><Select id="ci-w" name="who" required defaultValue="">
                  <option value="" disabled>Choose…</option>
                  <optgroup label="My customers">{d.customers.map((c) => <option key={c.id} value={`c:${c.id}`}>{c.name}</option>)}</optgroup>
                  {d.leads.length > 0 && <optgroup label="My leads">{d.leads.map((l) => <option key={l.id} value={`l:${l.id}`}>{l.name} (lead)</option>)}</optgroup>}
                </Select></Field>
                <Field label="Why" htmlFor="ci-p"><Select id="ci-p" name="purpose" defaultValue="sales_call">{VISIT_PURPOSES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
                <GpsFields />
                <SubmitButton>Check in</SubmitButton>
              </ActionForm>
            </CardBody>
          </Card>
        )}

        <Card>
          <CardHeader title="Today" />
          <CardBody className="space-y-2 text-sm">
            {d.today.length === 0 && <p className="text-muted">No visits yet today.</p>}
            {d.today.map((v) => <p key={v.id} className="flex justify-between gap-2"><span><span className="font-medium">{time(v.checkin_at)}</span> {v.who}
              <span className="text-muted"> · {label(VISIT_OUTCOMES, v.outcome) || "in progress"}{v.order_no ? ` · ${v.order_no}` : ""}</span></span>
              {v.payment && <span className="num">{formatLKR(v.payment)}</span>}</p>)}
            {d.follow_ups.length > 0 && <p className="pt-3 font-medium">Follow-ups due</p>}
            {d.follow_ups.map((f) => <p key={f.id}><Link href={f.lead_id ? `/crm/leads/${f.lead_id}` : `/customers/${f.customer_id}`} className="text-ola-700 hover:underline">{f.who}</Link>
              <span className="text-muted"> · {f.subject} · {formatDate(f.due_on)}</span></p>)}
            {d.leads.filter((l) => l.next_follow_up && l.next_follow_up <= new Date().toISOString().slice(0, 10)).map((l) => (
              <p key={l.id}><Link href={`/crm/leads/${l.id}`} className="text-ola-700 hover:underline">{l.name}</Link><span className="text-muted"> · lead follow-up {formatDate(l.next_follow_up)}</span></p>))}
          </CardBody>
        </Card>

        <Card className="lg:col-span-2">
          <CardHeader title={`My customers (${d.customers.length})`} actions={d.can_collect && d.customers.length > 0 && (
            <FormDialog trigger="Collect payment" triggerSize="sm" title="Collect a payment" submitLabel="Save payment" action={collectPayment}>
              <CollectFields customers={d.customers} /></FormDialog>)} />
          {d.customers.length === 0 ? <CardBody><p className="text-sm text-muted">No customers are assigned to you yet.</p></CardBody> : (
            <Table><tbody>{d.customers.map((c) => (
              <tr key={c.id}><Td><Link href={`/customers/${c.id}`} className="font-medium text-ola-700 hover:underline">{c.name}</Link>
                <span className="block text-xs text-muted">{c.customer_no} · {formatPhone(c.phone)}{c.address ? ` · ${c.address}` : ""}</span></Td>
                <Td className={`num text-right ${Number(c.outstanding) > 0 ? "font-semibold" : "text-muted"}`}>{formatLKR(c.outstanding)}</Td>
                <Td className="text-right"><Link href={`/orders/new?customer=${c.id}`} className="text-sm text-ola-700 hover:underline">Order</Link></Td></tr>))}</tbody></Table>)}
        </Card>
      </div>
    </>
  );
}
