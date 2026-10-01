"use client";

import { useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { completeReconciliation } from "../../../actions";

type Item = { line_id: number; date: string; entry_no: string; description: string; memo: string | null; amount: number };
const rs = (n: number) => `Rs. ${n.toLocaleString("en-LK", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** Tick the items that are on the bank statement until the difference is zero. */
export function ReconForm({ accountId, statementDate, cleared, items }: { accountId: string; statementDate: string; cleared: number; items: Item[] }) {
  const [ticked, setTicked] = useState<Set<number>>(new Set());
  const [stmt, setStmt] = useState("");
  const sum = cleared + items.filter((i) => ticked.has(i.line_id)).reduce((a, i) => a + Number(i.amount), 0);
  const diff = stmt === "" ? null : Math.round((Number(stmt) - sum) * 100) / 100;
  const toggle = (id: number) => setTicked((t) => { const n = new Set(t); if (n.has(id)) n.delete(id); else n.add(id); return n; });

  return (
    <ActionForm action={completeReconciliation} className="space-y-4">
      <input type="hidden" name="money_account_id" value={accountId} />
      <input type="hidden" name="statement_date" value={statementDate} />
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Closing balance on the statement (Rs.)" htmlFor="rc-b" required>
          <Input id="rc-b" name="statement_balance" type="number" step="0.01" value={stmt} onChange={(e) => setStmt(e.target.value)} required />
        </Field>
        <div className="rounded-lg bg-surface p-3 text-sm"><p className="text-muted">Ticked items + already reconciled</p><p className="num text-lg font-semibold">{rs(sum)}</p></div>
        <div className={`rounded-lg p-3 text-sm ${diff === 0 ? "bg-emerald-50 text-emerald-900" : "bg-amber-50 text-amber-900"}`}>
          <p>Difference</p><p className="num text-lg font-semibold">{diff === null ? "—" : rs(diff)}</p>
          {diff !== null && diff !== 0 && <p className="text-xs">Tick more items, or record missing bank charges / interest first.</p>}
        </div>
      </div>
      <div className="overflow-x-auto rounded-lg border border-line">
        <table className="w-full text-sm">
          <thead className="bg-surface text-left text-xs text-muted"><tr>
            <th className="w-10 px-2 py-2"><input type="checkbox" aria-label="Tick all" checked={items.length > 0 && ticked.size === items.length}
              onChange={(e) => setTicked(e.target.checked ? new Set(items.map((i) => i.line_id)) : new Set())} /></th>
            <th className="px-2 py-2">Date</th><th className="px-2 py-2">Entry</th><th className="px-2 py-2">Details</th>
            <th className="px-2 py-2 text-right">Money in</th><th className="px-2 py-2 text-right">Money out</th></tr></thead>
          <tbody>
            {items.length === 0 && <tr><td colSpan={6} className="px-3 py-4 text-muted">Nothing left to reconcile up to this date.</td></tr>}
            {items.map((i) => (
              <tr key={i.line_id} className={`border-t border-line ${ticked.has(i.line_id) ? "bg-emerald-50/50" : ""}`}>
                <td className="px-2 py-1.5"><input type="checkbox" name="line" value={i.line_id} checked={ticked.has(i.line_id)} onChange={() => toggle(i.line_id)} aria-label={`Tick ${i.entry_no}`} /></td>
                <td className="whitespace-nowrap px-2 py-1.5">{i.date}</td>
                <td className="px-2 py-1.5 font-mono text-xs">{i.entry_no}</td>
                <td className="px-2 py-1.5">{i.description}{i.memo && <span className="block text-xs text-muted">{i.memo}</span>}</td>
                <td className="num px-2 py-1.5 text-right">{Number(i.amount) > 0 ? rs(Number(i.amount)) : ""}</td>
                <td className="num px-2 py-1.5 text-right">{Number(i.amount) < 0 ? rs(-Number(i.amount)) : ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Field label="Notes" htmlFor="rc-n"><Input id="rc-n" name="notes" placeholder="e.g. Statement no. 10/2026" /></Field>
      <SubmitButton disabled={diff !== 0}>Save reconciliation</SubmitButton>
    </ActionForm>
  );
}
