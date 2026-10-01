"use client";

import { useState } from "react";
import { Field, Input, Select, Textarea } from "@/components/ui/field";

type Param = { id: string; name: string; unit: string | null; value_type: string; min_value: number | null; max_value: number | null; is_required: boolean };
export type QcTemplate = { id: string; name: string; parameters: Param[] };

function limits(p: Param) {
  if (p.value_type !== "number") return p.value_type === "pass_fail" ? "Pass / fail" : "";
  if (p.min_value !== null && p.max_value !== null) return `${p.min_value} – ${p.max_value}`;
  if (p.min_value !== null) return `at least ${p.min_value}`;
  if (p.max_value !== null) return `at most ${p.max_value}`;
  return "";
}

/** Fields for one QC test: choose a template, then enter each result. */
export function QcTestFields({ templates }: { templates: QcTemplate[] }) {
  const [tid, setTid] = useState(templates[0]?.id ?? "");
  const [vals, setVals] = useState<Record<string, string>>({});
  const t = templates.find((x) => x.id === tid);
  const out = (p: Param) => {
    const v = vals[p.id];
    if (!v || p.value_type !== "number" || Number.isNaN(Number(v))) return false;
    const n = Number(v);
    return (p.min_value !== null && n < p.min_value) || (p.max_value !== null && n > p.max_value);
  };
  if (templates.length === 0) return <p className="text-sm text-red-700">Set up a QC template first (Quality Control → Templates).</p>;
  return (
    <>
      <Field label="Test template" htmlFor="qt-t"><Select id="qt-t" name="template_id" value={tid} onChange={(e) => { setTid(e.target.value); setVals({}); }}>
        {templates.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
      <div className="grid gap-3 sm:grid-cols-2">
        {t?.parameters.map((p) => (
          <Field key={p.id} label={`${p.name}${p.unit ? ` (${p.unit})` : ""}`} htmlFor={`qp-${p.id}`} required={p.is_required} hint={limits(p) || undefined}>
            {p.value_type === "pass_fail" ? (
              <Select id={`qp-${p.id}`} name={`param:${p.id}`} required={p.is_required} value={vals[p.id] ?? ""} onChange={(e) => setVals((x) => ({ ...x, [p.id]: e.target.value }))}>
                <option value="">Choose…</option><option value="pass">Pass / absent</option><option value="fail">Fail / present</option>
              </Select>
            ) : (
              <Input id={`qp-${p.id}`} name={`param:${p.id}`} required={p.is_required} type={p.value_type === "number" ? "number" : "text"} step="any"
                value={vals[p.id] ?? ""} onChange={(e) => setVals((x) => ({ ...x, [p.id]: e.target.value }))}
                className={out(p) ? "border-red-400 bg-red-50 text-red-800" : ""} />
            )}
            {out(p) && <p className="mt-1 text-xs font-medium text-red-700">Outside the limit — the test will fail</p>}
          </Field>
        ))}
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Sample reference" htmlFor="qt-s"><Input id="qt-s" name="sample_ref" /></Field>
        <Field label="Laboratory" htmlFor="qt-l"><Input id="qt-l" name="lab_name" placeholder="In-house or lab name" /></Field>
      </div>
      <Field label="Certificate / lab report" htmlFor="qt-c" hint="PDF or photo, up to 10 MB (optional)">
        <Input id="qt-c" name="certificate" type="file" accept="application/pdf,image/*" className="py-1.5" />
      </Field>
      <Field label="Notes" htmlFor="qt-n"><Textarea id="qt-n" name="notes" /></Field>
    </>
  );
}
