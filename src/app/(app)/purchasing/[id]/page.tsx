import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Printer } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR, formatQty, todayISO } from "@/lib/format";
import { PO_STATUS, SUPPLIER_INVOICE_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { closeOrder, decideInvoice, decideOrder, receiveOrder, recordInvoice } from "../actions";

export const metadata: Metadata = { title: "Purchase order" };

type Line = { id: string; line_no: number; product_id: string; name: string; sku: string; unit: string; qty_ordered: number; unit_price: number; tax_rate: number;
  net: number; tax: number; total: number; qty_received: number; qty_rejected: number; qty_invoiced: number };
type Details = {
  order: { id: string; po_no: string; status: string; order_date: string; expected_date: string | null; subtotal: number; tax_total: number; total: number;
    notes: string | null; decision_note: string | null; created_by_name: string | null; approved_by_name: string | null; approved_at: string | null;
    request_no: string | null; location: string; purchase_limit: number };
  supplier: { id: string; name: string; vat_no: string | null; payment_terms_days: number };
  lines: Line[];
  receipts: { id: string; grn_no: string; received_at: string; delivery_note_no: string | null; on_time: boolean | null; received_by: string | null; value: number;
    lines: { name: string; qty_received: number; qty_rejected: number; reject_reason: string | null; supplier_lot: string | null; expiry_date: string | null }[] }[];
  invoices: { id: string; ref_no: string; supplier_invoice_no: string; invoice_date: string; due_date: string; total: number; amount_paid: number; status: string;
    match_status: string; match_notes: string[]; decision_note: string | null }[];
};

export default async function PurchaseOrderPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["procurement.view", "inventory.manage", "payments.view"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_order_details", { p_po: id });
  if (error || !data) notFound();
  const d = data as Details;
  const o = d.order;
  const st = statusBadge(PO_STATUS, o.status);
  const hidden = { po_id: o.id };
  const receivable = o.status === "approved" || o.status === "partially_received";
  const canReceive = can(access, ["inventory.manage", "procurement.manage"]) && receivable;
  const toInvoice = d.lines.filter((l) => Number(l.qty_received) - Number(l.qty_invoiced) > 0);
  const canInvoice = can(access, ["procurement.manage", "payments.manage"]) && !["pending_approval", "cancelled"].includes(o.status) && toInvoice.length > 0;
  const approve = can(access, "procurement.approve");

  return (
    <>
      <Link href="/purchasing" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Purchasing</Link>
      <PageHeader title={`Purchase order ${o.po_no}`}
        description={`${d.supplier.name} · ordered ${formatDate(o.order_date)}${o.expected_date ? ` · expected ${formatDate(o.expected_date)}` : ""} · deliver to ${o.location}${o.request_no ? ` · from ${o.request_no}` : ""}`}
        actions={<div className="flex flex-wrap items-center gap-2">
          <Badge tone={st.tone} className="text-sm">{st.label}</Badge>
          {o.status !== "pending_approval" && o.status !== "cancelled" && (
            <a href={`/print/purchase-order/${o.id}`} target="_blank" rel="noreferrer" className={buttonVariants({ variant: "secondary", size: "sm" })}><Printer className="h-4 w-4" /> Print / PDF</a>
          )}
          {approve && o.status === "pending_approval" && (
            <ReasonDialog trigger="Approve order" triggerVariant="primary" title={`Approve ${o.po_no}`} description={`Total ${formatLKR(o.total)} (limit for automatic approval ${formatLKR(o.purchase_limit)}).`}
              confirmLabel="Approve" action={decideOrder} hidden={{ ...hidden, decision: "approve" }} reasonRequired={false} />
          )}
          {(approve || (o.status === "pending_approval" && can(access, "procurement.manage"))) && (o.status === "pending_approval" || (o.status === "approved" && d.receipts.length === 0)) && (
            <ReasonDialog trigger="Cancel order" triggerVariant="dangerOutline" title={`Cancel ${o.po_no}`} confirmLabel="Cancel order" confirmVariant="danger"
              action={decideOrder} hidden={{ ...hidden, decision: "cancel" }} />
          )}
          {can(access, "procurement.manage") && o.status === "partially_received" && (
            <ReasonDialog trigger="Close (no more coming)" title={`Close ${o.po_no}`} description="The rest of the order will not be delivered."
              confirmLabel="Close order" action={closeOrder} hidden={hidden} />
          )}
        </div>} />

      {o.status === "pending_approval" && <Alert tone="warning" className="mb-4">This order is over the purchase limit ({formatLKR(o.purchase_limit)}) and waits for an approver. Do not send it to the supplier yet.</Alert>}
      {o.decision_note && <Alert tone="info" className="mb-4">{o.decision_note}</Alert>}

      <Card className="mb-6">
        <CardHeader title="Order lines" description={`Created by ${o.created_by_name ?? "—"}${o.approved_by_name ? ` · approved by ${o.approved_by_name}` : ""}`}
          actions={<div className="flex flex-wrap gap-2">
            {canReceive && (
              <FormDialog trigger="Receive goods" triggerVariant="primary" title={`Goods received — ${o.po_no}`}
                description="Count what arrived. Rejected goods (damaged, wrong item) stay with the driver and are not added to stock." submitLabel="Receive into stock"
                action={receiveOrder} hidden={hidden} wide>
                <Field label="Supplier's delivery note no." htmlFor="gr-dn"><Input id="gr-dn" name="delivery_note_no" /></Field>
                <div className="overflow-x-auto rounded-lg border border-line">
                  <table className="w-full text-sm">
                    <thead className="bg-surface text-left text-xs text-muted"><tr><th className="px-2 py-2">Item</th><th className="px-2 py-2 text-right">Still due</th>
                      <th className="px-2 py-2">Accepted</th><th className="px-2 py-2">Rejected</th><th className="px-2 py-2">Reject reason</th><th className="px-2 py-2">Lot</th><th className="px-2 py-2">Expiry</th></tr></thead>
                    <tbody>{d.lines.map((l) => { const due = Number(l.qty_ordered) - Number(l.qty_received); return (
                      <tr key={l.id} className="border-t border-line">
                        <td className="px-2 py-1.5">{l.name}</td><td className="num px-2 py-1.5 text-right">{formatQty(due)} {l.unit}</td>
                        <td className="w-24 px-2 py-1.5"><Input aria-label={`${l.name} accepted`} name={`rcv:${l.id}`} type="number" min={0} max={due} step="any" defaultValue={due > 0 ? due : 0} className="text-right" /></td>
                        <td className="w-24 px-2 py-1.5"><Input aria-label={`${l.name} rejected`} name={`rej:${l.id}`} type="number" min={0} step="any" defaultValue={0} className="text-right" /></td>
                        <td className="px-2 py-1.5"><Input aria-label={`${l.name} reject reason`} name={`why:${l.id}`} /></td>
                        <td className="w-24 px-2 py-1.5"><Input aria-label={`${l.name} lot`} name={`lot:${l.id}`} /></td>
                        <td className="w-36 px-2 py-1.5"><Input aria-label={`${l.name} expiry`} name={`exp:${l.id}`} type="date" /></td>
                      </tr>); })}</tbody>
                  </table>
                </div>
                <Field label="Notes" htmlFor="gr-n"><Input id="gr-n" name="notes" /></Field>
              </FormDialog>
            )}
            {canInvoice && (
              <FormDialog trigger="Record supplier invoice" title={`Supplier invoice — ${o.po_no}`}
                description="Enter what the invoice says. It is matched against the order and the goods received; anything that differs is held for approval."
                submitLabel="Save invoice" action={recordInvoice} hidden={hidden} wide>
                <div className="grid gap-4 sm:grid-cols-3">
                  <Field label="Their invoice no." htmlFor="si-no" required><Input id="si-no" name="supplier_invoice_no" required /></Field>
                  <Field label="Invoice date" htmlFor="si-d"><Input id="si-d" name="invoice_date" type="date" defaultValue={todayISO()} /></Field>
                  <Field label="Due date" htmlFor="si-due" hint={`Blank = ${d.supplier.payment_terms_days} days`}><Input id="si-due" name="due_date" type="date" /></Field>
                </div>
                <div className="overflow-x-auto rounded-lg border border-line">
                  <table className="w-full text-sm">
                    <thead className="bg-surface text-left text-xs text-muted"><tr><th className="px-2 py-2">Item</th><th className="px-2 py-2 text-right">Received, not billed</th>
                      <th className="px-2 py-2">Qty billed</th><th className="px-2 py-2">Price</th><th className="px-2 py-2">VAT %</th></tr></thead>
                    <tbody>{toInvoice.map((l) => { const open = Number(l.qty_received) - Number(l.qty_invoiced); return (
                      <tr key={l.id} className="border-t border-line">
                        <td className="px-2 py-1.5">{l.name}<span className="block text-xs text-muted">Order price {formatLKR(l.unit_price)}</span></td>
                        <td className="num px-2 py-1.5 text-right">{formatQty(open)}</td>
                        <td className="w-24 px-2 py-1.5"><Input aria-label={`${l.name} qty billed`} name={`iq:${l.id}`} type="number" min={0} step="any" defaultValue={open} className="text-right" /></td>
                        <td className="w-32 px-2 py-1.5"><Input aria-label={`${l.name} price`} name={`ip:${l.id}`} type="number" min={0} step="0.0001" defaultValue={Number(l.unit_price)} className="text-right" /></td>
                        <td className="w-20 px-2 py-1.5"><Input aria-label={`${l.name} VAT`} name={`iv:${l.id}`} type="number" min={0} step="any" defaultValue={Number(l.tax_rate)} className="text-right" /></td>
                      </tr>); })}</tbody>
                  </table>
                </div>
              </FormDialog>
            )}
          </div>} />
        <Table>
          <thead><tr><Th>Item</Th><Th className="text-right">Ordered</Th><Th className="text-right">Price</Th><Th className="text-right">VAT</Th><Th className="text-right">Total</Th>
            <Th className="text-right">Received</Th><Th className="text-right">Rejected</Th><Th className="text-right">Billed</Th></tr></thead>
          <tbody>
            {d.lines.map((l) => (
              <tr key={l.id}>
                <Td>{l.name}<span className="block font-mono text-xs text-muted">{l.sku}</span></Td>
                <Td className="num text-right">{formatQty(l.qty_ordered)} {l.unit}</Td>
                <Td className="num text-right">{formatLKR(l.unit_price)}</Td>
                <Td className="num text-right">{Number(l.tax_rate) ? `${Number(l.tax_rate)}%` : "—"}</Td>
                <Td className="num text-right">{formatLKR(l.total)}</Td>
                <Td className={`num text-right ${Number(l.qty_received) >= Number(l.qty_ordered) ? "text-emerald-700" : ""}`}>{formatQty(l.qty_received)}</Td>
                <Td className={`num text-right ${Number(l.qty_rejected) > 0 ? "text-red-700" : "text-muted"}`}>{formatQty(l.qty_rejected)}</Td>
                <Td className="num text-right">{formatQty(l.qty_invoiced)}</Td>
              </tr>
            ))}
            <tr><Td colSpan={4} className="text-right font-medium">Before VAT {formatLKR(o.subtotal)} · VAT {formatLKR(o.tax_total)}</Td>
              <Td className="num text-right font-semibold">{formatLKR(o.total)}</Td><Td colSpan={3} /></tr>
          </tbody>
        </Table>
        {o.notes && <p className="px-5 py-3 text-sm text-muted">Notes: {o.notes}</p>}
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Supplier invoices" />
          {d.invoices.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No invoice recorded yet.</p> : (
            <div className="divide-y divide-line">
              {d.invoices.map((i) => { const s = statusBadge(SUPPLIER_INVOICE_STATUS, i.status); return (
                <div key={i.id} className="space-y-1 px-5 py-3 text-sm">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span><span className="font-medium">{i.supplier_invoice_no}</span> <span className="font-mono text-xs text-muted">{i.ref_no}</span></span>
                    <Badge tone={s.tone}>{s.label}</Badge>
                  </div>
                  <p className="text-muted">{formatDate(i.invoice_date)} · due {formatDate(i.due_date)} · {formatLKR(i.total)}{Number(i.amount_paid) > 0 && ` · paid ${formatLKR(i.amount_paid)}`}</p>
                  {i.match_notes.length > 0 && <p className="text-red-800">{i.match_notes.join("; ")}</p>}
                  {i.decision_note && <p className="text-muted">Decision: {i.decision_note}</p>}
                  {approve && i.status === "on_hold" && (
                    <div className="flex gap-2 pt-1">
                      <ReasonDialog trigger="Accept anyway" triggerVariant="primary" title={`Accept ${i.supplier_invoice_no}`} description="It is posted as owed to the supplier; the price difference goes to purchase price variance."
                        confirmLabel="Accept" action={decideInvoice} hidden={{ ...hidden, invoice_id: i.id, decision: "approve" }} />
                      <ReasonDialog trigger="Reject" triggerVariant="dangerOutline" title={`Reject ${i.supplier_invoice_no}`} description="Ask the supplier for a corrected invoice."
                        confirmLabel="Reject" confirmVariant="danger" action={decideInvoice} hidden={{ ...hidden, invoice_id: i.id, decision: "void" }} />
                    </div>
                  )}
                </div>); })}
            </div>
          )}
        </Card>
        <Card>
          <CardHeader title="Goods received" />
          {d.receipts.length === 0 ? <p className="px-5 py-4 text-sm text-muted">Nothing received yet.</p> : (
            <div className="divide-y divide-line">
              {d.receipts.map((g) => (
                <div key={g.id} className="px-5 py-3 text-sm">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-medium">{g.grn_no}</span>
                    {g.on_time === false ? <Badge tone="amber">Late</Badge> : <Badge tone="green">On time</Badge>}
                  </div>
                  <p className="text-muted">{formatDateTime(g.received_at)} · {g.received_by}{g.delivery_note_no && ` · DN ${g.delivery_note_no}`} · {formatLKR(g.value)}</p>
                  <ul className="mt-1">{g.lines.map((l, n) => (
                    <li key={n}>{formatQty(l.qty_received)} × {l.name}{Number(l.qty_rejected) > 0 && <span className="text-red-700"> · {formatQty(l.qty_rejected)} rejected ({l.reject_reason})</span>}
                      {l.supplier_lot && <span className="text-muted"> · lot {l.supplier_lot}</span>}{l.expiry_date && <span className="text-muted"> · exp {formatDate(l.expiry_date)}</span>}</li>))}</ul>
                </div>
              ))}
            </div>
          )}
        </Card>
      </div>
    </>
  );
}
