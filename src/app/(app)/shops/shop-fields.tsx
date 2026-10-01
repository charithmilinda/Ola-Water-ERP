"use client";

import { useState } from "react";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { formatPhone } from "@/lib/format";

export type ShopRow = {
  id: string; code: string; name: string; operating_model: string; owner_name: string | null; contact_person: string | null;
  phone: string | null; email: string | null; address: string | null; city: string | null; district: string | null; territory: string | null;
  gps_lat: number | null; gps_lng: number | null; retail_price_list_id: string; transfer_price_list_id: string | null;
  commission_percent: number; status: string; notes: string | null;
};

export function ShopFields({ s, priceLists, canCredit }: { s?: ShopRow; priceLists: { id: string; name: string; code: string }[]; canCredit: boolean }) {
  const [model, setModel] = useState(s?.operating_model ?? "company_owned");
  const def = (code: string) => priceLists.find((p) => p.code === code)?.id ?? "";
  const k = s?.id ?? "new";
  return (
    <div className="space-y-4">
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Shop code" htmlFor={`sc-${k}`} required hint="e.g. SHOP01 — used on receipts">
          <Input id={`sc-${k}`} name="code" defaultValue={s?.code} required disabled={!!s} className="uppercase" />
        </Field>
        <Field label="Shop name" htmlFor={`sn-${k}`} required className="sm:col-span-2">
          <Input id={`sn-${k}`} name="name" defaultValue={s?.name} required />
        </Field>
      </div>
      {!s ? (
        <fieldset>
          <legend className="mb-2 text-sm font-medium text-navy-800">Who owns the shop?</legend>
          <div className="grid gap-2 sm:grid-cols-2">
            {[["company_owned", "OLA-owned", "OLA's stock and staff. Takings are banked by OLA."],
              ["dealer", "Dealer-owned", "The dealer buys water from OLA at transfer prices and keeps the takings."]].map(([v, l, h]) => (
              <label key={v} className={`cursor-pointer rounded-lg border p-3 text-sm ${model === v ? "border-ola-600 bg-ola-50" : "border-line"}`}>
                <input type="radio" name="operating_model" value={v} checked={model === v} onChange={() => setModel(v)} className="mr-2" />
                <span className="font-medium">{l}</span>
                <span className="mt-1 block text-xs text-muted">{h}</span>
              </label>
            ))}
          </div>
        </fieldset>
      ) : (
        <input type="hidden" name="operating_model" value={s.operating_model} />
      )}
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label={model === "dealer" ? "Dealer / owner" : "Manager"} htmlFor={`so-${k}`}>
          <Input id={`so-${k}`} name="owner_name" defaultValue={s?.owner_name ?? ""} />
        </Field>
        <Field label="Phone" htmlFor={`sp-${k}`} required={model === "dealer"} hint="e.g. 011 281 2345">
          <Input id={`sp-${k}`} name="phone" type="tel" defaultValue={s?.phone ? formatPhone(s.phone) : ""} required={model === "dealer"} />
        </Field>
        <Field label="Email" htmlFor={`se-${k}`}><Input id={`se-${k}`} name="email" type="email" defaultValue={s?.email ?? ""} /></Field>
      </div>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Address" htmlFor={`sa-${k}`} className="sm:col-span-2"><Input id={`sa-${k}`} name="address" defaultValue={s?.address ?? ""} /></Field>
        <Field label="City" htmlFor={`sci-${k}`}><Input id={`sci-${k}`} name="city" defaultValue={s?.city ?? ""} /></Field>
        <Field label="District" htmlFor={`sd-${k}`}><Input id={`sd-${k}`} name="district" defaultValue={s?.district ?? ""} /></Field>
        <Field label="Territory" htmlFor={`st-${k}`}><Input id={`st-${k}`} name="territory" defaultValue={s?.territory ?? ""} /></Field>
        <div className="grid grid-cols-2 gap-2">
          <Field label="GPS lat" htmlFor={`sla-${k}`}><Input id={`sla-${k}`} name="gps_lat" inputMode="decimal" defaultValue={s?.gps_lat ?? ""} /></Field>
          <Field label="GPS lng" htmlFor={`sln-${k}`}><Input id={`sln-${k}`} name="gps_lng" inputMode="decimal" defaultValue={s?.gps_lng ?? ""} /></Field>
        </div>
      </div>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Shop selling prices" htmlFor={`srp-${k}`} hint="Price list used at the till">
          <Select id={`srp-${k}`} name="retail_price_list_id" defaultValue={s?.retail_price_list_id ?? def("RETAIL")}>
            {priceLists.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </Select>
        </Field>
        {model === "dealer" ? (
          <>
            <Field label="Transfer prices (dealer pays OLA)" htmlFor={`stp-${k}`}>
              <Select id={`stp-${k}`} name="transfer_price_list_id" defaultValue={s?.transfer_price_list_id ?? def("SHOP_TRANSFER")}>
                {priceLists.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              </Select>
            </Field>
            {!s && (
              <div className="grid grid-cols-2 gap-2">
                <Field label="Credit limit (Rs.)" htmlFor={`scl-${k}`} hint={canCredit ? undefined : "Finance only"}>
                  <Input id={`scl-${k}`} name="credit_limit" type="number" min={0} defaultValue={0} readOnly={!canCredit} />
                </Field>
                <Field label="Terms (days)" htmlFor={`spt-${k}`}><Input id={`spt-${k}`} name="payment_terms_days" type="number" min={0} defaultValue={7} /></Field>
              </div>
            )}
          </>
        ) : (
          <Field label="Commission on net sales (%)" htmlFor={`scm-${k}`} hint="0 if none — accrued at each settlement">
            <Input id={`scm-${k}`} name="commission_percent" type="number" min={0} max={100} step="0.01" defaultValue={s?.commission_percent ?? 0} />
          </Field>
        )}
      </div>
      {s && (
        <Field label="Status" htmlFor={`sst-${k}`}>
          <Select id={`sst-${k}`} name="status" defaultValue={s.status}>
            <option value="active">Active</option><option value="suspended">Suspended (till cannot open)</option><option value="closed">Closed</option>
          </Select>
        </Field>
      )}
      <Field label="Notes" htmlFor={`snt-${k}`}><Textarea id={`snt-${k}`} name="notes" defaultValue={s?.notes ?? ""} /></Field>
    </div>
  );
}
