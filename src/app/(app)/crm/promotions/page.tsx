import type { Metadata } from "next";
import { Percent, Plus } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { CUSTOMER_TYPES, PROMO_KINDS, PROMO_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { CrmTabs } from "../crm-tabs";
import { activatePromotion, endPromotion, savePromotion } from "../actions";

export const metadata: Metadata = { title: "Promotions" };

type Perf = { id: string; code: string; name: string; kind: string; value: number; status: string; start_date: string; end_date: string; product: string | null;
  orders: number; qty: number; discount_given: number; sales_net: number };
type Promo = { id: string; code: string; name: string; kind: string; value: number; buy_qty: number | null; product_id: string | null; customer_types: string[] | null;
  segment_id: string | null; price_list_id: string | null; min_qty: number; start_date: string; end_date: string; status: string; notes: string | null };
type Opt = { id: string; name: string };

function PromoFields({ p, products, segments, lists, today }: { p?: Promo; products: Opt[]; segments: Opt[]; lists: Opt[]; today: string }) {
  const k = p?.id ?? "new";
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Code" htmlFor={`pr-c-${k}`} required><Input id={`pr-c-${k}`} name="code" required defaultValue={p?.code} placeholder="NEWYEAR10" /></Field>
        <Field label="Name" htmlFor={`pr-n-${k}`} required className="sm:col-span-2"><Input id={`pr-n-${k}`} name="name" required defaultValue={p?.name} /></Field>
        <Field label="Kind" htmlFor={`pr-k-${k}`}><Select id={`pr-k-${k}`} name="kind" defaultValue={p?.kind ?? "percent"}>{PROMO_KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
        <Field label="Value" htmlFor={`pr-v-${k}`} required hint="% · Rs. off · special price · free units"><Input id={`pr-v-${k}`} name="value" type="number" min={0.01} step="0.01" required defaultValue={p?.value ?? ""} /></Field>
        <Field label="Buy (for Buy X get Y)" htmlFor={`pr-b-${k}`}><Input id={`pr-b-${k}`} name="buy_qty" type="number" min={1} defaultValue={p?.buy_qty ?? ""} /></Field>
        <Field label="Product" htmlFor={`pr-p-${k}`}><Select id={`pr-p-${k}`} name="product_id" defaultValue={p?.product_id ?? ""}><option value="">Every product</option>{products.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="Minimum quantity on the line" htmlFor={`pr-m-${k}`}><Input id={`pr-m-${k}`} name="min_qty" type="number" min={0} defaultValue={p?.min_qty ?? 0} /></Field>
        <Field label="Only this price list" htmlFor={`pr-l-${k}`}><Select id={`pr-l-${k}`} name="price_list_id" defaultValue={p?.price_list_id ?? ""}><option value="">Any</option>{lists.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="Only this segment" htmlFor={`pr-s-${k}`}><Select id={`pr-s-${k}`} name="segment_id" defaultValue={p?.segment_id ?? ""}><option value="">Any customer</option>{segments.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="From" htmlFor={`pr-f-${k}`} required><Input id={`pr-f-${k}`} name="start_date" type="date" required defaultValue={p?.start_date ?? today} /></Field>
        <Field label="Until" htmlFor={`pr-u-${k}`} required><Input id={`pr-u-${k}`} name="end_date" type="date" required defaultValue={p?.end_date ?? ""} /></Field>
      </div>
      <div><p className="mb-1 text-sm font-medium">Only these customer types (none ticked = all)</p>
        <div className="flex flex-wrap gap-x-4 gap-y-1 text-sm">{CUSTOMER_TYPES.map(([v, l]) => <label key={v} className="flex items-center gap-1.5">
          <input type="checkbox" name="customer_types" value={v} defaultChecked={p?.customer_types?.includes(v)} /> {l}</label>)}</div></div>
      <Field label="Notes" htmlFor={`pr-no-${k}`}><Textarea id={`pr-no-${k}`} name="notes" defaultValue={p?.notes ?? ""} /></Field>
    </>
  );
}

const describe = (p: { kind: string; value: number; buy_qty?: number | null }) =>
  p.kind === "percent" ? `${Number(p.value)}% off` : p.kind === "amount_per_unit" ? `${formatLKR(p.value)} off each` : p.kind === "fixed_price" ? `${formatLKR(p.value)} each` : `buy ${p.buy_qty} get ${Number(p.value)} free`;

export default async function PromotionsPage() {
  await requirePermission(["crm.manage", "prices.approve"]);
  const supabase = await createClient();
  const today = todayISO();
  const [{ data: perf }, { data: promos }, { data: products }, { data: segments }, { data: lists }] = await Promise.all([
    supabase.rpc("promotion_performance"), supabase.from("promotions").select("*"),
    supabase.from("products").select("id, name").eq("is_active", true).eq("item_type", "finished_good").order("sort_order"),
    supabase.from("customer_segments").select("id, name").eq("is_active", true).order("name"),
    supabase.from("price_lists").select("id, name").eq("is_active", true).order("name"),
  ]);
  const byId = Object.fromEntries(((promos ?? []) as Promo[]).map((p) => [p.id, p]));
  const rows = (perf ?? []) as Perf[];

  return (
    <>
      <PageHeader title="Leads & CRM" description="Promotions — price offers applied automatically to orders (including recurring orders) while they are on. Switching one on needs the price approver."
        actions={<FormDialog trigger={<><Plus className="h-4 w-4" /> New promotion</>} triggerVariant="primary" triggerSize="md" title="New promotion" submitLabel="Save draft" action={savePromotion} wide>
          <PromoFields products={products ?? []} segments={segments ?? []} lists={lists ?? []} today={today} /></FormDialog>} />
      <CrmTabs active="/crm/promotions" />
      <Card>
        <CardHeader title="Promotions" description="When several apply to a line, the customer gets the biggest one. Till sales at shops are not included." />
        {rows.length === 0 ? <EmptyState icon={Percent} title="No promotions yet" /> : (
          <Table>
            <thead><tr><Th>Promotion</Th><Th>Offer</Th><Th>Dates</Th><Th className="text-right">Used on</Th><Th className="text-right">Discount given</Th><Th>Status</Th><Th /></tr></thead>
            <tbody>{rows.map((r) => { const st = statusBadge(PROMO_STATUS, r.status); const p = byId[r.id]; return (
              <tr key={r.id}>
                <Td><span className="font-medium">{r.name}</span><span className="block font-mono text-xs text-muted">{r.code}</span></Td>
                <Td className="text-sm">{describe(p ?? r)} · {r.product ?? "every product"}{p && Number(p.min_qty) > 0 ? ` · min ${Number(p.min_qty)}` : ""}
                  {p?.customer_types?.length ? <span className="block text-xs text-muted">{p.customer_types.join(", ")}</span> : null}</Td>
                <Td className="whitespace-nowrap text-sm">{formatDate(r.start_date)} – {formatDate(r.end_date)}</Td>
                <Td className="num text-right">{r.orders} orders<span className="block text-xs text-muted">{Number(r.qty)} units</span></Td>
                <Td className="num text-right">{formatLKR(r.discount_given)}<span className="block text-xs text-muted">sales {formatLKR(r.sales_net)}</span></Td>
                <Td><Badge tone={st.tone}>{st.label}</Badge></Td>
                <Td className="space-x-1 whitespace-nowrap text-right">
                  {r.status === "draft" && p && <>
                    <FormDialog trigger="Edit" triggerVariant="ghost" title={r.name} submitLabel="Save" action={savePromotion} hidden={{ id: r.id }} wide>
                      <PromoFields p={p} products={products ?? []} segments={segments ?? []} lists={lists ?? []} today={today} /></FormDialog>
                    <ReasonDialog trigger="Switch on" triggerVariant="primary" title={`Switch on ${r.name}`} description="If you are not the price approver it is sent for approval."
                      reasonRequired={false} confirmLabel="Switch on" action={activatePromotion} hidden={{ promotion_id: r.id }} /></>}
                  {r.status !== "ended" && <ReasonDialog trigger="End" triggerVariant="dangerOutline" title={`End ${r.name}`} confirmLabel="End now" confirmVariant="danger"
                    reasonRequired={false} action={endPromotion} hidden={{ promotion_id: r.id }} />}
                </Td>
              </tr>); })}</tbody>
          </Table>)}
      </Card>
    </>
  );
}
