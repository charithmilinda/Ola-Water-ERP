"use client";

import { useState } from "react";
import { Field, Input, Select } from "@/components/ui/field";

type M = { id: string; name: string; kind: string };
const METHODS = [["cash", "Cash", "cash"], ["petty_cash", "Petty cash", "petty_cash"], ["bank_transfer", "Bank transfer", "bank"], ["cheque", "Cheque", "bank"],
  ["card", "Company card", "bank"], ["on_credit", "Not paid yet (bill to pay later)", ""]] as const;

/** How the expense was paid and from which account. */
export function MethodFields({ accounts, prefix = "ex" }: { accounts: M[]; prefix?: string }) {
  const [m, setM] = useState<string>("cash");
  const kind = METHODS.find((x) => x[0] === m)?.[2] ?? "";
  const list = accounts.filter((a) => a.kind === kind);
  return (
    <div className="grid gap-4 sm:grid-cols-3">
      <Field label="Paid by" htmlFor={`${prefix}-m`}><Select id={`${prefix}-m`} name="pay_method" value={m} onChange={(e) => setM(e.target.value)}>
        {METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
      {kind && <Field label="From" htmlFor={`${prefix}-a`}><Select id={`${prefix}-a`} name={`account_${m}`}>{list.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</Select></Field>}
      {(m === "bank_transfer" || m === "cheque") && <Field label={m === "cheque" ? "Cheque no." : "Bank reference"} htmlFor={`${prefix}-r`} required><Input id={`${prefix}-r`} name="reference" required /></Field>}
    </div>
  );
}
