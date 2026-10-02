import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatLKR, formatPhone, todayISO } from "@/lib/format";
import { ORDER_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { DocumentsCard } from "@/components/documents/documents-card";
import { DistributorFields } from "../distributor-fields";
import { recordStock, updateDistributor } from "../actions";

export const metadata: Metadata = { title: "Distributor" };

type D = {
  distributor: { id: string; code: string; kind: string; territory_id: string | null; territory: string | null; manager_id: string | null; manager: string | null;
    agreement_start: string | null; agreement_end: string | null; monthly_target: number; min_stock_19l: number | null; exclusive: boolean; status: string; notes: string | null };
  customer: { id: string; name: string; customer_no: string; phone: string; credit_limit: number; payment_terms_days: number; price_list: string | null;
    outstanding: number; ola_bottles: number; overdue: number };
  history: { month: string; sales: number; qty_19l: number; collections: number }[];
  stock: { report_date: string; empty_bottles: number | null; lines: { product_id: string; product: string; reported: number; delivered_since: number }[] } | null;
  reports: { report_date: string; empty_bottles: number | null; notes: string | null; total: number | null }[];
  orders: { id: string; order_no: string; status: string; requested_date: string; total: number }[];
};

export default async function DistributorPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission("distributors.manage");
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [{ data }, { data: territories }, { data: staff }, { data: products }] = await Promise.all([
    supabase.rpc("distributor_details", { p_id: id }),
    supabase.from("territories").select("id, name").eq("is_active", true).order("name"),
    supabase.rpc("staff_directory"),
    supabase.from("products").select("id, name").eq("is_active", true).eq("item_type", "finished_good").order("sort_order"),
  ]);
  if (!data) notFound();
  const d = data as D;
  const x = d.distributor;
  const c = d.customer;
  const today = todayISO();
  const thisMonth = d.history[0];
  const est19 = d.stock?.lines.find((l) => l.product.includes("19"));
  const staffOpts = ((staff ?? []) as { id: string; full_name: string }[]).map((s) => ({ id: s.id, name: s.full_name }));

  return (
    <>
      <Link href="/distributors" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Distributors</Link>
      <PageHeader title={c.name} description={[x.code, x.kind, x.territory, x.exclusive && "exclusive", x.manager && `looked after by ${x.manager}`, formatPhone(c.phone)].filter(Boolean).join(" · ")}
        actions={<div className="flex flex-wrap gap-2">
          {x.status !== "active" && <Badge tone="neutral">{x.status}</Badge>}
          {can(access, "orders.manage") && <Link href={`/orders/new?customer=${c.id}`} className={buttonVariants({ size: "md" })}><Plus className="h-4 w-4" /> New order</Link>}
          <Link href={`/customers/${c.id}`} className={buttonVariants({ variant: "secondary", size: "md" })}>Account, invoices & payments</Link>
          <FormDialog trigger="Stock count" triggerSize="md" title="Stock they hold" description="What the distributor counted in their store." submitLabel="Save count" action={recordStock}
            hidden={{ distributor_id: x.id }}>
            <Field label="Counted on" htmlFor="sc-d"><Input id="sc-d" name="report_date" type="date" defaultValue={today} max={today} /></Field>
            <div className="grid gap-3 sm:grid-cols-2">{(products ?? []).map((p) => (
              <Field key={p.id} label={p.name} htmlFor={`sc-${p.id}`}><Input id={`sc-${p.id}`} name={`q:${p.id}`} type="number" min={0} step="1" /></Field>))}</div>
            <Field label="Empty bottles held" htmlFor="sc-e"><Input id="sc-e" name="empty_bottles" type="number" min={0} /></Field>
            <Field label="Notes" htmlFor="sc-n"><Input id="sc-n" name="notes" /></Field>
          </FormDialog>
          <FormDialog trigger="Edit" triggerSize="md" title={`Edit ${x.code}`} submitLabel="Save" action={updateDistributor} hidden={{ id: x.id }} wide>
            <DistributorFields v={x} territories={territories ?? []} staff={staffOpts} />
            <Field label="Reason for change" htmlFor="de-r"><Input id="de-r" name="reason" /></Field>
          </FormDialog>
        </div>} />

      {x.agreement_end && x.agreement_end < today && <Alert tone="error" className="mb-4">The agreement ended on {formatDate(x.agreement_end)}.</Alert>}
      {x.min_stock_19l && est19 && Number(est19.reported) + Number(est19.delivered_since) < x.min_stock_19l && (
        <Alert tone="warning" className="mb-4">Their 19L stock may be below the agreed minimum of {x.min_stock_19l} (last count plus deliveries since: {Number(est19.reported) + Number(est19.delivered_since)}).</Alert>)}

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Sales this month" value={formatLKR(thisMonth?.sales)} hint={Number(x.monthly_target) ? `Target ${formatLKR(x.monthly_target)} · ${Math.round(Number(thisMonth?.sales ?? 0) / Number(x.monthly_target) * 100)}%` : "No target"} />
        <Stat label="Owes" value={formatLKR(c.outstanding)} hint={`${formatLKR(c.overdue)} overdue · limit ${formatLKR(c.credit_limit)} · ${c.payment_terms_days} days`} />
        <Stat label="OLA bottles with them" value={c.ola_bottles} hint={c.price_list ? `Price list: ${c.price_list}` : undefined} />
        <Stat label="Agreement" value={x.agreement_end ? formatDate(x.agreement_end) : "—"} hint={x.agreement_start ? `Since ${formatDate(x.agreement_start)}` : undefined} />
      </div>

      <div className="grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader title="Last 12 months" />
          <Table>
            <thead><tr><Th>Month</Th><Th className="text-right">Sales</Th><Th className="text-right">vs target</Th><Th className="text-right">19L bottles</Th><Th className="text-right">Paid</Th></tr></thead>
            <tbody>{d.history.map((h) => (
              <tr key={h.month}><Td>{new Intl.DateTimeFormat("en-GB", { month: "short", year: "numeric" }).format(new Date(h.month))}</Td>
                <Td className="num text-right">{formatLKR(h.sales)}</Td>
                <Td className="num text-right">{Number(x.monthly_target) ? `${Math.round(Number(h.sales) / Number(x.monthly_target) * 100)}%` : "—"}</Td>
                <Td className="num text-right">{Number(h.qty_19l)}</Td><Td className="num text-right">{formatLKR(h.collections)}</Td></tr>))}</tbody>
          </Table>
        </Card>
        <div className="space-y-6">
          <Card>
            <CardHeader title="Stock they hold" description={d.stock ? `Last count ${formatDate(d.stock.report_date)} plus what we delivered since` : undefined} />
            {!d.stock ? <CardBody><p className="text-sm text-muted">No stock count recorded yet.</p></CardBody> : (
              <Table>
                <thead><tr><Th>Product</Th><Th className="text-right">Counted</Th><Th className="text-right">Delivered since</Th><Th className="text-right">Estimated now</Th></tr></thead>
                <tbody>{d.stock.lines.map((l) => (
                  <tr key={l.product_id}><Td>{l.product}</Td><Td className="num text-right">{Number(l.reported)}</Td><Td className="num text-right">{Number(l.delivered_since)}</Td>
                    <Td className="num text-right font-semibold">{Number(l.reported) + Number(l.delivered_since)}</Td></tr>))}
                  {d.stock.empty_bottles !== null && <tr><Td>Empty bottles</Td><Td className="num text-right">{d.stock.empty_bottles}</Td><Td /><Td /></tr>}</tbody>
              </Table>)}
            <CardBody className="text-xs text-muted">The estimate does not know what they sold since the count — ask for a count regularly.</CardBody>
          </Card>
          <Card>
            <CardHeader title="Recent orders" />
            <Table><tbody>{d.orders.map((o) => { const st = statusBadge(ORDER_STATUS, o.status); return (
              <tr key={o.id}><Td><Link href={`/orders/${o.id}`} className="font-mono text-sm text-ola-700 hover:underline">{o.order_no}</Link></Td><Td>{formatDate(o.requested_date)}</Td>
                <Td className="num text-right">{formatLKR(o.total)}</Td><Td><Badge tone={st.tone}>{st.label}</Badge></Td></tr>); })}
              {d.orders.length === 0 && <tr><Td className="text-muted">No orders yet.</Td></tr>}</tbody></Table>
          </Card>
        </div>
      </div>
      {x.notes && <p className="mt-4 whitespace-pre-line text-sm text-muted">{x.notes}</p>}
      <div className="mt-6"><DocumentsCard access={access} entityType="customer" entityId={c.id} categories={["contract", "finance", "other"]} returnTo={`/distributors/${x.id}`} /></div>
    </>
  );
}
