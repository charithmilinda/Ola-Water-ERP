"use client";

import { useMemo, useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "./button";
import { Input, Select } from "./field";

export type LineItemOption = { id: string; name: string; unit?: string | null; hint?: string | null; defaults?: Record<string, string> };
export type LineColumn = {
  key: string;
  label: string;
  type?: "number" | "text" | "date";
  step?: string;
  min?: number;
  placeholder?: string;
  className?: string;
};
export type Line = { item_id: string } & Record<string, string>;

/**
 * Editable list of item lines (bill of materials, purchase lines, supplier prices).
 * The rows are posted as JSON in a hidden field called `name`.
 */
export function LineEditor({
  name,
  items,
  columns,
  initial = [],
  itemLabel = "Item",
  addLabel = "Add line",
  minRows = 1,
}: {
  name: string;
  items: LineItemOption[];
  columns: LineColumn[];
  initial?: Line[];
  itemLabel?: string;
  addLabel?: string;
  minRows?: number;
}) {
  const blank = (): Line => ({ item_id: "", ...Object.fromEntries(columns.map((c) => [c.key, ""])) });
  const [rows, setRows] = useState<Line[]>(() => {
    const r = [...initial];
    while (r.length < minRows) r.push(blank());
    return r;
  });
  const json = useMemo(() => JSON.stringify(rows.filter((r) => r.item_id)), [rows]);
  const byId = useMemo(() => Object.fromEntries(items.map((i) => [i.id, i])), [items]);

  const set = (i: number, key: string, value: string) =>
    setRows((rs) =>
      rs.map((r, n) => {
        if (n !== i) return r;
        if (key === "item_id") {
          const d = byId[value]?.defaults ?? {};
          const filled = Object.fromEntries(columns.map((c) => [c.key, r[c.key] || d[c.key] || ""]));
          return { ...r, ...filled, item_id: value };
        }
        return { ...r, [key]: value };
      }),
    );

  return (
    <div className="space-y-2">
      <input type="hidden" name={name} value={json} />
      <div className="overflow-x-auto rounded-lg border border-line">
        <table className="w-full text-sm">
          <thead className="bg-surface text-left text-xs font-medium text-muted">
            <tr>
              <th className="px-2 py-2">{itemLabel}</th>
              {columns.map((c) => (
                <th key={c.key} className={`px-2 py-2 ${c.type === "number" ? "text-right" : ""}`}>{c.label}</th>
              ))}
              <th className="w-10" />
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className="border-t border-line">
                <td className="min-w-48 px-2 py-1.5">
                  <Select aria-label={itemLabel} value={r.item_id} onChange={(e) => set(i, "item_id", e.target.value)}>
                    <option value="">Choose…</option>
                    {items.map((it) => (
                      <option key={it.id} value={it.id} disabled={it.id !== r.item_id && rows.some((x) => x.item_id === it.id)}>
                        {it.name}{it.unit ? ` (${it.unit})` : ""}
                      </option>
                    ))}
                  </Select>
                  {r.item_id && byId[r.item_id]?.hint && <p className="mt-0.5 text-xs text-muted">{byId[r.item_id]?.hint}</p>}
                </td>
                {columns.map((c) => (
                  <td key={c.key} className={`px-2 py-1.5 ${c.className ?? "w-32"}`}>
                    <Input
                      aria-label={c.label}
                      type={c.type ?? "text"}
                      step={c.step}
                      min={c.min}
                      inputMode={c.type === "number" ? "decimal" : undefined}
                      className={c.type === "number" ? "text-right" : ""}
                      placeholder={c.placeholder}
                      value={r[c.key] ?? ""}
                      onChange={(e) => set(i, c.key, e.target.value)}
                    />
                  </td>
                ))}
                <td className="px-1">
                  <Button type="button" variant="ghost" size="icon" aria-label="Remove line" disabled={rows.length <= minRows}
                    onClick={() => setRows((rs) => rs.filter((_, n) => n !== i))}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Button type="button" variant="secondary" size="sm" onClick={() => setRows((rs) => [...rs, blank()])}>
        <Plus className="h-4 w-4" /> {addLabel}
      </Button>
    </div>
  );
}
