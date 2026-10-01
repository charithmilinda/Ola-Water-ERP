import { Field, Input, Textarea } from "@/components/ui/field";

export type Supplier = { id: string; code: string; name: string; contact_person: string | null; phone: string | null; email: string | null;
  address: string | null; city: string | null; vat_no: string | null; payment_terms_days: number; notes: string | null; is_active: boolean };

export function SupplierFields({ s }: { s?: Supplier }) {
  const k = s?.id ?? "new";
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Code" htmlFor={`sc-${k}`} required hint="Short code, e.g. PACKLK"><Input id={`sc-${k}`} name="code" defaultValue={s?.code} required disabled={!!s} /></Field>
        <Field label="Name" htmlFor={`sn-${k}`} required><Input id={`sn-${k}`} name="name" defaultValue={s?.name} required /></Field>
        <Field label="Contact person" htmlFor={`scp-${k}`}><Input id={`scp-${k}`} name="contact_person" defaultValue={s?.contact_person ?? ""} /></Field>
        <Field label="Phone" htmlFor={`sp-${k}`}><Input id={`sp-${k}`} name="phone" defaultValue={s?.phone ?? ""} /></Field>
        <Field label="Email" htmlFor={`se-${k}`}><Input id={`se-${k}`} name="email" type="email" defaultValue={s?.email ?? ""} /></Field>
        <Field label="City" htmlFor={`sci-${k}`}><Input id={`sci-${k}`} name="city" defaultValue={s?.city ?? ""} /></Field>
        <Field label="VAT registration no." htmlFor={`sv-${k}`} hint="If set, purchase orders add VAT automatically"><Input id={`sv-${k}`} name="vat_no" defaultValue={s?.vat_no ?? ""} /></Field>
        <Field label="Payment terms (days)" htmlFor={`st-${k}`}><Input id={`st-${k}`} name="payment_terms_days" type="number" min={0} defaultValue={s?.payment_terms_days ?? 30} /></Field>
      </div>
      <Field label="Address" htmlFor={`sa-${k}`}><Input id={`sa-${k}`} name="address" defaultValue={s?.address ?? ""} /></Field>
      <Field label="Notes" htmlFor={`sno-${k}`}><Textarea id={`sno-${k}`} name="notes" defaultValue={s?.notes ?? ""} /></Field>
      {s && <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={s.is_active} /> Active</label>}
      {s && <Field label="Reason for change" htmlFor={`sr-${k}`}><Input id={`sr-${k}`} name="reason" /></Field>}
    </>
  );
}
