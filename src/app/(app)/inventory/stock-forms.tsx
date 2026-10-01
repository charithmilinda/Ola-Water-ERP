"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { receiveStock, transferStock } from "./actions";

type Opt = { id: string; name: string };

export function ReceiveForm({ locations, products }: { locations: Opt[]; products: Opt[] }) {
  const [location, setLocation] = useState(locations[0]?.id ?? "");
  const [source, setSource] = useState("receipt");
  const [reason, setReason] = useState("");
  const [qty, setQty] = useState<Record<string, string>>({});
  const json = useMemo(() => JSON.stringify({ location, source, reason, lines: Object.entries(qty).map(([product_id, q]) => ({ product_id, qty: q })) }), [location, source, reason, qty]);
  return (
    <ActionForm action={receiveStock} onSuccess={() => { setQty({}); setReason(""); }}>
      <input type="hidden" name="payload" value={json} />
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Into" htmlFor="rc-loc"><Select id="rc-loc" value={location} onChange={(e) => setLocation(e.target.value)}>{locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
        <Field label="Type" htmlFor="rc-src" hint={source === "receipt" ? "19L: fills empty bottles already here" : "19L: full bottles come in from outside"}>
          <Select id="rc-src" value={source} onChange={(e) => setSource(e.target.value)}>
            <option value="receipt">Filled / received today</option>
            <option value="opening">Opening stock at go-live</option>
          </Select>
        </Field>
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        {products.map((p) => (
          <Field key={p.id} label={p.name} htmlFor={`rq-${p.id}`}>
            <Input id={`rq-${p.id}`} type="number" min={0} step={1} value={qty[p.id] ?? ""} onChange={(e) => setQty((v) => ({ ...v, [p.id]: e.target.value }))} placeholder="0" />
          </Field>
        ))}
      </div>
      <Field label="Reason / reference" htmlFor="rc-reason" required><Input id="rc-reason" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Batch 2026-10-02 morning shift" required /></Field>
      <SubmitButton>Receive stock</SubmitButton>
    </ActionForm>
  );
}

export function TransferForm({ locations, products }: { locations: Opt[]; products: Opt[] }) {
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
          <Field key={p.id} label={p.name} htmlFor={`tq-${p.id}`}>
            <Input id={`tq-${p.id}`} type="number" min={0} step={1} value={qty[p.id] ?? ""} onChange={(e) => setQty((v) => ({ ...v, [p.id]: e.target.value }))} placeholder="0" />
          </Field>
        ))}
      </div>
      <Field label="Reason" htmlFor="tr-reason"><Input id="tr-reason" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      <SubmitButton>Transfer</SubmitButton>
    </ActionForm>
  );
}
