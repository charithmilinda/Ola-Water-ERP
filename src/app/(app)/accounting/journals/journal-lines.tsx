"use client";

import { useMemo, useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input, Select } from "@/components/ui/field";

type Account = { id: string; code: string; name: string };
type L = { account_id: string; debit: string; credit: string; memo: string };

/** Debit / credit lines of a manual journal, with a running balance check. */
export function JournalLines({ accounts }: { accounts: Account[] }) {
  const blank: L = { account_id: "", debit: "", credit: "", memo: "" };
  const [rows, setRows] = useState<L[]>([blank, blank]);
  const set = (i: number, k: keyof L, v: string) => setRows((rs) => rs.map((r, n) => (n === i ? { ...r, [k]: v, ...(k === "debit" && v ? { credit: "" } : {}), ...(k === "credit" && v ? { debit: "" } : {}) } : r)));
  const d = rows.reduce((a, r) => a + Number(r.debit || 0), 0);
  const c = rows.reduce((a, r) => a + Number(r.credit || 0), 0);
  const json = useMemo(() => JSON.stringify(rows), [rows]);
  return (
    <div className="space-y-2">
      <input type="hidden" name="lines" value={json} />
      <div className="overflow-x-auto rounded-lg border border-line">
        <table className="w-full text-sm">
          <thead className="bg-surface text-left text-xs text-muted"><tr><th className="px-2 py-2">Account</th><th className="px-2 py-2 text-right">Debit</th>
            <th className="px-2 py-2 text-right">Credit</th><th className="px-2 py-2">Line note</th><th /></tr></thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className="border-t border-line">
                <td className="min-w-64 px-2 py-1.5"><Select aria-label="Account" value={r.account_id} onChange={(e) => set(i, "account_id", e.target.value)}>
                  <option value="">Choose…</option>{accounts.map((a) => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</Select></td>
                <td className="w-32 px-2 py-1.5"><Input aria-label="Debit" type="number" min={0} step="0.01" className="text-right" value={r.debit} onChange={(e) => set(i, "debit", e.target.value)} /></td>
                <td className="w-32 px-2 py-1.5"><Input aria-label="Credit" type="number" min={0} step="0.01" className="text-right" value={r.credit} onChange={(e) => set(i, "credit", e.target.value)} /></td>
                <td className="px-2 py-1.5"><Input aria-label="Line note" value={r.memo} onChange={(e) => set(i, "memo", e.target.value)} /></td>
                <td className="px-1"><Button type="button" variant="ghost" size="icon" aria-label="Remove" disabled={rows.length <= 2} onClick={() => setRows((rs) => rs.filter((_, n) => n !== i))}><Trash2 className="h-4 w-4" /></Button></td>
              </tr>
            ))}
            <tr className="border-t border-line font-medium">
              <td className="px-2 py-2 text-right">Totals</td><td className="num px-3 py-2 text-right">{d.toFixed(2)}</td><td className="num px-3 py-2 text-right">{c.toFixed(2)}</td>
              <td className={`px-2 py-2 ${Math.abs(d - c) < 0.005 && d > 0 ? "text-emerald-700" : "text-red-700"}`}>{Math.abs(d - c) < 0.005 && d > 0 ? "Balanced" : `Difference ${(d - c).toFixed(2)}`}</td><td />
            </tr>
          </tbody>
        </table>
      </div>
      <Button type="button" variant="secondary" size="sm" onClick={() => setRows((rs) => [...rs, blank])}><Plus className="h-4 w-4" /> Add line</Button>
    </div>
  );
}
