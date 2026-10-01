"use client";

import { useState } from "react";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { LineEditor } from "@/components/ui/line-editor";

type Opt = { id: string; name: string };
export type SupplierOpt = Opt & { prices: Record<string, number>; vat: boolean };
export type RequestOpt = { id: string; request_no: string; location_id: string; items: { product_id: string; qty: number; est_unit_price: number | null }[] };

/** Fields of a new purchase order; lines can be filled from an approved request and the supplier's prices. */
export function OrderFields({ suppliers, locations, requests, items, initialRequest }: {
  suppliers: SupplierOpt[]; locations: Opt[]; requests: RequestOpt[]; items: (Opt & { unit: string })[]; initialRequest?: string;
}) {
  const [sup, setSup] = useState(suppliers[0]?.id ?? "");
  const [req, setReq] = useState(initialRequest ?? "");
  const r = requests.find((x) => x.id === req);
  const [loc, setLoc] = useState(r?.location_id ?? locations[0]?.id ?? "");
  const s = suppliers.find((x) => x.id === sup);
  const opts = items.map((i) => ({ id: i.id, name: i.name, unit: i.unit,
    hint: s?.prices[i.id] !== undefined ? `${s.name}: Rs. ${s.prices[i.id]}` : null,
    defaults: s?.prices[i.id] !== undefined ? { unit_price: String(s.prices[i.id]) } : undefined }));
  const initial = (r?.items ?? []).map((x) => ({ item_id: x.product_id, qty: String(x.qty),
    unit_price: s?.prices[x.product_id] !== undefined ? String(s.prices[x.product_id]) : x.est_unit_price !== null ? String(x.est_unit_price) : "", tax_rate: "" }));

  return (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Supplier" htmlFor="po-s" required><Select id="po-s" name="supplier_id" value={sup} onChange={(e) => setSup(e.target.value)} required>
          {suppliers.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="From purchase request" htmlFor="po-r"><Select id="po-r" name="request_id" value={req}
          onChange={(e) => { setReq(e.target.value); const n = requests.find((x) => x.id === e.target.value); if (n) setLoc(n.location_id); }}>
          <option value="">None</option>{requests.map((x) => <option key={x.id} value={x.id}>{x.request_no}</option>)}</Select></Field>
        <Field label="Deliver to" htmlFor="po-l"><Select id="po-l" name="location_id" value={loc} onChange={(e) => setLoc(e.target.value)}>
          {locations.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label="Expected delivery" htmlFor="po-e" hint="Used to measure on-time delivery"><Input id="po-e" name="expected_date" type="date" /></Field>
      </div>
      <LineEditor key={`${sup}-${req}`} name="lines" items={opts} initial={initial} addLabel="Add item"
        columns={[{ key: "qty", label: "Qty", type: "number", step: "any", min: 0 }, { key: "unit_price", label: "Price (Rs., before VAT)", type: "number", step: "0.0001", min: 0 },
          { key: "tax_rate", label: "VAT %", type: "number", step: "any", min: 0, placeholder: s?.vat ? "auto" : "0", className: "w-24" }]} />
      <p className="text-xs text-muted">{s?.vat ? "VAT is added automatically for items with a VAT code (leave VAT % empty)." : "This supplier is not VAT registered — no VAT unless you enter a rate."}</p>
      <Field label="Notes for the supplier" htmlFor="po-n"><Textarea id="po-n" name="notes" /></Field>
    </>
  );
}
