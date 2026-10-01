import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, MapPin, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR, formatPhone, humanize } from "@/lib/format";
import { CUSTOMER_TYPES, INVOICE_STATUS, ORDER_STATUS, PAYMENT_METHODS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, Td } from "@/components/ui/table";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { CustomerFields, type CustomerRow } from "../customer-fields";
import { updateCustomer, saveAddress, recordPayment, setOpeningBottles } from "../actions";

export const metadata: Metadata = { title: "Customer" };

type Summary = {
  outstanding: number; overdue: number; credit_available: number | null; ola_bottles: number;
  deposits: { type: string; qty: number; amount: number }[]; last_delivery: string | null; open_orders: number;
};

export default async function CustomerPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission("customers.view");
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data: c } = await supabase.from("customers").select("*").eq("id", id).maybeSingle();
  if (!c) notFound();

  const [{ data: summary }, { data: addresses }, { data: orders }, { data: invoices }, { data: payments }, { data: routes }, { data: lists }, { data: companies }, { data: types }, bottleTx] =
    await Promise.all([
      supabase.rpc("customer_summary", { p_customer: id }),
      supabase.from("customer_addresses").select("*").eq("customer_id", id).eq("is_active", true).order("is_default", { ascending: false }),
      supabase.from("orders").select("id, order_no, status, requested_date, total, hold_reason").eq("customer_id", id).order("created_at", { ascending: false }).limit(10),
      supabase.from("invoices").select("id, invoice_no, invoice_date, due_date, total, balance, status").eq("customer_id", id).order("created_at", { ascending: false }).limit(10),
      supabase.from("payments").select("id, payment_no, received_at, method, amount, reference, unallocated").eq("customer_id", id).order("received_at", { ascending: false }).limit(10),
      supabase.from("routes").select("id, name").eq("is_active", true).order("name"),
      supabase.from("price_lists").select("id, name").eq("is_active", true).order("name"),
      supabase.from("bottle_companies").select("id, name, is_own").eq("is_active", true).order("is_own", { ascending: false }),
      supabase.from("bottle_types").select("id, name").eq("is_active", true),
      can(access, "bottles.view")
        ? supabase.from("bottle_transactions").select("id, created_at, txn_type, qty, from_type, from_id, to_type, to_id, reason, company_id")
            .or(`and(from_type.eq.customer,from_id.eq.${id}),and(to_type.eq.customer,to_id.eq.${id})`).order("created_at", { ascending: false }).limit(15)
        : Promise.resolve({ data: null }),
    ]);
  const s = summary as Summary | null;
  const typeLabel = (Object.fromEntries(CUSTOMER_TYPES) as Record<string, string>)[c.customer_type];
  const companyName = Object.fromEntries((companies ?? []).map((x) => [x.id, x.name]));

  return (
    <>
      <Link href="/customers" className="mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-ola-700 hover:underline">
        <ArrowLeft className="h-4 w-4" /> All customers
      </Link>
      <PageHeader
        title={c.name}
        description={[c.customer_no, typeLabel, formatPhone(c.phone), c.company_name].filter(Boolean).join(" · ")}
        actions={
          <>
            {c.status !== "active" && <Badge tone={c.status === "on_hold" ? "red" : "neutral"} className="self-center">{humanize(c.status)}</Badge>}
            {can(access, "orders.manage") && (
              <Link href={`/orders/new?customer=${c.id}`} className={buttonVariants({ size: "md" })}>
                <Plus className="h-4 w-4" /> New order
              </Link>
            )}
            {can(access, "payments.manage") && (
              <FormDialog trigger="Record payment" triggerSize="md" title="Record payment" description="Applied to the oldest unpaid invoices first." submitLabel="Save payment" action={recordPayment} hidden={{ customer_id: c.id }}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field label="Amount (Rs.)" htmlFor="pay-amount" required>
                    <Input id="pay-amount" name="amount" type="number" min={0.01} step="0.01" required />
                  </Field>
                  <Field label="Method" htmlFor="pay-method">
                    <Select id="pay-method" name="method" defaultValue="cash">
                      {PAYMENT_METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </Select>
                  </Field>
                </div>
                <Field label="Reference" htmlFor="pay-ref" hint="Required for bank transfers and cheques">
                  <Input id="pay-ref" name="reference" />
                </Field>
                <Field label="Apply first to invoice" htmlFor="pay-inv">
                  <Select id="pay-inv" name="invoice_id" defaultValue="">
                    <option value="">Oldest unpaid first</option>
                    {invoices?.filter((i) => Number(i.balance) > 0).map((i) => (
                      <option key={i.id} value={i.id}>{i.invoice_no} — {formatLKR(i.balance)}</option>
                    ))}
                  </Select>
                </Field>
                <Field label="Notes" htmlFor="pay-notes"><Input id="pay-notes" name="notes" /></Field>
              </FormDialog>
            )}
          </>
        }
      />

      {s && (
        <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <Stat label="Balance" value={formatLKR(s.outstanding)} hint={Number(s.overdue) > 0 ? `${formatLKR(s.overdue)} overdue` : "Nothing overdue"} />
          <Stat label="Credit available" value={s.credit_available === null ? "Cash customer" : formatLKR(s.credit_available)} hint={`Limit ${formatLKR(c.credit_limit)} · ${c.payment_terms_days ? `${c.payment_terms_days} days` : "pay on delivery"}`} />
          <Stat label="OLA bottles held" value={s.ola_bottles} hint={c.bottle_model === "loan" ? `Limit ${c.allowed_bottles}` : c.bottle_model === "deposit" ? "Deposit model" : "No returnable bottles"} />
          <Stat label="Deposits held" value={formatLKR(s.deposits.reduce((a, d) => a + Number(d.amount), 0))} hint={s.last_delivery ? `Last delivery ${formatDate(s.last_delivery)}` : "No deliveries yet"} />
        </div>
      )}

      <div className="grid gap-6 xl:grid-cols-2">
        <div className="space-y-6">
          <Card>
            <CardHeader title="Recent orders" actions={<Link href={`/orders?customer=${c.id}`} className="text-sm font-medium text-ola-700 hover:underline">All orders</Link>} />
            <Table>
              <tbody>
                {(orders ?? []).length === 0 && <tr><Td className="text-muted">No orders yet.</Td></tr>}
                {orders?.map((o) => {
                  const b = statusBadge(ORDER_STATUS, o.status);
                  return (
                    <tr key={o.id}>
                      <Td><Link href={`/orders/${o.id}`} className="font-medium text-ola-700 hover:underline">{o.order_no}</Link>
                        {o.hold_reason && <span className="block text-xs text-red-700">{o.hold_reason}</span>}</Td>
                      <Td>{formatDate(o.requested_date)}</Td>
                      <Td><Badge tone={b.tone}>{b.label}</Badge></Td>
                      <Td className="num text-right">{formatLKR(o.total)}</Td>
                    </tr>
                  );
                })}
              </tbody>
            </Table>
          </Card>

          <Card>
            <CardHeader title="Invoices" />
            <Table>
              <tbody>
                {(invoices ?? []).length === 0 && <tr><Td className="text-muted">No invoices yet.</Td></tr>}
                {invoices?.map((i) => {
                  const b = statusBadge(INVOICE_STATUS, i.status);
                  return (
                    <tr key={i.id}>
                      <Td><a href={`/print/receipt/${i.id}`} target="_blank" rel="noopener" className="font-medium text-ola-700 hover:underline">{i.invoice_no}</a>
                        <span className="block text-xs text-muted">Due {formatDate(i.due_date)}</span></Td>
                      <Td>{formatDate(i.invoice_date)}</Td>
                      <Td><Badge tone={b.tone}>{b.label}</Badge></Td>
                      <Td className="num text-right">{formatLKR(i.total)}{Number(i.balance) > 0 && Number(i.balance) !== Number(i.total) && <span className="block text-xs text-red-700">{formatLKR(i.balance)} due</span>}</Td>
                    </tr>
                  );
                })}
              </tbody>
            </Table>
          </Card>

          <Card>
            <CardHeader title="Payments" />
            <Table>
              <tbody>
                {(payments ?? []).length === 0 && <tr><Td className="text-muted">No payments yet.</Td></tr>}
                {payments?.map((p) => (
                  <tr key={p.id}>
                    <Td className="font-medium">{p.payment_no}<span className="block text-xs text-muted">{p.reference}</span></Td>
                    <Td>{formatDateTime(p.received_at)}</Td>
                    <Td>{humanize(p.method)}</Td>
                    <Td className="num text-right">{formatLKR(p.amount)}{Number(p.unallocated) > 0 && <span className="block text-xs text-ola-700">{formatLKR(p.unallocated)} on account</span>}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </Card>
        </div>

        <div className="space-y-6">
          <Card>
            <CardHeader title="Addresses" actions={can(access, "customers.manage") && (
              <FormDialog trigger={<><Plus className="h-4 w-4" /> Add</>} title="Add address" submitLabel="Save address" action={saveAddress} hidden={{ customer_id: c.id }}>
                <AddressFields />
              </FormDialog>
            )} />
            <ul className="divide-y divide-line">
              {addresses?.map((a) => (
                <li key={a.id} className="flex items-start justify-between gap-3 px-5 py-3 text-sm">
                  <span className="flex gap-2">
                    <MapPin className="mt-0.5 h-4 w-4 shrink-0 text-muted" />
                    <span>
                      <span className="font-medium">{a.label}</span>{a.is_default && <Badge tone="blue" className="ml-2">Default</Badge>}
                      <span className="block">{a.address_line}{a.city && `, ${a.city}`}</span>
                      {a.delivery_instructions && <span className="block text-xs text-muted">{a.delivery_instructions}</span>}
                      {a.gps_lat && <a className="text-xs text-ola-700 hover:underline" target="_blank" rel="noopener" href={`https://www.google.com/maps?q=${a.gps_lat},${a.gps_lng}`}>Open map</a>}
                    </span>
                  </span>
                  {can(access, "customers.manage") && (
                    <FormDialog trigger="Edit" triggerVariant="ghost" title="Edit address" submitLabel="Save" action={saveAddress} hidden={{ customer_id: c.id, id: a.id }}>
                      <AddressFields a={a} />
                    </FormDialog>
                  )}
                </li>
              ))}
            </ul>
          </Card>

          {bottleTx.data && (
            <Card>
              <CardHeader title="Bottle movements" actions={can(access, "bottles.manage") && (
                <FormDialog trigger="Opening balance" title="Bottles held before go-live" description="Record bottles this customer already had before the ERP started." submitLabel="Record" action={setOpeningBottles} hidden={{ customer_id: c.id }}>
                  <Field label="Company" htmlFor="ob-co"><Select id="ob-co" name="company_id">{companies?.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
                  <Field label="Bottle" htmlFor="ob-type"><Select id="ob-type" name="bottle_type_id">{types?.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
                  <Field label="Number of bottles" htmlFor="ob-qty" required><Input id="ob-qty" name="qty" type="number" min={1} required /></Field>
                  <Field label="Reason" htmlFor="ob-r" required><Input id="ob-r" name="reason" defaultValue="Bottles held at go-live" required /></Field>
                </FormDialog>
              )} />
              <Table>
                <tbody>
                  {bottleTx.data.length === 0 && <tr><Td className="text-muted">No bottle movements yet.</Td></tr>}
                  {bottleTx.data.map((t) => {
                    const toCustomer = t.to_type === "customer" && t.to_id === c.id;
                    return (
                      <tr key={t.id}>
                        <Td className="whitespace-nowrap">{formatDateTime(t.created_at)}</Td>
                        <Td>{humanize(t.txn_type)}<span className="block text-xs text-muted">{companyName[t.company_id]}{t.reason && ` · ${t.reason}`}</span></Td>
                        <Td className={`num text-right font-medium ${toCustomer ? "text-ola-700" : "text-emerald-700"}`}>{toCustomer ? `+${t.qty}` : `−${t.qty}`}</Td>
                      </tr>
                    );
                  })}
                </tbody>
              </Table>
            </Card>
          )}

          {can(access, "customers.manage") && (
            <Card>
              <details>
                <summary className="cursor-pointer px-5 py-4 text-base font-semibold text-navy-900">Edit customer details</summary>
                <CardBody className="border-t border-line">
                  <ActionForm action={updateCustomer}>
                    <input type="hidden" name="id" value={c.id} />
                    <CustomerFields c={c as CustomerRow} routes={routes ?? []} priceLists={lists ?? []} canCredit={can(access, "customers.credit")} />
                    <Field label="Reason for change" htmlFor="reason"><Input id="reason" name="reason" /></Field>
                    <SubmitButton>Save changes</SubmitButton>
                  </ActionForm>
                </CardBody>
              </details>
            </Card>
          )}
        </div>
      </div>
    </>
  );
}

function AddressFields({ a }: { a?: { label: string; address_line: string; city: string | null; district: string | null; gps_lat: number | null; gps_lng: number | null; delivery_instructions: string | null; is_default: boolean } }) {
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Label" htmlFor="a-label"><Input id="a-label" name="label" defaultValue={a?.label ?? "Main"} /></Field>
        <Field label="City" htmlFor="a-city"><Input id="a-city" name="city" defaultValue={a?.city ?? ""} /></Field>
      </div>
      <Field label="Address" htmlFor="a-line" required><Input id="a-line" name="address_line" defaultValue={a?.address_line} required /></Field>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="District" htmlFor="a-d"><Input id="a-d" name="district" defaultValue={a?.district ?? ""} /></Field>
        <Field label="GPS lat" htmlFor="a-lat"><Input id="a-lat" name="gps_lat" inputMode="decimal" defaultValue={a?.gps_lat ?? ""} /></Field>
        <Field label="GPS lng" htmlFor="a-lng"><Input id="a-lng" name="gps_lng" inputMode="decimal" defaultValue={a?.gps_lng ?? ""} /></Field>
      </div>
      <Field label="Delivery instructions" htmlFor="a-ins"><Input id="a-ins" name="delivery_instructions" defaultValue={a?.delivery_instructions ?? ""} /></Field>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_default" defaultChecked={a?.is_default} /> Default delivery address</label>
    </>
  );
}
