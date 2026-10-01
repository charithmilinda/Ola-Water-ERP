"use client";

import { useMemo, useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input, Select } from "@/components/ui/field";

export type Param = { name: string; unit: string; value_type: string; min_value: string; max_value: string; is_required: boolean };

/** Test parameters of a QC template; posted as JSON in "parameters". */
export function TemplateEditor({ initial }: { initial: Param[] }) {
  const blank: Param = { name: "", unit: "", value_type: "number", min_value: "", max_value: "", is_required: true };
  const [rows, setRows] = useState<Param[]>(initial.length ? initial : [blank]);
  const json = useMemo(() => JSON.stringify(rows.filter((r) => r.name.trim()).map((r) => ({
    ...r, min_value: r.min_value === "" ? null : Number(r.min_value), max_value: r.max_value === "" ? null : Number(r.max_value) }))), [rows]);
  const set = (i: number, k: keyof Param, v: string | boolean) => setRows((rs) => rs.map((r, n) => (n === i ? { ...r, [k]: v } : r)));
  return (
    <div className="space-y-2">
      <input type="hidden" name="parameters" value={json} />
      <div className="overflow-x-auto rounded-lg border border-line">
        <table className="w-full text-sm">
          <thead className="bg-surface text-left text-xs text-muted">
            <tr><th className="px-2 py-2">Test</th><th className="px-2 py-2">Unit</th><th className="px-2 py-2">Kind</th><th className="px-2 py-2">Min</th>
              <th className="px-2 py-2">Max</th><th className="px-2 py-2">Required</th><th /></tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className="border-t border-line">
                <td className="px-2 py-1.5"><Input aria-label="Test name" value={r.name} onChange={(e) => set(i, "name", e.target.value)} placeholder="pH" /></td>
                <td className="w-24 px-2 py-1.5"><Input aria-label="Unit" value={r.unit} onChange={(e) => set(i, "unit", e.target.value)} placeholder="ppm" /></td>
                <td className="w-36 px-2 py-1.5">
                  <Select aria-label="Kind" value={r.value_type} onChange={(e) => set(i, "value_type", e.target.value)}>
                    <option value="number">Number</option><option value="pass_fail">Pass / fail</option><option value="text">Note</option>
                  </Select>
                </td>
                <td className="w-24 px-2 py-1.5"><Input aria-label="Minimum" type="number" step="any" disabled={r.value_type !== "number"} value={r.min_value} onChange={(e) => set(i, "min_value", e.target.value)} /></td>
                <td className="w-24 px-2 py-1.5"><Input aria-label="Maximum" type="number" step="any" disabled={r.value_type !== "number"} value={r.max_value} onChange={(e) => set(i, "max_value", e.target.value)} /></td>
                <td className="px-2 py-1.5 text-center"><input aria-label="Required" type="checkbox" checked={r.is_required} onChange={(e) => set(i, "is_required", e.target.checked)} /></td>
                <td className="px-1"><Button type="button" variant="ghost" size="icon" aria-label="Remove" disabled={rows.length === 1}
                  onClick={() => setRows((rs) => rs.filter((_, n) => n !== i))}><Trash2 className="h-4 w-4" /></Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Button type="button" variant="secondary" size="sm" onClick={() => setRows((rs) => [...rs, blank])}><Plus className="h-4 w-4" /> Add test</Button>
    </div>
  );
}
