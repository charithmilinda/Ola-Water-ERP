import { Field, Input, Select, Textarea } from "@/components/ui/field";

export type DocCategory = { code: string; name: string; has_expiry: boolean };

/** Fields of the "Upload a document" form. */
export function DocumentUploadFields({ categories, defaultCategory, entity, entities, replacing }: {
  categories: DocCategory[];
  defaultCategory?: string;
  entity?: { type: string; id: string } | null;
  entities?: { type: string; options: { id: string; name: string }[] }[];
  replacing?: { id: string; category: string; title: string } | null;
}) {
  return (
    <>
      {entity && <><input type="hidden" name="entity_type" value={entity.type} /><input type="hidden" name="entity_id" value={entity.id} /></>}
      {replacing && <><input type="hidden" name="replaces_id" value={replacing.id} /><input type="hidden" name="category_code" value={replacing.category} /></>}
      <Field label="File" htmlFor="du-f" required hint="PDF, photo, Word or Excel — up to 10 MB"><Input id="du-f" name="file" type="file" required className="py-1.5"
        accept="application/pdf,image/*,.doc,.docx,.xls,.xlsx" /></Field>
      <div className="grid gap-4 sm:grid-cols-2">
        {!replacing && (
          <Field label="Type" htmlFor="du-c" required><Select id="du-c" name="category_code" defaultValue={defaultCategory ?? categories[0]?.code} required>
            {categories.map((c) => <option key={c.code} value={c.code}>{c.name}{c.has_expiry ? " (expiry date needed)" : ""}</option>)}</Select></Field>)}
        <Field label="Title" htmlFor="du-t" hint="Blank = file name"><Input id="du-t" name="title" defaultValue={replacing?.title} /></Field>
        <Field label="Reference / policy / licence no." htmlFor="du-r"><Input id="du-r" name="reference_no" /></Field>
        <Field label="Issued on" htmlFor="du-i"><Input id="du-i" name="issued_on" type="date" /></Field>
        <Field label="Expires on" htmlFor="du-e"><Input id="du-e" name="expires_on" type="date" /></Field>
        <Field label="Warn me (days before)" htmlFor="du-a"><Input id="du-a" name="alert_days" type="number" min={0} max={365} placeholder="30" /></Field>
      </div>
      {!entity && !replacing && entities && entities.length > 0 && (
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Belongs to" htmlFor="du-et"><Select id="du-et" name="entity_type" defaultValue="company">
            <option value="company">The company</option>{entities.map((e) => <option key={e.type} value={e.type}>{e.type.charAt(0).toUpperCase() + e.type.slice(1)}</option>)}</Select></Field>
          <Field label="Which one" htmlFor="du-ei" hint="Only when it belongs to someone"><Select id="du-ei" name="entity_id" defaultValue=""><option value="">—</option>
            {entities.map((e) => <optgroup key={e.type} label={e.type}>{e.options.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}</optgroup>)}</Select></Field>
        </div>)}
      <Field label="Notes" htmlFor="du-n"><Textarea id="du-n" name="notes" /></Field>
    </>
  );
}
