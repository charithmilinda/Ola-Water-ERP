import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Calculator, FileText, PackagePlus } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR, formatPhone, humanize, todayISO } from "@/lib/format";
import { PAYMENT_METHODS, SEVERITY, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge, type BadgeTone } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { Button, buttonVariants } from "@/components/ui/button";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { ShopFields, type ShopRow } from "../shop-fields";
import { createRequest, receiveRequest, settleShop, updateShop, withdrawRequest } from "../actions";

export const metadata: Metadata = { title: "Water shop" };

const REQ: Record<string, { label: string; tone: BadgeTone }> = {
  submitted: { label: "Waiting for approval", tone: "amber" }, approved: { label: "Approved — being picked", tone: "blue" },
  dispatched: { label: "On the way", tone: "blue" }, received: { label: "Received", tone: "green" },
  received_with_differences: { label: "Received — differences", tone: "red" }, rejected: { label: "Rejected", tone: "neutral" },
  cancelled: { label: "Withdrawn", tone: "neutral" },
};

type Figures = { sales_count: number; sales_total: number; net_sales: number; cash: number; card_qr: number; bank_cheque: number; credit: number;
  outstanding_to_ola: number; stock: { product: string; qty: number; value: number }[]; bottles: { company: string; type: string; fill_state: string; qty: number }[];
  walk_in_bottles: number; open_exceptions: number };
type Dash = {
  shop: ShopRow & { location_id: string; account: { id: string; customer_no: string; credit_limit: number; payment_terms_days: number } | null;
    retail_price_list: string; transfer_price_list: string | null };
  today: Figures; month: Figures;
  till: { id: string; session_no: string; opened_at: string; opening_float: number; opened_by: string; cash_expected: number; sales: number } | null;
  requests: { id: string; request_no: string; status: string; requested_at: string; items: { product: string; requested: number; approved: number | null; dispatched: number | null; received: number | null }[] }[];
  sessions: { id: string; session_no: string; status: string; opened_at: string; closed_at: string | null; cash_expected: number | null; cash_counted: number | null; exceptions: number | null; settled: boolean }[];
  settlements: { id: string; settlement_no: string; period_from: string; period_to: string; amount_received: number; cash_expected: number; commission: number; created_at: string }[];
  exceptions: { id: string; type: string; severity: string; description: string; created_at: string }[];
  recent_sales: { id: string; receipt_no: string; sold_at: string; total: number; customer: string; walk_in: boolean }[];
  unsettled_cash: number;
};

