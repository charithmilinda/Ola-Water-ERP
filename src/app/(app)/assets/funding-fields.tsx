"use client";

import { useState } from "react";
import { Field, Input, Select } from "@/components/ui/field";

/** How a newly registered asset was paid for. */
export function FundingFields({ money }: { money: { id: string; name: string }[] }) {
  const [f, setF] = useState("paid");
  return (
    <div className="grid gap-4 sm:grid-cols-3">
      <Field label="Paid for" htmlFor="ra-f"><Select id="ra-f" name="funding" value={f} onChange={(e) => setF(e.target.value)}>
        <option value="paid">Paid now from cash / bank</option>
        <option value="opening">Owned before go-live (opening balance)</option>
        <option value="recorded">Already in the accounts (no entry)</option></Select></Field>
      {f === "paid" && <Field label="Paid from" htmlFor="ra-m"><Select id="ra-m" name="money_account_id">{money.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>}
      {f === "opening" && <Field label="Depreciation to date (Rs.)" htmlFor="ra-oa" hint="From the old books"><Input id="ra-oa" name="opening_accumulated" type="number" min={0} step="0.01" /></Field>}
    </div>
  );
}
