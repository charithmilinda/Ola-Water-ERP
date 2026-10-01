"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { Table, Td, Th } from "@/components/ui/table";
import { formatLKR } from "@/lib/format";
import { setPrices } from "./actions";

type Product = { id: string; name: string; sku: string };
type PriceList = { id: string; name: string; prices_include_tax: boolean };

export function PriceEditor({
  products,
  priceLists,
  current,
  today,
}: {
  products: Product[];
  priceLists: PriceList[];
  current: Record<string, Record<string, number>>;
  today: string;
}) {
  const [listId, setListId] = useState(priceLists[0]?.id ?? "");
  const [values, setValues] = useState<Record<string, string>>({});
  const [effective, setEffective] = useState(today);
  const [reason, setReason] = useState("");
  const list = priceLists.find((l) => l.id === listId);

  const json = useMemo(
    () =>
      JSON.stringify({
        price_list_id: listId,
        effective_from: effective,
        reason,
        prices: products.map((p) => ({ product_id: p.id, unit_price: values[p.id] ?? "" })),
      }),
    [listId, effective, reason, products, values],
  );

  return (
    <ActionForm action={setPrices} onSuccess={() => setValues({})}>
      <input type="hidden" name="payload" value={json} />
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Price list" htmlFor="pl">
          <Select id="pl" value={listId} onChange={(e) => { setListId(e.target.value); setValues({}); }}>
            {priceLists.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="New prices apply from" htmlFor="eff" required>
          <Input id="eff" type="date" min={today} value={effective} onChange={(e) => setEffective(e.target.value)} />
        </Field>
        <Field label="Reason" htmlFor="pr-reason" required>
          <Input id="pr-reason" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Price revision Nov 2026" />
        </Field>
      </div>
      <p className="text-xs text-muted">
        Prices in this list {list?.prices_include_tax ? "include VAT (VAT is worked out backwards on invoices)" : "exclude VAT (VAT is added on invoices)"}.
        Leave a box empty to keep the current price. Old prices are kept in history.
      </p>
      <Table>
        <thead>
          <tr>
            <Th>Product</Th>
            <Th className="text-right">Current price</Th>
            <Th className="w-48">New price (Rs.)</Th>
          </tr>
        </thead>
        <tbody>
          {products.map((p) => (
            <tr key={p.id}>
              <Td>
                {p.name} <span className="font-mono text-xs text-muted">{p.sku}</span>
              </Td>
              <Td className="num text-right">{current[listId]?.[p.id] !== undefined ? formatLKR(current[listId][p.id]) : <span className="text-muted">No price</span>}</Td>
              <Td>
                <Input
                  type="number"
                  inputMode="decimal"
                  min={0}
                  step="0.01"
                  value={values[p.id] ?? ""}
                  onChange={(e) => setValues((v) => ({ ...v, [p.id]: e.target.value }))}
                  aria-label={`New price for ${p.name}`}
                />
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      <SubmitButton>Save prices</SubmitButton>
    </ActionForm>
  );
}
