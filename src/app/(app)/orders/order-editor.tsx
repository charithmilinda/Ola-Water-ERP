"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { Search, Trash2, Plus } from "lucide-react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { SubmitButton } from "@/components/ui/submit-button";
import { Alert } from "@/components/ui/alert";
import { Table, Td, Th } from "@/components/ui/table";
import { formatLKR } from "@/lib/format";
import { customerPricing, saveOrder, searchCustomers, type CustomerHit, type Pricing } from "./actions";

type Line = { product_id: string; qty: string; discount: string };

export type OrderInitial = {
  id?: string;
  customer_id?: string;
  address_id?: string;
  requested_date: string;
  time_window?: string;
  notes?: string;
  delivery_charge?: string;
  expected_ola_returns?: string;
  items?: Line[];
};

export function OrderEditor({ initial, today }: { initial: OrderInitial; today: string }) {
  const [customerId, setCustomerId] = useState(initial.customer_id ?? "");
  const [pricing, setPricing] = useState<Pricing | null>(null);
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<CustomerHit[]>([]);
  const [searching, startSearch] = useTransition();
  const [addressId, setAddressId] = useState(initial.address_id ?? "");
  const [date, setDate] = useState(initial.requested_date);
  const [timeWindow, setTimeWindow] = useState(initial.time_window ?? "");
  const [notes, setNotes] = useState(initial.notes ?? "");
  const [charge, setCharge] = useState(initial.delivery_charge ?? "0");
  const [returns, setReturns] = useState(initial.expected_ola_returns ?? "");
  const [lines, setLines] = useState<Line[]>(initial.items ?? []);
  const [confirm, setConfirm] = useState(true);

  useEffect(() => {
    if (!customerId) return;
    customerPricing(customerId).then((p) => {
      setPricing(p);
      if (!p) return;
      if (!initial.address_id || initial.customer_id !== customerId) setAddressId(p.addresses.find((a) => a.is_default)?.id ?? p.addresses[0]?.id ?? "");
      if (lines.length === 0) {
        const main = p.products.find((x) => x.is_returnable) ?? p.products[0];
        if (main) setLines([{ product_id: main.id, qty: "1", discount: "" }]);
      }
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [customerId]);

  useEffect(() => {
    if (query.trim().length < 2) {
      setHits([]);
      return;
    }
    const t = setTimeout(() => startSearch(async () => setHits(await searchCustomers(query.trim()))), 250);
    return () => clearTimeout(t);
  }, [query]);

  const priced = lines.map((l) => {
    const p = pricing?.products.find((x) => x.id === l.product_id);
    const total = p?.price != null ? Number(l.qty || 0) * p.price - Number(l.discount || 0) : null;
    return { ...l, product: p, total };
  });
  const sum = priced.reduce((a, l) => a + (l.total ?? 0), 0) + Number(charge || 0);
  const returnableQty = priced.filter((l) => l.product?.is_returnable).reduce((a, l) => a + Number(l.qty || 0), 0);
  const missingPrice = priced.some((l) => l.product && l.product.price === null);

  const json = useMemo(
    () =>
      JSON.stringify({
        id: initial.id, customer_id: customerId, address_id: addressId, requested_date: date, time_window: timeWindow,
        source: "phone", notes, delivery_charge: charge, expected_ola_returns: returns === "" ? String(returnableQty) : returns,
        items: lines, confirm,
      }),
    [initial.id, customerId, addressId, date, timeWindow, notes, charge, returns, returnableQty, lines, confirm],
  );

  return (
    <ActionForm action={saveOrder}>
      <input type="hidden" name="payload" value={json} />

      {!initial.id && (
        <div>
          {pricing ? (
            <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-line bg-surface px-4 py-3">
              <div>
                <p className="font-medium text-navy-900">{pricing.customer.name} <span className="text-sm text-muted">{pricing.customer.customer_no}</span></p>
                <p className="text-sm text-muted">
                  Holds {pricing.ola_bottles} OLA bottle(s){pricing.customer.bottle_model === "loan" && ` (limit ${pricing.customer.allowed_bottles})`} · Balance {formatLKR(pricing.outstanding)}
                </p>
              </div>
              <Button type="button" variant="secondary" size="sm" onClick={() => { setCustomerId(""); setPricing(null); setLines([]); }}>Change customer</Button>
            </div>
          ) : (
            <Field label="Customer" htmlFor="cust-search" required>
              <div className="relative">
                <Search className="pointer-events-none absolute left-3 top-3 h-4 w-4 text-muted" />
                <Input id="cust-search" value={query} onChange={(e) => setQuery(e.target.value)} className="pl-9" placeholder="Type a name, customer no. or phone" autoComplete="off" />
              </div>
              {searching && <p className="mt-1 text-xs text-muted">Searching…</p>}
              {hits.length > 0 && (
                <ul className="mt-1 max-h-64 overflow-auto rounded-lg border border-line bg-white shadow-sm">
                  {hits.map((h) => (
                    <li key={h.id}>
                      <button type="button" className="w-full px-3 py-2 text-left text-sm hover:bg-ola-50" onClick={() => { setCustomerId(h.id); setHits([]); setQuery(""); }}>
                        <span className="font-medium">{h.name}</span> <span className="text-muted">{h.customer_no}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </Field>
          )}
        </div>
      )}

      {pricing && (
        <>
          {pricing.customer.status === "on_hold" && <Alert tone="warning">This customer is on hold — the order will need approval.</Alert>}
          {pricing.promotions?.length > 0 && (
            <Alert tone="info">Promotions for this customer (applied automatically when the order is saved):{" "}
              {pricing.promotions.map((pr) => `${pr.name}${pr.product_id ? ` on ${pricing.products.find((x) => x.id === pr.product_id)?.name ?? "a product"}` : ""}${Number(pr.min_qty) > 0 ? ` (from ${Number(pr.min_qty)})` : ""}`).join("; ")}.</Alert>
          )}
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Field label="Deliver on" htmlFor="o-date" required>
              <Input id="o-date" type="date" min={today} value={date} onChange={(e) => setDate(e.target.value)} required />
            </Field>
            <Field label="Time window" htmlFor="o-tw">
              <Input id="o-tw" value={timeWindow} onChange={(e) => setTimeWindow(e.target.value)} placeholder="e.g. Before 10 AM" />
            </Field>
            <Field label="Address" htmlFor="o-addr" className="lg:col-span-2">
              <Select id="o-addr" value={addressId} onChange={(e) => setAddressId(e.target.value)}>
                {pricing.addresses.map((a) => <option key={a.id} value={a.id}>{a.label}: {a.address_line}</option>)}
              </Select>
            </Field>
          </div>

          <Table>
            <thead>
              <tr>
                <Th>Product</Th>
                <Th className="w-28">Qty</Th>
                <Th className="text-right">Price</Th>
                <Th className="w-32">Discount (Rs.)</Th>
                <Th className="text-right">Line total</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {priced.map((l, i) => (
                <tr key={i}>
                  <Td>
                    <Select value={l.product_id} onChange={(e) => setLines((ls) => ls.map((x, j) => (j === i ? { ...x, product_id: e.target.value } : x)))} aria-label="Product">
                      {pricing.products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                    </Select>
                  </Td>
                  <Td>
                    <Input type="number" min={1} step={1} value={l.qty} onChange={(e) => setLines((ls) => ls.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} aria-label="Quantity" />
                  </Td>
                  <Td className="num text-right">{l.product?.price != null ? formatLKR(l.product.price) : <span className="text-red-700">No price</span>}</Td>
                  <Td>
                    <Input type="number" min={0} step="0.01" value={l.discount} onChange={(e) => setLines((ls) => ls.map((x, j) => (j === i ? { ...x, discount: e.target.value } : x)))} aria-label="Discount" />
                  </Td>
                  <Td className="num text-right">{l.total != null ? formatLKR(l.total) : "—"}</Td>
                  <Td>
                    <Button type="button" variant="ghost" size="icon" aria-label="Remove line" onClick={() => setLines((ls) => ls.filter((_, j) => j !== i))}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
          <Button type="button" variant="secondary" size="sm" onClick={() => setLines((ls) => [...ls, { product_id: pricing.products[0]?.id ?? "", qty: "1", discount: "" }])}>
            <Plus className="h-4 w-4" /> Add product
          </Button>
          {missingPrice && <Alert tone="error">Some products have no price in this customer&apos;s price list. Set prices in Products & Prices first.</Alert>}

          <div className="grid gap-4 sm:grid-cols-3">
            <Field label="Empty OLA bottles to collect" htmlFor="o-ret" hint={`Blank = same as bottles delivered (${returnableQty})`}>
              <Input id="o-ret" type="number" min={0} value={returns} onChange={(e) => setReturns(e.target.value)} />
            </Field>
            <Field label="Delivery charge (Rs.)" htmlFor="o-ch">
              <Input id="o-ch" type="number" min={0} step="0.01" value={charge} onChange={(e) => setCharge(e.target.value)} />
            </Field>
            <div className="flex flex-col justify-end rounded-lg bg-surface px-4 py-3">
              <span className="text-sm text-muted">Estimated total {pricing.includes_tax ? "(incl. VAT)" : "(+ VAT)"}</span>
              <span className="num text-xl font-semibold">{formatLKR(sum)}</span>
              <span className="text-xs text-muted">Deposits are added on delivery if needed</span>
            </div>
          </div>
          <Field label="Notes for the driver" htmlFor="o-notes">
            <Textarea id="o-notes" value={notes} onChange={(e) => setNotes(e.target.value)} />
          </Field>
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={confirm} onChange={(e) => setConfirm(e.target.checked)} /> Confirm now (checks credit and bottle limits)
          </label>
          <SubmitButton size="lg" disabled={missingPrice || lines.length === 0}>{initial.id ? "Save order" : confirm ? "Create & confirm order" : "Save as draft"}</SubmitButton>
        </>
      )}
    </ActionForm>
  );
}
