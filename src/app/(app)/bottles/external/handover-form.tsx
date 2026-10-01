"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { recordHandover } from "../actions";

type Opt = { id: string; name: string };

export function HandoverForm({ companies, types }: { companies: Opt[]; types: Opt[] }) {
  const [company, setCompany] = useState(companies[0]?.id ?? "");
  const [codes, setCodes] = useState("");
  const [give, setGive] = useState<Record<string, string>>({});
  const [receive, setReceive] = useState<Record<string, string>>({});
  const [rep, setRep] = useState("");
  const [phone, setPhone] = useState("");
  const [notes, setNotes] = useState("");
  const json = useMemo(() => JSON.stringify({
    company_id: company, codes, rep_name: rep, rep_phone: phone, notes,
    give: types.map((t) => ({ bottle_type_id: t.id, qty: give[t.id] ?? "" })),
    receive: types.map((t) => ({ bottle_type_id: t.id, qty: receive[t.id] ?? "" })),
  }), [company, codes, give, receive, rep, phone, notes, types]);
  const tagged = codes.split(/[\s,;]+/).filter(Boolean).length;

  return (
    <ActionForm action={recordHandover} onSuccess={() => { setCodes(""); setGive({}); setReceive({}); setNotes(""); }}>
      <input type="hidden" name="payload" value={json} />
      <Field label="Company" htmlFor="ho-co"><Select id="ho-co" value={company} onChange={(e) => setCompany(e.target.value)}>{companies.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
      <Field label="Tagged bottles handed over" htmlFor="ho-codes" hint={`Scan each EXT- label. ${tagged} scanned.`}>
        <Textarea id="ho-codes" value={codes} onChange={(e) => setCodes(e.target.value)} rows={4} className="font-mono" />
      </Field>
      <div className="grid gap-4 sm:grid-cols-2">
        {types.map((t) => (
          <Field key={t.id} label={`Untagged ${t.name} handed over`} htmlFor={`g-${t.id}`}><Input id={`g-${t.id}`} type="number" min={0} value={give[t.id] ?? ""} onChange={(e) => setGive((v) => ({ ...v, [t.id]: e.target.value }))} /></Field>
        ))}
        {types.map((t) => (
          <Field key={t.id} label={`OLA ${t.name} received back`} htmlFor={`r-${t.id}`}><Input id={`r-${t.id}`} type="number" min={0} value={receive[t.id] ?? ""} onChange={(e) => setReceive((v) => ({ ...v, [t.id]: e.target.value }))} /></Field>
        ))}
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Received by (their representative)" htmlFor="ho-rep" required><Input id="ho-rep" value={rep} onChange={(e) => setRep(e.target.value)} required /></Field>
        <Field label="Their phone" htmlFor="ho-ph"><Input id="ho-ph" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
      </div>
      <Field label="Notes" htmlFor="ho-notes"><Input id="ho-notes" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
      <SubmitButton>Record hand-over</SubmitButton>
    </ActionForm>
  );
}
