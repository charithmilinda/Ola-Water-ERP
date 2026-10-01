"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Textarea } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { completeBatch } from "../actions";

type Bom = { material_id: string; name: string; unit: string; qty_per_unit: number; available: number };

/** Finish production: output, rejects, materials actually used, bottles filled. */
export function CompleteForm({ batchId, planned, bom, returnable, operator }: {
  batchId: string; planned: number; bom: Bom[]; returnable: boolean; operator: string | null;
}) {
  const [good, setGood] = useState(String(planned));
  const [rejected, setRejected] = useState("0");
  const [wastage, setWastage] = useState("");
  const [note, setNote] = useState("");
  const [op, setOp] = useState(operator ?? "");
  const [edited, setEdited] = useState<Record<string, string>>({});
  const [codes, setCodes] = useState("");
  const units = Number(good || 0) + Number(rejected || 0);
  const used = (m: Bom) => edited[m.material_id] ?? String(Math.round(m.qty_per_unit * units * 1000) / 1000);
  const scanned = useMemo(() => new Set(codes.split(/[\s,;]+/).map((c) => c.trim().toUpperCase()).filter(Boolean)).size, [codes]);
  const json = JSON.stringify({ batch_id: batchId, produced_qty: good, rejected_qty: rejected, wastage_qty: wastage, wastage_note: note, operator_name: op,
    materials: bom.map((m) => ({ material_id: m.material_id, qty: used(m) })), codes });

  return (
    <ActionForm action={completeBatch}>
      <input type="hidden" name="payload" value={json} />
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Good units" htmlFor="cb-good" required hint="Go to QC hold"><Input id="cb-good" type="number" min={0} value={good} onChange={(e) => setGood(e.target.value)} required /></Field>
        <Field label="Rejected units" htmlFor="cb-rej" hint="Filled but not usable"><Input id="cb-rej" type="number" min={0} value={rejected} onChange={(e) => setRejected(e.target.value)} /></Field>
        <Field label="Operator" htmlFor="cb-op"><Input id="cb-op" value={op} onChange={(e) => setOp(e.target.value)} /></Field>
        <Field label="Water wasted (litres)" htmlFor="cb-w"><Input id="cb-w" type="number" min={0} step="any" value={wastage} onChange={(e) => setWastage(e.target.value)} /></Field>
        <Field label="Wastage / reject notes" htmlFor="cb-wn" className="sm:col-span-2"><Input id="cb-wn" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      </div>

      <div>
        <p className="mb-1.5 text-sm font-medium text-navy-800">Materials used</p>
        {bom.length === 0 ? (
          <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">No bill of materials is set for this product, so no materials will be taken from stock. Set it under Production → Materials.</p>
        ) : (
          <table className="w-full rounded-lg border border-line text-sm">
            <thead className="bg-surface text-left text-xs text-muted"><tr><th className="px-3 py-2">Material</th><th className="px-3 py-2 text-right">In store</th><th className="px-3 py-2 text-right">Used</th></tr></thead>
            <tbody>
              {bom.map((m) => {
                const short = Number(used(m)) > Number(m.available);
                return (
                  <tr key={m.material_id} className="border-t border-line">
                    <td className="px-3 py-1.5">{m.name} <span className="text-xs text-muted">({m.qty_per_unit} {m.unit} each)</span></td>
                    <td className={`num px-3 py-1.5 text-right ${short ? "font-semibold text-red-700" : "text-muted"}`}>{Number(m.available).toLocaleString()}</td>
                    <td className="w-36 px-3 py-1.5">
                      <Input aria-label={`${m.name} used`} type="number" min={0} step="any" className="text-right" value={used(m)}
                        onChange={(e) => setEdited((x) => ({ ...x, [m.material_id]: e.target.value }))} />
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
        <p className="mt-1 text-xs text-muted">Suggested from the bill of materials for {units} filled unit(s); change it to what was really used.</p>
      </div>

      {returnable && (
        <Field label="Bottle labels filled (optional)" htmlFor="cb-codes"
          hint={`Scan bottle QR codes here (a USB scanner types them in). ${scanned} scanned; the rest are counted. Scanned bottles can be traced in a recall.`}>
          <Textarea id="cb-codes" value={codes} onChange={(e) => setCodes(e.target.value)} placeholder="OLA-BTL-00000001" className="font-mono" />
        </Field>
      )}
      <SubmitButton>Finish production — put on QC hold</SubmitButton>
    </ActionForm>
  );
}
