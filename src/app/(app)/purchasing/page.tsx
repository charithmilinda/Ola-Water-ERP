import type { Metadata } from "next";
import Link from "next/link";
import { Plus, ShoppingCart } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatQty } from "@/lib/format";
import { PO_STATUS, PR_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { LineEditor } from "@/components/ui/line-editor";
import { OrderFields, type RequestOpt, type SupplierOpt } from "./order-fields";
import { createOrder, createRequest, decideRequest } from "./actions";

export const metadata: Metadata = { title: "Purchasing" };

type PR = { id: string; request_no: string; status: string; needed_by: string | null; notes: string | null; requested_at: string; requested_by: string | null;
  decision_note: string | null; location_id: string; location: { name: string } | null;
  items: { product_id: string; qty: number; est_unit_price: number | null; product: { name: string; unit: string } | null }[] };
type PO = { id: string; po_no: string; status: string; order_date: string; expected_date: string | null; total: number; supplier: { name: string } | null;
  lines: { qty_ordered: number; qty_received: number }[] };

export default async function PurchasingPage() {
  const access = await requirePermission(["procurement.view", "inventory.manage"]);
  const supabase = await createClient();
  const [{ data: reqs }, { data: orders }, { data: held }, { data: suppliers }, { data: prices }, { data: items }, { data: locations }, { data: ops }] = await Promise.all([
    supabase.from("purchase_requests").select("id, request_no, status, needed_by, notes, requested_at, requested_by, decision_note, location_id, location:locations(name), items:purchase_request_items(product_id, qty, est_unit_price, product:products(name, unit))")
      .order("requested_at", { ascending: false }).limit(40),
    supabase.from("purchase_orders").select("id, po_no, status, order_date, expected_date, total, supplier:suppliers(name), lines:purchase_order_lines(qty_ordered, qty_received)")
      .order("order_date", { ascending: false }).order("po_no", { ascending: false }).limit(60),
    supabase.from("supplier_invoices").select("id, ref_no, supplier_invoice_no, total, match_notes, po_id, supplier:suppliers(name)").eq("status", "on_hold"),
    supabase.from("suppliers").select("id, name, vat_no").eq("is_active", true).order("name"),
    supabase.from("supplier_items").select("supplier_id, product_id, unit_price"),
    supabase.from("products").select("id, name, unit, item_type").eq("is_active", true).order("item_type", { ascending: false }).order("name"),
    supabase.from("locations").select("id, name").in("location_type", ["warehouse", "head_office"]).eq("is_active", true).order("name"),
    supabase.rpc("operations_summary"),
  ]);
  const pu = (ops as { purchasing?: Record<string, number> } | null)?.purchasing;
  const requests = (reqs ?? []) as unknown as PR[];
  const pos = (orders ?? []) as unknown as PO[];
  const manage = can(access, "procurement.manage");
  const approve = can(access, "procurement.approve");
  const supplierOpts: SupplierOpt[] = (suppliers ?? []).map((s) => ({ id: s.id, name: s.name, vat: !!s.vat_no,
    prices: Object.fromEntries((prices ?? []).filter((p) => p.supplier_id === s.id).map((p) => [p.product_id, Number(p.unit_price)])) }));
  const approved: RequestOpt[] = requests.filter((r) => r.status === "approved").map((r) => ({ id: r.id, request_no: r.request_no, location_id: r.location_id,
    items: r.items.map((i) => ({ product_id: i.product_id, qty: Number(i.qty), est_unit_price: i.est_unit_price === null ? null : Number(i.est_unit_price) })) }));
  const itemOpts = (items ?? []).map((i) => ({ id: i.id, name: i.name, unit: i.unit }));
  const orderDialog = (label: React.ReactNode, initialRequest?: string, variant: "primary" | "secondary" | "ghost" = "primary") => (
    <FormDialog trigger={label} triggerVariant={variant} triggerSize={variant === "ghost" ? "sm" : "md"} title="New purchase order"
      description="Orders below the purchase limit are approved straight away; larger ones wait for an approver." submitLabel="Create order" action={createOrder} wide>
      {supplierOpts.length === 0 ? <p className="text-sm text-red-700">Add a supplier first (Purchasing → Suppliers).</p> :
        <OrderFields suppliers={supplierOpts} locations={locations ?? []} requests={approved} items={itemOpts} initialRequest={initialRequest} />}
    </FormDialog>
  );

  return (
    <>
      <PageHeader title="Purchasing" description="Request → approve → order → receive the goods → match the supplier's invoice → pay."
        actions={<>
          {manage && (
            <FormDialog trigger="New request" triggerSize="md" title="New purchase request" description="Ask for materials; an approver decides." submitLabel="Send request"
              action={createRequest} wide>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Needed at" htmlFor="pr-l"><Select id="pr-l" name="location_id">{locations?.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
                <Field label="Needed by" htmlFor="pr-d"><Input id="pr-d" name="needed_by" type="date" /></Field>
              </div>
              <LineEditor name="lines" items={itemOpts} addLabel="Add item"
                columns={[{ key: "qty", label: "Qty", type: "number", step: "any", min: 0 }, { key: "est_unit_price", label: "Est. price", type: "number", step: "0.01", min: 0 },
                  { key: "notes", label: "Note", className: "w-40" }]} />
              <Field label="Why is it needed?" htmlFor="pr-n"><Textarea id="pr-n" name="notes" /></Field>
            </FormDialog>
          )}
          {manage && orderDialog(<><Plus className="h-4 w-4" /> New order</>)}
        </>} />

      {pu && (
        <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Stat label="Waiting for approval" value={Number(pu.requests_waiting) + Number(pu.orders_waiting)} hint={`${pu.requests_waiting} request(s), ${pu.orders_waiting} order(s)`} />
          <Stat label="Open orders" value={pu.orders_open} hint={Number(pu.orders_late) > 0 ? `${pu.orders_late} late` : "None late"} />
          <Stat label="Invoices on hold" value={pu.invoices_on_hold} hint="Don't match the order or the goods received" />
          <Stat label="Owed to suppliers" value={formatLKR(pu.payable)} hint={`${formatLKR(pu.payable_overdue)} overdue · ${formatLKR(pu.due_7_days)} due in 7 days`} />
        </div>
      )}

      <div className="space-y-6">
        {(held ?? []).length > 0 && (
          <Card className="border-red-200">
            <CardHeader title="Supplier invoices on hold" description="Open the order to accept or reject each one." />
            <Table>
              <thead><tr><Th>Invoice</Th><Th>Supplier</Th><Th className="text-right">Total</Th><Th>Why</Th></tr></thead>
              <tbody>{(held as unknown as { id: string; ref_no: string; supplier_invoice_no: string; total: number; match_notes: string[]; po_id: string; supplier: { name: string } | null }[]).map((i) => (
                <tr key={i.id}><Td><Link href={`/purchasing/${i.po_id}`} className="font-medium text-ola-700 hover:underline">{i.supplier_invoice_no}</Link>
                  <span className="block font-mono text-xs text-muted">{i.ref_no}</span></Td><Td>{i.supplier?.name}</Td>
                  <Td className="num text-right">{formatLKR(i.total)}</Td><Td className="text-sm text-red-800">{i.match_notes.join("; ")}</Td></tr>))}</tbody>
            </Table>
          </Card>
        )}

        <Card>
          <CardHeader title="Purchase requests" />
          {requests.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No requests yet.</p> : (
            <Table>
              <thead><tr><Th>Request</Th><Th>Items</Th><Th>Needed</Th><Th>Status</Th><Th /></tr></thead>
              <tbody>{requests.map((r) => { const st = statusBadge(PR_STATUS, r.status); return (
                <tr key={r.id}>
                  <Td><span className="font-medium">{r.request_no}</span><span className="block text-xs text-muted">{formatDate(r.requested_at)} · {r.location?.name}</span></Td>
                  <Td className="text-sm">{r.items.map((i) => <span key={i.product_id} className="block">{formatQty(i.qty)} {i.product?.unit} {i.product?.name}</span>)}
                    {r.notes && <span className="block text-xs text-muted">{r.notes}</span>}</Td>
                  <Td>{r.needed_by ? formatDate(r.needed_by) : "—"}</Td>
                  <Td><Badge tone={st.tone}>{st.label}</Badge>{r.decision_note && <span className="block text-xs text-muted">{r.decision_note}</span>}</Td>
                  <Td className="space-x-1 whitespace-nowrap text-right">
                    {approve && r.status === "submitted" && (
                      <>
                        <ReasonDialog trigger="Approve" triggerVariant="primary" title={`Approve ${r.request_no}`} confirmLabel="Approve" action={decideRequest}
                          hidden={{ request_id: r.id, decision: "approve" }} reasonRequired={false} />
                        <ReasonDialog trigger="Reject" triggerVariant="dangerOutline" title={`Reject ${r.request_no}`} confirmLabel="Reject" confirmVariant="danger"
                          action={decideRequest} hidden={{ request_id: r.id, decision: "reject" }} />
                      </>
                    )}
                    {manage && r.status === "approved" && orderDialog("Order", r.id, "ghost")}
                  </Td>
                </tr>); })}</tbody>
            </Table>
          )}
        </Card>

        <Card>
          <CardHeader title="Purchase orders" />
          {pos.length === 0 ? <EmptyState icon={ShoppingCart} title="No purchase orders yet" /> : (
            <Table>
              <thead><tr><Th>Order</Th><Th>Supplier</Th><Th>Ordered</Th><Th>Expected</Th><Th className="text-right">Total</Th><Th className="text-right">Received</Th><Th>Status</Th></tr></thead>
              <tbody>{pos.map((o) => {
                const st = statusBadge(PO_STATUS, o.status);
                const ord = o.lines.reduce((a, l) => a + Number(l.qty_ordered), 0);
                const rec = o.lines.reduce((a, l) => a + Number(l.qty_received), 0);
                const late = (o.status === "approved" || o.status === "partially_received") && o.expected_date && o.expected_date < new Date().toISOString().slice(0, 10);
                return (
                  <tr key={o.id} className="hover:bg-ola-50/40">
                    <Td><Link href={`/purchasing/${o.id}`} className="font-medium text-ola-700 hover:underline">{o.po_no}</Link></Td>
                    <Td>{o.supplier?.name}</Td><Td>{formatDate(o.order_date)}</Td>
                    <Td className={late ? "font-semibold text-red-700" : ""}>{o.expected_date ? formatDate(o.expected_date) : "—"}</Td>
                    <Td className="num text-right">{formatLKR(o.total)}</Td>
                    <Td className="num text-right">{ord ? `${Math.round((100 * rec) / ord)}%` : "—"}</Td>
                    <Td><Badge tone={st.tone}>{st.label}</Badge></Td>
                  </tr>
                );
              })}</tbody>
            </Table>
          )}
        </Card>
      </div>
    </>
  );
}