export default async function ShopPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("shop_dashboard", { p_shop: id });
  if (error?.code === "42501") notFound();
  if (error || !data) notFound();
  const d = data as Dash;
  const s = d.shop;
  const dealer = s.operating_model === "dealer";
  const atShop = can(access, "shop_pos.use") || access.scoped.some((x) => x.permission === "shop_pos.use" && x.location_id === s.location_id);
  const [{ data: products }, { data: lists }, reqItems] = await Promise.all([
    supabase.from("products").select("id, name").eq("is_active", true).order("sort_order"),
    supabase.from("price_lists").select("id, name, code").eq("is_active", true).order("name"),
    supabase.from("shop_stock_request_items").select("request_id, product_id, dispatched_qty, product:products(name)")
      .in("request_id", d.requests.filter((r) => r.status === "dispatched").map((r) => r.id).concat(["00000000-0000-0000-0000-000000000000"])),
  ]);
  const today = todayISO();
  const monthStart = `${today.slice(0, 8)}01`;

  return (
    <>
      {can(access, "shops.view") && (
        <Link href="/shops" className="mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> All shops</Link>
      )}
      <PageHeader title={s.name}
        description={[s.code, dealer ? `Dealer: ${s.owner_name ?? "—"}` : "OLA-owned", s.phone ? formatPhone(s.phone) : null, s.city].filter(Boolean).join(" · ")}
        actions={
          <>
            {s.status !== "active" && <Badge className="self-center capitalize">{s.status}</Badge>}
            {atShop && s.status === "active" && (
              <Link href={`/pos?location=${s.location_id}`} className={buttonVariants({ size: "md" })}><Calculator className="h-4 w-4" /> {d.till ? "Go to till" : "Open till"}</Link>
            )}
            {(atShop || can(access, "shops.manage")) && s.status === "active" && (
              <FormDialog trigger={<><PackagePlus className="h-4 w-4" /> Request stock</>} triggerSize="md" title="Request stock from the warehouse"
                submitLabel="Send request" action={createRequest} hidden={{ shop_id: s.id }}>
                <div className="grid gap-3 sm:grid-cols-2">
                  {products?.map((p) => (
                    <Field key={p.id} label={p.name} htmlFor={`rq-${p.id}`}><Input id={`rq-${p.id}`} name={`qty:${p.id}`} type="number" min={0} placeholder="0" /></Field>
                  ))}
                </div>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field label="Needed by" htmlFor="rq-need"><Input id="rq-need" name="needed_by" type="date" min={today} /></Field>
                  <Field label="Notes" htmlFor="rq-notes"><Input id="rq-notes" name="notes" /></Field>
                </div>
              </FormDialog>
            )}
            <form action={`/print/shop-statement/${s.id}`} target="_blank" className="flex items-end gap-1">
              <input type="date" name="from" defaultValue={monthStart} aria-label="Statement from" className="h-10 rounded-lg border border-line px-2 text-sm" />
              <input type="date" name="to" defaultValue={today} aria-label="Statement to" className="h-10 rounded-lg border border-line px-2 text-sm" />
              <Button type="submit" variant="secondary"><FileText className="h-4 w-4" /> Statement</Button>
            </form>
          </>
        } />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Stat label="Sales today" value={formatLKR(d.today.sales_total)} hint={`${d.today.sales_count} receipt(s) · cash ${formatLKR(d.today.cash)} · card/QR ${formatLKR(d.today.card_qr)}`} />
        <Stat label="This month" value={formatLKR(d.month.sales_total)} hint={`${d.month.sales_count} receipt(s)`} />
        {dealer
          ? <Stat label="Owes OLA" value={formatLKR(d.today.outstanding_to_ola)} hint={`Credit limit ${formatLKR(s.account?.credit_limit ?? 0)} · ${s.account?.payment_terms_days ?? 0} days`} />
          : <Stat label="Takings to bank" value={formatLKR(d.unsettled_cash)} hint="Counted at closing, not yet settled" />}
        <Stat label="Till" value={d.till ? "Open" : "Closed"} hint={d.till ? `${d.till.session_no} · ${d.till.sales} sale(s) · ${formatLKR(d.till.cash_expected)} in drawer` : "Open it from the till screen"} />
      </div>

      {d.exceptions.length > 0 && (
        <Card className="mb-6">
          <CardHeader title="Needs attention" actions={can(access, ["deliveries.reconcile", "shops.settle", "inventory.adjust"]) &&
            <Link href="/exceptions" className="text-sm font-medium text-ola-700 hover:underline">Resolve</Link>} />
          <ul className="divide-y divide-line">
            {d.exceptions.map((e) => { const b = statusBadge(SEVERITY, e.severity); return (
              <li key={e.id} className="flex flex-wrap items-center gap-2 px-5 py-3 text-sm"><Badge tone={b.tone}>{b.label}</Badge><span className="flex-1">{e.description}</span>
                <span className="text-xs text-muted">{formatDateTime(e.created_at)}</span></li>); })}
          </ul>
        </Card>
      )}

      <div className="grid gap-6 xl:grid-cols-2">
        <div className="space-y-6">
          <Card>
            <CardHeader title="Stock requests" />
            {d.requests.length === 0 ? <CardBody><p className="text-sm text-muted">No requests yet.</p></CardBody> : (
              <ul className="divide-y divide-line">
                {d.requests.map((r) => {
                  const b = REQ[r.status] ?? { label: r.status, tone: "neutral" as BadgeTone };
                  const items = (reqItems.data ?? []).filter((i) => i.request_id === r.id);
                  return (
                    <li key={r.id} className="px-5 py-3 text-sm">
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <span><span className="font-medium">{r.request_no}</span> <span className="text-muted">· {formatDateTime(r.requested_at)}</span></span>
                        <span className="flex items-center gap-2">
                          <Badge tone={b.tone}>{b.label}</Badge>
                          {r.status === "dispatched" && (atShop || can(access, "shops.manage")) && (
                            <FormDialog trigger="Receive" triggerVariant="primary" title={`Receive ${r.request_no}`}
                              description="Count what actually arrived. Any difference is reported to the warehouse automatically." submitLabel="Confirm receipt"
                              action={receiveRequest} hidden={{ request_id: r.id, shop_id: s.id }}>
                              {items.map((i) => (
                                <Field key={i.product_id} label={`${(i.product as unknown as { name: string }).name} — ${i.dispatched_qty} sent`} htmlFor={`rc-${r.id}-${i.product_id}`}>
                                  <Input id={`rc-${r.id}-${i.product_id}`} name={`qty:${i.product_id}`} type="number" min={0} defaultValue={i.dispatched_qty ?? 0} required />
                                </Field>
                              ))}
                              <Field label="Notes" htmlFor={`rcn-${r.id}`}><Input id={`rcn-${r.id}`} name="notes" /></Field>
                            </FormDialog>
                          )}
                          {r.status === "submitted" && atShop && (
                            <ReasonDialog trigger="Withdraw" triggerVariant="ghost" title="Withdraw request" confirmLabel="Withdraw" action={withdrawRequest}
                              hidden={{ request_id: r.id, shop_id: s.id }} />
                          )}
                        </span>
                      </div>
                      <p className="mt-1 text-muted">{r.items.map((i) => `${i.product}: ${i.requested}${i.approved !== null && i.approved !== i.requested ? ` (approved ${i.approved})` : ""}${i.received !== null ? ` → received ${i.received}` : ""}`).join(" · ")}</p>
                    </li>
                  );
                })}
              </ul>
            )}
          </Card>

          <Card>
            <CardHeader title="Recent sales" />
            <Table>
              <tbody>
                {d.recent_sales.length === 0 && <tr><Td className="text-muted">No sales yet.</Td></tr>}
                {d.recent_sales.map((x) => (
                  <tr key={x.id}>
                    <Td><a href={`/print/pos-receipt/${x.id}`} target="_blank" rel="noopener" className="font-mono text-xs text-ola-700 hover:underline">{x.receipt_no}</a></Td>
                    <Td>{x.walk_in ? <span className="text-muted">Walk-in</span> : x.customer}</Td>
                    <Td className="whitespace-nowrap">{formatDateTime(x.sold_at)}</Td>
                    <Td className="num text-right">{formatLKR(x.total)}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </Card>
        </div>

        <div className="space-y-6">
          <Card>
            <CardHeader title="Stock and bottles at the shop" description={dealer ? "Stock belongs to the dealer once received; OLA bottles stay OLA's." : undefined} />
            <Table>
              <tbody>
                {d.today.stock.length === 0 && d.today.bottles.length === 0 && <tr><Td className="text-muted">Nothing recorded yet.</Td></tr>}
                {d.today.stock.map((x) => <tr key={x.product}><Td>{x.product}</Td><Td className="num text-right">{Number(x.qty)}</Td></tr>)}
                {d.today.bottles.filter((b) => b.fill_state === "empty").map((b) => (
                  <tr key={`${b.company}-${b.type}`}><Td>{b.company} {b.type} empties</Td><Td className={`num text-right ${b.qty < 0 ? "text-red-700" : ""}`}>{b.qty}</Td></tr>
                ))}
                <tr><Td className="text-muted">OLA bottles held by walk-in customers</Td><Td className="num text-right text-muted">{d.today.walk_in_bottles}</Td></tr>
              </tbody>
            </Table>
          </Card>

          <Card>
            <CardHeader title="Tills" />
            <Table>
              <thead><tr><Th>Till</Th><Th>Opened</Th><Th className="text-right">Expected</Th><Th className="text-right">Counted</Th><Th /></tr></thead>
              <tbody>
                {d.sessions.length === 0 && <tr><Td colSpan={5} className="text-muted">The till has not been opened yet.</Td></tr>}
                {d.sessions.map((x) => (
                  <tr key={x.id}>
                    <Td className="font-mono text-xs">{x.session_no}</Td>
                    <Td className="whitespace-nowrap">{formatDateTime(x.opened_at)}</Td>
                    <Td className="num text-right">{x.cash_expected !== null ? formatLKR(x.cash_expected) : "—"}</Td>
                    <Td className={`num text-right ${x.cash_counted !== null && x.cash_expected !== null && Number(x.cash_counted) !== Number(x.cash_expected) ? "text-red-700" : ""}`}>{x.cash_counted !== null ? formatLKR(x.cash_counted) : "—"}</Td>
                    <Td>{x.status === "open" ? <Badge tone="green">Open</Badge> : x.settled ? <Badge tone="neutral">Settled</Badge> : <Badge tone="amber">To settle</Badge>}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </Card>

          <Card>
            <CardHeader title="Settlements" description={dealer ? "Payments received from the dealer against its account." : "Takings banked from the shop."}
              actions={can(access, "shops.settle") && (
                <FormDialog trigger="New settlement" title={`Settle ${s.name}`}
                  description={dealer ? `The dealer currently owes ${formatLKR(d.today.outstanding_to_ola)}.` : `Counted takings not yet banked: ${formatLKR(d.unsettled_cash)}. Close the till first.`}
                  submitLabel="Save settlement" action={settleShop} hidden={{ shop_id: s.id }}>
                  <div className="grid gap-4 sm:grid-cols-2">
                    <Field label="From" htmlFor="st-from"><Input id="st-from" name="from" type="date" defaultValue={today} required /></Field>
                    <Field label="To" htmlFor="st-to"><Input id="st-to" name="to" type="date" defaultValue={today} required /></Field>
                    <Field label={dealer ? "Amount paid by the dealer (Rs.)" : "Amount banked (Rs.)"} htmlFor="st-amt">
                      <Input id="st-amt" name="amount" type="number" min={0} step="0.01" defaultValue={dealer ? "" : String(d.unsettled_cash)} />
                    </Field>
                    <Field label="Method" htmlFor="st-m"><Select id="st-m" name="method" defaultValue="bank_transfer">{PAYMENT_METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
                  </div>
                  <Field label="Reference" htmlFor="st-ref" hint="Bank slip or cheque number"><Input id="st-ref" name="reference" /></Field>
                  <Field label="Notes" htmlFor="st-notes"><Input id="st-notes" name="notes" /></Field>
                </FormDialog>
              )} />
            <Table>
              <tbody>
                {d.settlements.length === 0 && <tr><Td className="text-muted">No settlements yet.</Td></tr>}
                {d.settlements.map((x) => (
                  <tr key={x.id}>
                    <Td className="font-medium">{x.settlement_no}<span className="block text-xs font-normal text-muted">{formatDate(x.period_from)}{x.period_to !== x.period_from && ` – ${formatDate(x.period_to)}`}</span></Td>
                    <Td className="num text-right">{formatLKR(x.amount_received)}{!dealer && Number(x.amount_received) < Number(x.cash_expected) && <span className="block text-xs text-red-700">expected {formatLKR(x.cash_expected)}</span>}</Td>
                    <Td className="text-right text-xs text-muted">{Number(x.commission) > 0 && `Commission ${formatLKR(x.commission)}`}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </Card>

          {can(access, "shops.manage") && (
            <Card>
              <details>
                <summary className="cursor-pointer px-5 py-4 text-base font-semibold text-navy-900">Edit shop details</summary>
                <CardBody className="border-t border-line">
                  <EditShop s={s} lists={lists ?? []} />
                </CardBody>
              </details>
            </Card>
          )}
        </div>
      </div>
      {!dealer && Number(d.month.credit) > 0 && <Alert tone="info" className="mt-6">{formatLKR(d.month.credit)} sold on account this month — collected through the customers&apos; accounts.</Alert>}
      <p className="mt-6 text-xs text-muted">Prices at the till: {s.retail_price_list}{dealer && s.transfer_price_list ? ` · Dealer pays: ${s.transfer_price_list}` : ""}. {humanize(s.status)}.</p>
    </>
  );
}

function EditShop({ s, lists }: { s: ShopRow; lists: { id: string; name: string; code: string }[] }) {
  return (
    <ActionForm action={updateShop}>
      <input type="hidden" name="id" value={s.id} />
      <input type="hidden" name="code" value={s.code} />
      <ShopFields s={s} priceLists={lists} canCredit={false} />
      <Field label="Reason for change" htmlFor="shop-reason"><Input id="shop-reason" name="reason" /></Field>
      <SubmitButton>Save shop</SubmitButton>
    </ActionForm>
  );
}
