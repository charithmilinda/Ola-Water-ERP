"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { receiveShopBottles } from "../actions";

type Opt = { id: string; name: string };

export function BottleReturnForm({ shops, companies, types }: { shops: Opt[]; companies: (Opt & { is_own: boolean })[]; types: Opt[] }) {
  const [shop, setShop] = useState(shops[0]?.id ?? "");
  const [qty, setQty] = useState<Record<string, string>>({});
  const [codes, setCodes] = useState("");
  const [notes, setNotes] = useState("");
  const json = useMemo(() => JSON.stringify({
    shop_id: shop, codes, notes,
    lines: companies.flatMap((c) => types.map((t) => ({ company_id: c.id, bottle_type_id: t.id, qty: qty[`${c.id}|${t.id}`] ?? "" }))),
  }), [shop, codes, notes, qty, companies, types]);
  return (
    <ActionForm action={receiveShopBottles} onSuccess={() => { setQty({}); setCodes(""); }}>
      <input type="hidden" name="payload" value={json} />
      <Field label="From shop" htmlFor="br-shop"><Select id="br-shop" value={shop} onChange={(e) => setShop(e.target.value)}>{shops.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
      <div className="grid gap-3 sm:grid-cols-2">
        {companies.flatMap((c) => types.map((t) => (
          <Field key={`${c.id}|${t.id}`} label={`${c.name} ${t.name} empties`} htmlFor={`br-${c.id}-${t.id}`}>
            <Input id={`br-${c.id}-${t.id}`} type="number" min={0} placeholder="0" value={qty[`${c.id}|${t.id}`] ?? ""}
              onChange={(e) => setQty((v) => ({ ...v, [`${c.id}|${t.id}`]: e.target.value }))} />
          </Field>
        )))}
      </div>
      <Field label="Tagged bottles (optional)" htmlFor="br-codes" hint="Scan labels to record them one by one — don't count them above as well">
        <Textarea id="br-codes" rows={3} className="font-mono" value={codes} onChange={(e) => setCodes(e.target.value)} />
      </Field>
      <Field label="Notes" htmlFor="br-notes"><Input id="br-notes" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
      <SubmitButton>Receive bottles</SubmitButton>
    </ActionForm>
  );
}
