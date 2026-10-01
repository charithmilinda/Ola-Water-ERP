import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Pencil } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR } from "@/lib/format";
import { DELIVERY_STATUS, ORDER_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, Td, Th } from "@/components/ui/table";
import { Alert } from "@/components/ui/alert";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { buttonVariants } from "@/components/ui/button";
import { confirmOrder, releaseHold, cancelOrder } from "../actions";

export const metadata: Metadata = { title: "Order" };

export default async function OrderPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission("orders.view");
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data: o } = await supabase.from("orders").select("*, customer:customers(id, name, customer_no, phone), address:customer_addresses(label, address_line, city)").eq("id", id).maybeSingle();
  if (!o) notFound();
  const [{ data: items }, { data: deliveries }, { data: invoices }] = await Promise.all([
    supabase.from("order_items").select("*, product:products(name, sku)").eq("order_id", id).order("line_no"),
    supabase.from("deliveries").select("id, delivery_no, status, failure_reason, completed_at, run:route_runs(id, run_no, run_date)").eq("order_id", id).order("created_at"),
    supabase.from("invoices").select("id, invoice_no, total, status").eq("order_id", id),
  ]);
  const b = statusBadge(ORDER_STATUS, o.status);
  const editable = ["draft", "on_hold", "confirmed"].includes(o.status);
  const manage = can(access, "orders.manage");

  return (
    <>
      <Link href="/orders" className="mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> All orders</Link>
      <PageHeader
        title={o.order_no}
        description={`${o.customer?.name} · deliver ${formatDate(o.requested_date)}${o.time_window ? ` (${o.time_window})` : ""}`}
        actions={
          <>
            <Badge tone={b.tone} className="self-center">{b.label}</Badge>
            {manage && editable && <Link href={`/orders/${o.id}/edit`} className={buttonVariants({ variant: "secondary", size: "md" })}><Pencil className="h-4 w-4" /> Edit</Link>}
            {manage && o.status === "draft" && (
              <ActionForm action={confirmOrder} className="space-y-0"><input type="hidden" name="order_id" value={o.id} /><SubmitButton>Confirm order</SubmitButton></ActionForm>
            )}
            {o.status === "on_hold" && can(access, "customers.credit") && (
              <ReasonDialog trigger="Approve & release" triggerVariant="primary" triggerSize="md" title="Release hold" description={o.hold_reason ?? undefined}
                confirmLabel="Approve" action={releaseHold} hidden={{ order_id: o.id }} />
            )}
            {manage && ["draft", "on_hold", "confirmed", "assigned"].includes(o.status) && (
              <ReasonDialog trigger="Cancel order" triggerVariant="dangerOutline" triggerSize="md" title="Cancel order" confirmLabel="Cancel order" confirmVariant="danger"
                action={cancelOrder} hidden={{ order_id: o.id }} />
            )}
          </>
        }
      />
      {o.hold_reason && o.status === "on_hold" && <Alert tone="warning" className="mb-6"><strong>On hold:</strong> {o.hold_reason}</Alert>}
      {o.cancel_reason && <Alert tone="info" className="mb-6">Cancelled: {o.cancel_reason}</Alert>}

      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title="Items" />
          <Table>
            <thead><tr><Th>Product</Th><Th className="text-right">Qty</Th><Th className="text-right">Delivered</Th><Th className="text-right">Price</Th><Th className="text-right">Discount</Th><Th className="text-right">Total</Th></tr></thead>
            <tbody>
              {items?.map((i) => (
                <tr key={i.id}>
                  <Td>{i.product?.name}</Td>
                  <Td className="num text-right">{Number(i.qty)}</Td>
                  <Td className="num text-right">{Number(i.delivered_qty)}</Td>
                  <Td className="num text-right">{formatLKR(i.unit_price)}</Td>
                  <Td className="num text-right">{Number(i.discount) ? formatLKR(i.discount) : "—"}</Td>
                  <Td className="num text-right">{formatLKR(i.line_total)}</Td>
                </tr>
              ))}
              {Number(o.delivery_charge) > 0 && <tr><Td colSpan={5}>Delivery charge</Td><Td className="num text-right">{formatLKR(o.delivery_charge)}</Td></tr>}
              <tr><Td colSpan={5} className="text-right text-muted">VAT included</Td><Td className="num text-right text-muted">{formatLKR(o.tax_total)}</Td></tr>
              <tr><Td colSpan={5} className="text-right font-semibold">Total</Td><Td className="num text-right font-semibold">{formatLKR(o.total)}</Td></tr>
            </tbody>
          </Table>
        </Card>
        <div className="space-y-6">
          <Card>
            <CardHeader title="Details" />
            <CardBody>
              <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
                <dt className="text-muted">Customer</dt><dd><Link href={`/customers/${o.customer?.id}`} className="text-ola-700 hover:underline">{o.customer?.name}</Link></dd>
                <dt className="text-muted">Address</dt><dd>{o.address ? `${o.address.address_line}${o.address.city ? `, ${o.address.city}` : ""}` : "—"}</dd>
                <dt className="text-muted">Empties to collect</dt><dd className="num">{o.expected_ola_returns}</dd>
                <dt className="text-muted">Source</dt><dd className="capitalize">{o.source.replace("_", " ")}</dd>
                <dt className="text-muted">Created</dt><dd>{formatDateTime(o.created_at)}</dd>
                {o.confirmed_at && <><dt className="text-muted">Confirmed</dt><dd>{formatDateTime(o.confirmed_at)}</dd></>}
                {o.notes && <><dt className="text-muted">Notes</dt><dd>{o.notes}</dd></>}
              </dl>
            </CardBody>
          </Card>
          <Card>
            <CardHeader title="Deliveries & invoices" />
            <CardBody className="space-y-2 text-sm">
              {(deliveries ?? []).length === 0 && <p className="text-muted">Not dispatched yet.</p>}
              {deliveries?.map((d) => {
                const db = statusBadge(DELIVERY_STATUS, d.status);
                const run = d.run as unknown as { id: string; run_no: string; run_date: string } | null;
                return (
                  <div key={d.id} className="flex flex-wrap items-center justify-between gap-2">
                    <span>{d.delivery_no} · <Link href={`/dispatch/${run?.id}`} className="text-ola-700 hover:underline">{run?.run_no}</Link>{d.failure_reason && <span className="block text-xs text-red-700">{d.failure_reason}</span>}</span>
                    <Badge tone={db.tone}>{db.label}</Badge>
                  </div>
                );
              })}
              {invoices?.map((i) => (
                <div key={i.id} className="flex justify-between"><a href={`/print/receipt/${i.id}`} target="_blank" rel="noopener" className="text-ola-700 hover:underline">{i.invoice_no}</a><span className="num">{formatLKR(i.total)}</span></div>
              ))}
            </CardBody>
          </Card>
        </div>
      </div>
    </>
  );
}
