"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Textarea } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { Table, Td, Th } from "@/components/ui/table";
import { formatLKR } from "@/lib/format";
import { loadRun, checkinRun } from "../actions";

type LoadLine = { product_id: string; product_name: string; qty: number; available: number };

export function LoadForm({ runId, suggested, products }: { runId: string; suggested: LoadLine[]; products: { id: string; name: string; available: number }[] }) {
  const [qty, setQty] = useState<Record<string, string>>(Object.fromEntries(suggested.map((s) => [s.product_id, String(Number(s.qty))])));
  const [float, setFloat] = useState("0");
  const json = useMemo(() => JSON.stringify({ run_id: runId, cash_float: float, lines: Object.entries(qty).map(([product_id, q]) => ({ product_id, qty: q })) }), [runId, qty, float]);
  return (
    <ActionForm action={loadRun}>
      <input type="hidden" name="payload" value={json} />
      <Table>
        <thead><tr><Th>Product</Th><Th className="text-right">Ordered</Th><Th className="text-right">In warehouse</Th><Th className="w-36">Load</Th></tr></thead>
        <tbody>
          {products.map((p) => {
            const s = suggested.find((x) => x.product_id === p.id);
            const over = Number(qty[p.id] || 0) > p.available;
            return (
              <tr key={p.id}>
                <Td>{p.name}</Td>
                <Td className="num text-right">{s ? Number(s.qty) : 0}</Td>
                <Td className={`num text-right ${over ? "text-red-700" : ""}`}>{p.available}</Td>
                <Td><Input type="number" min={0} value={qty[p.id] ?? ""} onChange={(e) => setQty((v) => ({ ...v, [p.id]: e.target.value }))} aria-label={`Load ${p.name}`} /></Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
      <p className="text-xs text-muted">Load a few extra bottles for walk-up sales if you like — unsold stock comes back at check-in.</p>
      <Field label="Cash float given to the driver (Rs.)" htmlFor="float"><Input id="float" type="number" min={0} step="0.01" value={float} onChange={(e) => setFloat(e.target.value)} /></Field>
      <SubmitButton>Confirm load-out</SubmitButton>
    </ActionForm>
  );
}

type ExpProduct = { product_id: string; name: string; qty: number };
type ExpBottle = { company_id: string; company: string; bottle_type_id: string; type: string; fill_state: string; qty: number };

export function CheckinForm({ runId, products, bottles, cashExpected }: { runId: string; products: ExpProduct[]; bottles: ExpBottle[]; cashExpected: number }) {
  const [pq, setPq] = useState<Record<string, string>>({});
  const [bq, setBq] = useState<Record<string, string>>({});
  const [scanned, setScanned] = useState("");
  const [cash, setCash] = useState("");
  const [notes, setNotes] = useState("");
  const key = (b: ExpBottle) => `${b.company_id}|${b.bottle_type_id}|${b.fill_state}`;
  const json = useMemo(() => JSON.stringify({
    run_id: runId,
    products: products.map((p) => ({ product_id: p.product_id, qty: pq[p.product_id] ?? "0" })),
    bottles: bottles.map((b) => ({ company_id: b.company_id, bottle_type_id: b.bottle_type_id, fill_state: b.fill_state, qty: bq[key(b)] ?? "0" })),
    scanned, cash_handed: cash, notes,
  }), [runId, products, bottles, pq, bq, scanned, cash, notes]);
  const blank = products.some((p) => pq[p.product_id] === undefined || pq[p.product_id] === "") || bottles.some((b) => bq[key(b)] === undefined || bq[key(b)] === "") || cash === "";

  return (
    <ActionForm action={checkinRun}>
      <input type="hidden" name="payload" value={json} />
      <p className="text-sm text-muted">Count what physically comes off the vehicle. The system compares it with what should be there and flags every difference.</p>
      <Table>
        <thead><tr><Th>Item</Th><Th className="text-right">Expected</Th><Th className="w-36">Counted</Th></tr></thead>
        <tbody>
          {products.map((p) => (
            <tr key={p.product_id}>
              <Td>{p.name} <span className="text-muted">(full, unsold)</span></Td>
              <Td className="num text-right">{p.qty}</Td>
              <Td><Input type="number" min={0} value={pq[p.product_id] ?? ""} onChange={(e) => setPq((v) => ({ ...v, [p.product_id]: e.target.value }))} aria-label={`Counted ${p.name}`} /></Td>
            </tr>
          ))}
          {bottles.map((b) => (
            <tr key={key(b)}>
              <Td>{b.company} {b.type} <span className="text-muted">({b.fill_state})</span></Td>
              <Td className="num text-right">{b.qty}</Td>
              <Td><Input type="number" min={0} value={bq[key(b)] ?? ""} onChange={(e) => setBq((v) => ({ ...v, [key(b)]: e.target.value }))} aria-label={`Counted ${b.company} ${b.type}`} /></Td>
            </tr>
          ))}
          <tr>
            <Td>Cash handed in</Td>
            <Td className="num text-right">{formatLKR(cashExpected)}</Td>
            <Td><Input type="number" min={0} step="0.01" value={cash} onChange={(e) => setCash(e.target.value)} aria-label="Cash handed in" /></Td>
          </tr>
        </tbody>
      </Table>
      <Field label="Tagged bottles scanned (optional)" htmlFor="ci-scan" hint="Scan EXT- and OLA labels to verify them one by one. Include them in the counts above too.">
        <Textarea id="ci-scan" rows={3} className="font-mono" value={scanned} onChange={(e) => setScanned(e.target.value)} />
      </Field>
      <Field label="Notes" htmlFor="ci-notes"><Input id="ci-notes" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
      <SubmitButton disabled={blank}>Complete check-in</SubmitButton>
      {blank && <p className="text-xs text-muted">Enter a count for every line (0 if none).</p>}
    </ActionForm>
  );
}
