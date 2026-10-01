"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { receiveStock, transferStock } from "./actions";

type Opt = { id: string; name: string };
type Item = Opt & { unit?: string; finished?: boolean };

export function ReceiveForm({ locations, products }: { locations: Opt[]; products: Item[] }) {
  const [location, setLocation] = useState(locations[0]?.id ?? "");
  const [source, setSource] = useState("opening");
  const [reason, setReason] = useState("");
  const [qty, setQty] = useState<Record<string, string>>({});
  const [cost, setCost] = useState<Record<string, string>>({});
  const shown = source === "opening" ? products : products.filter((p) => p.finished);
  const json = useMemo(() => JSON.stringify({ location, source, reason,
    lines: Object.entries(qty).map(([product_id, q]) => ({ product_id, qty: q, unit_cost: cost[product_id] || null })) }), [location, source, reason, qty, cost]);
  return (
    <ActionForm action={receiveStock} onSuccess={() => { setQty({}); setCost({}); setReason(""); }}>
      <input type="hidden" name="payload" value={json} />
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Into" htmlFor="rc-loc"><Select id="rc-loc" value={location} onChange={(e) => setLocation(e.target.value)}>{locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
        <Field label="Type" htmlFor="rc-src" hint={source === "opening" ? "Stock already here before go-live. Enter the cost per unit if you know it." : "Only for managers who can release QC batches — normal production goes through Production."}>
          <Select id="rc-src" value={source} onChange={(e) => setSource(e.target.value)}>
            <option value="opening">Opening stock at go-live</option>
            <option value="receipt">Water filled without a batch (exception)</option>
          </Select>
        </Field>
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        {shown.map((p) => (
          <div key={p.id} className="flex items-end gap-2">
            <Field label={`${p.name}${p.unit ? ` (${p.unit})` : ""}`} htmlFor={`rq-${p.id}`} className="flex-1">
              <Input id={`rq-${p.id}`} type="number" min={0} step={p.finished ? 1 : "any"} value={qty[p.id] ?? ""} onChange={(e) => setQty((v) => ({ ...v, [p.id]: e.target.value }))} placeholder="0" />
            </Field>
            {source === "opening" && (
              <Field label="Cost / unit" htmlFor={`rc-${p.id}`} className="w-28">
                <Input id={`rc-${p.id}`} type="number" min={0} step="any" value={cost[p.id] ?? ""} onChange={(e) => setCost((v) => ({ ...v, [p.id]: e.target.value }))} placeholder="avg" />
              </Field>
            )}
          </div>
        ))}
      </div>
      <Field label="Reason / reference" htmlFor="rc-reason" required><Input id="rc-reason" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Go-live count 1 November" required /></Field>
      <SubmitButton>Receive stock</SubmitButton>
    </ActionForm>
  );
}

export function TransferForm({ locations, products }: { locations: Opt[]; products: Item[] }) {
  const [from, setFrom] = useState(locations[0]?.id ?? "");
  const [to, setTo] = useState(locations[1]?.id ?? "");
  const [reason, setReason] = useState("");
  const [qty, setQty] = useState<Record<string, string>>({});
  const json = useMemo(() => JSON.stringify({ from, to, reason, lines: Object.entries(qty).map(([product_id, q]) => ({ product_id, qty: q })) }), [from, to, reason, qty]);
  return (
    <ActionForm action={transferStock} onSuccess={() => setQty({})}>
      <input type="hidden" name="payload" value={json} />
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="From" htmlFor="tr-from"><Select id="tr-from" value={from} onChange={(e) => setFrom(e.target.value)}>{locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
        <Field label="To" htmlFor="tr-to"><Select id="tr-to" value={to} onChange={(e) => setTo(e.target.value)}>{locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        {products.map((p) => (
          <Field key={p.id} label={`${p.name}${p.unit && !p.finished ? ` (${p.unit})` : ""}`} htmlFor={`tq-${p.id}`}>
            <Input id={`tq-${p.id}`} type="number" min={0} step={p.finished ? 1 : "any"} value={qty[p.id] ?? ""} onChange={(e) => setQty((v) => ({ ...v, [p.id]: e.target.value }))} placeholder="0" />
          </Field>
        ))}
      </div>
      <Field label="Reason" htmlFor="tr-reason"><Input id="tr-reason" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      <SubmitButton>Transfer</SubmitButton>
    </ActionForm>
  );
}
