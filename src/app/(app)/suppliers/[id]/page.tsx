import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR, formatPhone, formatQty, humanize } from "@/lib/format";
import { PO_STATUS, SUPPLIER_INVOICE_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { LineEditor } from "@/components/ui/line-editor";
import { SupplierFields, type Supplier } from "../supplier-fields";
import { paySupplier, saveSupplierItems, updateSupplier } from "../actions";

export const metadata: Metadata = { title: "Supplier" };

type Details = {
  supplier: Supplier; outstanding: number; advance: number;
  items: { product_id: string; name: string; unit: string; supplier_sku: string | null; unit_price: number; lead_time_days: number | null }[];
  orders: { id: string; po_no: string; order_date: string; expected_date: string | null; status: string; total: number }[];
  invoices: { id: string; ref_no: string; supplier_invoice_no: string; invoice_date: string; due_date: string; total: number; amount_paid: number;
    balance: number; status: string; match_status: string; po_no: string }[];
  payments: { id: string; payment_no: string; paid_at: string; method: string; amount: number; unallocated: number; reference: string | null }[];
  performance: { receipts: number; on_time: number; qty_received: number; qty_rejected: number; mismatched_invoices: number };
};

export default async function SupplierPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["procurement.view", "suppliers.manage", "payments.view"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [{ data, error }, { data: items }] = await Promise.all([
    supabase.rpc("supplier_details", { p_supplier: id }),
    supabase.from("products").select("id, name, unit, item_type").eq("is_active", true).order("item_type").order("name"),
  ]);
  if (error || !data) notFound();
  const d = data as Details;
  const s = d.supplier;
  const perf = d.performance;
  const open = d.invoices.filter((i) => i.status === "approved" || i.status === "partially_paid");
  const today = new Date().toISOString().slice(0, 10);

  return (
    <>
      <Link href="/suppliers" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Suppliers</Link>
      <PageHeader title={s.name} description={[s.code, s.contact_person, s.phone && formatPhone(s.phone), s.email, s.city, s.vat_no && `VAT ${s.vat_no}`].filter(Boolean).join(" · ")}
        actions={<>
          {can(access, "payments.manage") && (
            <FormDialog trigger="Record payment" triggerVariant="primary" triggerSize="md" title={`Pay ${s.name}`}
              description={`Owed: ${formatLKR(d.outstanding)}. Without a chosen invoice, the oldest invoices are paid first.`} submitLabel="Save payment" action={paySupplier}
              hidden={{ supplier_id: s.id }}>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Amount (Rs.)" htmlFor="sp-amt" required><Input id="sp-amt" name="amount" type="number" min={0.01} step="0.01" required /></Field>
                <Field label="Paid by" htmlFor="sp-m"><Select id="sp-m" name="method" defaultValue="bank_transfer">
                  <option value="bank_transfer">Bank transfer</option><option value="cheque">Cheque</option><option value="cash">Cash</option></Select></Field>
              </div>
              <Field label="Bank reference / cheque no." htmlFor="sp-ref" hint="Required for bank and cheque payments"><Input id="sp-ref" name="reference" /></Field>
              <Field label="Apply to" htmlFor="sp-inv"><Select id="sp-inv" name="invoice" defaultValue="">
                <option value="">Oldest invoices first</option>
                {open.map((i) => <option key={i.id} value={`${i.id}|${i.balance}`}>{i.supplier_invoice_no} — {formatLKR(i.balance)} due {formatDate(i.due_date)}</option>)}
              </Select></Field>
              <Field label="Notes" htmlFor="sp-n"><Textarea id="sp-n" name="notes" /></Field>
            </FormDialog>
          )}
          {can(access, "suppliers.manage") && (
            <FormDialog trigger="Edit supplier" triggerSize="md" title={`Edit ${s.name}`} submitLabel="Save" action={updateSupplier} hidden={{ id: s.id, code: s.code }} wide>
              <SupplierFields s={s} />
            </FormDialog>
          )}
        </>} />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="We owe" value={formatLKR(d.outstanding)} hint={Number(d.advance) > 0 ? `Includes ${formatLKR(d.advance)} paid in advance` : `${s.payment_terms_days} days terms`} />
        <Stat label="Deliveries on time" value={perf.receipts ? `${Math.round((100 * perf.on_time) / perf.receipts)}%` : "—"} hint={`${perf.on_time} of ${perf.receipts} deliveries`} />
        <Stat label="Rejected at delivery" value={Number(perf.qty_received) + Number(perf.qty_rejected) > 0 ? `${((100 * Number(perf.qty_rejected)) / (Number(perf.qty_received) + Number(perf.qty_rejected))).toFixed(1)}%` : "—"}
          hint={`${formatQty(perf.qty_rejected)} unit(s) rejected`} />
        <Stat label="Invoices not matching the order" value={perf.mismatched_invoices} />
      </div>

      <div className="space-y-6">
        <Card>
          <CardHeader title="Prices from this supplier" description="Suggested on new purchase orders."
            actions={can(access, "suppliers.manage") && (
              <FormDialog trigger="Edit prices" title={`Prices — ${s.name}`} description="Price per unit before VAT." submitLabel="Save prices" action={saveSupplierItems}
                hidden={{ supplier_id: s.id }} wide>
                <LineEditor name="lines" items={(items ?? []).map((i) => ({ id: i.id, name: i.name, unit: i.unit }))} addLabel="Add item"
                  columns={[{ key: "supplier_sku", label: "Their code", className: "w-32" }, { key: "unit_price", label: "Price (Rs.)", type: "number", step: "0.0001", min: 0 },
                    { key: "lead_time_days", label: "Lead days", type: "number", min: 0, className: "w-24" }]}
                  initial={d.items.map((i) => ({ item_id: i.product_id, supplier_sku: i.supplier_sku ?? "", unit_price: String(Number(i.unit_price)),
                    lead_time_days: i.lead_time_days === null ? "" : String(i.lead_time_days) }))} />
              </FormDialog>
            )} />
          {d.items.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No prices recorded.</p> : (
            <Table>
              <thead><tr><Th>Item</Th><Th>Their code</Th><Th className="text-right">Price</Th><Th className="text-right">Lead time</Th></tr></thead>
              <tbody>{d.items.map((i) => (
                <tr key={i.product_id}><Td>{i.name}</Td><Td className="font-mono text-xs">{i.supplier_sku ?? "—"}</Td>
                  <Td className="num text-right">{formatLKR(i.unit_price)} <span className="text-xs text-muted">/ {i.unit}</span></Td>
                  <Td className="num text-right">{i.lead_time_days === null ? "—" : `${i.lead_time_days} days`}</Td></tr>))}</tbody>
            </Table>
          )}
        </Card>

        <Card>
          <CardHeader title="Invoices" />
          {d.invoices.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No invoices yet.</p> : (
            <Table>
              <thead><tr><Th>Invoice</Th><Th>Order</Th><Th>Date</Th><Th>Due</Th><Th className="text-right">Total</Th><Th className="text-right">Balance</Th><Th>Status</Th></tr></thead>
              <tbody>{d.invoices.map((i) => { const st = statusBadge(SUPPLIER_INVOICE_STATUS, i.status); const late = (i.status === "approved" || i.status === "partially_paid") && i.due_date < today; return (
                <tr key={i.id}><Td><span className="font-medium">{i.supplier_invoice_no}</span><span className="block font-mono text-xs text-muted">{i.ref_no}</span></Td>
                  <Td>{i.po_no}</Td><Td>{formatDate(i.invoice_date)}</Td><Td className={late ? "font-semibold text-red-700" : ""}>{formatDate(i.due_date)}</Td>
                  <Td className="num text-right">{formatLKR(i.total)}</Td><Td className="num text-right">{i.status === "void" ? "—" : formatLKR(i.balance)}</Td>
                  <Td><Badge tone={st.tone}>{st.label}</Badge>{i.match_status === "override" && <Badge tone="amber" className="ml-1">Approved mismatch</Badge>}</Td></tr>); })}</tbody>
            </Table>
          )}
        </Card>

        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader title="Purchase orders" />
            {d.orders.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No orders yet.</p> : (
              <Table>
                <thead><tr><Th>Order</Th><Th>Date</Th><Th className="text-right">Total</Th><Th>Status</Th></tr></thead>
                <tbody>{d.orders.map((o) => { const st = statusBadge(PO_STATUS, o.status); return (
                  <tr key={o.id}><Td><Link href={`/purchasing/${o.id}`} className="font-medium text-ola-700 hover:underline">{o.po_no}</Link></Td>
                    <Td>{formatDate(o.order_date)}</Td><Td className="num text-right">{formatLKR(o.total)}</Td><Td><Badge tone={st.tone}>{st.label}</Badge></Td></tr>); })}</tbody>
              </Table>
            )}
          </Card>
          <Card>
            <CardHeader title="Payments" />
            {d.payments.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No payments yet.</p> : (
              <Table>
                <thead><tr><Th>Payment</Th><Th>When</Th><Th>How</Th><Th className="text-right">Amount</Th></tr></thead>
                <tbody>{d.payments.map((p) => (
                  <tr key={p.id}><Td className="font-mono text-xs">{p.payment_no}</Td><Td>{formatDateTime(p.paid_at)}</Td>
                    <Td>{humanize(p.method)}{p.reference && <span className="block text-xs text-muted">{p.reference}</span>}</Td>
                    <Td className="num text-right">{formatLKR(p.amount)}{Number(p.unallocated) > 0 && <span className="block text-xs text-amber-700">{formatLKR(p.unallocated)} advance</span>}</Td></tr>))}</tbody>
              </Table>
            )}
          </Card>
        </div>
      </div>
    </>
  );
}
