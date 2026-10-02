import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { CUSTOMER_TYPES, LEAD_SOURCES } from "@/lib/labels";

type Opt = { id: string; name: string };
export type LeadValues = { name?: string; company_name?: string | null; contact_person?: string | null; phone?: string | null; email?: string | null;
  address_line?: string | null; city?: string | null; customer_type?: string | null; source?: string; campaign_id?: string | null; territory_id?: string | null;
  owner_id?: string | null; status?: string; est_monthly_bottles?: number | null; est_monthly_value?: number | null; next_follow_up?: string | null;
  lost_reason?: string | null; notes?: string | null };

export function LeadFields({ v, staff, campaigns, territories, withStatus }: { v?: LeadValues; staff: Opt[]; campaigns: Opt[]; territories: Opt[]; withStatus?: boolean }) {
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Name" htmlFor="lf-n" required><Input id="lf-n" name="name" required defaultValue={v?.name} /></Field>
        <Field label="Company / business" htmlFor="lf-co"><Input id="lf-co" name="company_name" defaultValue={v?.company_name ?? ""} /></Field>
        <Field label="Contact person" htmlFor="lf-cp"><Input id="lf-cp" name="contact_person" defaultValue={v?.contact_person ?? ""} /></Field>
        <Field label="Phone" htmlFor="lf-p"><Input id="lf-p" name="phone" type="tel" defaultValue={v?.phone ?? ""} placeholder="077 123 4567" /></Field>
        <Field label="Email" htmlFor="lf-e"><Input id="lf-e" name="email" type="email" defaultValue={v?.email ?? ""} /></Field>
        <Field label="Would be a" htmlFor="lf-t"><Select id="lf-t" name="customer_type" defaultValue={v?.customer_type ?? ""}><option value="">—</option>
          {CUSTOMER_TYPES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
        <Field label="Address" htmlFor="lf-a" className="sm:col-span-2"><Input id="lf-a" name="address_line" defaultValue={v?.address_line ?? ""} /></Field>
        <Field label="Town" htmlFor="lf-c"><Input id="lf-c" name="city" defaultValue={v?.city ?? ""} /></Field>
        <Field label="Where from" htmlFor="lf-s"><Select id="lf-s" name="source" defaultValue={v?.source ?? "phone"}>{LEAD_SOURCES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
        <Field label="Campaign" htmlFor="lf-cm"><Select id="lf-cm" name="campaign_id" defaultValue={v?.campaign_id ?? ""}><option value="">—</option>{campaigns.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
        <Field label="Territory" htmlFor="lf-tr"><Select id="lf-tr" name="territory_id" defaultValue={v?.territory_id ?? ""}><option value="">—</option>{territories.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</Select></Field>
        <Field label="Bottles a month (estimate)" htmlFor="lf-b"><Input id="lf-b" name="est_monthly_bottles" type="number" min={0} defaultValue={v?.est_monthly_bottles ?? ""} /></Field>
        <Field label="Rs. a month (estimate)" htmlFor="lf-v"><Input id="lf-v" name="est_monthly_value" type="number" min={0} step="100" defaultValue={v?.est_monthly_value ?? ""} /></Field>
        <Field label="Owner" htmlFor="lf-o" hint="Blank = you"><Select id="lf-o" name="owner_id" defaultValue={v?.owner_id ?? ""}><option value="">—</option>{staff.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
        <Field label="Next follow-up" htmlFor="lf-f"><Input id="lf-f" name="next_follow_up" type="date" defaultValue={v?.next_follow_up ?? ""} /></Field>
        {withStatus && <Field label="Stage" htmlFor="lf-st"><Select id="lf-st" name="status" defaultValue={v?.status ?? "new"}>
          <option value="new">New</option><option value="contacted">Contacted</option><option value="qualified">Prospect (qualified)</option>
          <option value="proposal">Offer made</option><option value="lost">Lost</option></Select></Field>}
        {withStatus && <Field label="If lost — why" htmlFor="lf-l"><Input id="lf-l" name="lost_reason" defaultValue={v?.lost_reason ?? ""} /></Field>}
      </div>
      <Field label="Notes" htmlFor="lf-no"><Textarea id="lf-no" name="notes" defaultValue={v?.notes ?? ""} /></Field>
    </>
  );
}
