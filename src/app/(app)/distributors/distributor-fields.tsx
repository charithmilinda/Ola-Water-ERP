import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { DISTRIBUTOR_KINDS } from "@/lib/labels";

type Opt = { id: string; name: string };
export type DistributorValues = { code?: string; kind?: string; territory_id?: string | null; manager_id?: string | null; agreement_start?: string | null;
  agreement_end?: string | null; monthly_target?: number; min_stock_19l?: number | null; exclusive?: boolean; status?: string; notes?: string | null };

export function DistributorFields({ v, territories, staff, customers }: { v?: DistributorValues; territories: Opt[]; staff: Opt[]; customers?: Opt[] }) {
  return (
    <>
      {customers && (
        <Field label="Customer account they buy on" htmlFor="df-c" required hint="Create the customer first (type Distributor) for its price list, credit limit and bottles">
          <Select id="df-c" name="customer_id" required>{customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>)}
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Code" htmlFor="df-code" required><Input id="df-code" name="code" required defaultValue={v?.code} placeholder="D-KDY" /></Field>
        <Field label="Kind" htmlFor="df-k"><Select id="df-k" name="kind" defaultValue={v?.kind ?? "distributor"}>{DISTRIBUTOR_KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
        <Field label="Territory" htmlFor="df-t"><Select id="df-t" name="territory_id" defaultValue={v?.territory_id ?? ""}><option value="">—</option>{territories.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</Select></Field>
        <Field label="Looked after by" htmlFor="df-m"><Select id="df-m" name="manager_id" defaultValue={v?.manager_id ?? ""}><option value="">—</option>{staff.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
        <Field label="Agreement from" htmlFor="df-as"><Input id="df-as" name="agreement_start" type="date" defaultValue={v?.agreement_start ?? ""} /></Field>
        <Field label="Agreement until" htmlFor="df-ae"><Input id="df-ae" name="agreement_end" type="date" defaultValue={v?.agreement_end ?? ""} /></Field>
        <Field label="Monthly target (Rs., before VAT)" htmlFor="df-tg"><Input id="df-tg" name="monthly_target" type="number" min={0} step="1000" defaultValue={v?.monthly_target ?? ""} /></Field>
        <Field label="Minimum 19L stock to hold" htmlFor="df-ms"><Input id="df-ms" name="min_stock_19l" type="number" min={0} defaultValue={v?.min_stock_19l ?? ""} /></Field>
        {v && <Field label="Status" htmlFor="df-s"><Select id="df-s" name="status" defaultValue={v.status}><option value="active">Active</option><option value="suspended">Suspended</option><option value="ended">Ended</option></Select></Field>}
      </div>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="exclusive" defaultChecked={v?.exclusive} /> Exclusive in this territory</label>
      <Field label="Notes" htmlFor="df-n"><Textarea id="df-n" name="notes" defaultValue={v?.notes ?? ""} /></Field>
    </>
  );
}
