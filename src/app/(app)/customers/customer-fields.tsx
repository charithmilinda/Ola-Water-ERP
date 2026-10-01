import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { CUSTOMER_TYPES, POLICIES } from "@/lib/labels";
import { formatPhone } from "@/lib/format";

export type CustomerRow = {
  id: string; name: string; company_name: string | null; customer_type: string; contact_person: string | null;
  phone: string; phone2: string | null; email: string | null; vat_no: string | null; route_id: string | null;
  route_sequence: number | null; price_list_id: string; credit_limit: number; payment_terms_days: number;
  bottle_model: string; allowed_bottles: number; external_policy: string | null; status: string; notes: string | null;
};

type Opt = { id: string; name: string };

export function CustomerFields({
  c,
  routes,
  priceLists,
  canCredit,
}: {
  c?: CustomerRow;
  routes: Opt[];
  priceLists: Opt[];
  canCredit: boolean;
}) {
  return (
    <div className="space-y-6">
      <fieldset className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <legend className="mb-2 text-sm font-semibold text-navy-900">Customer</legend>
        <Field label="Name" htmlFor="name" required>
          <Input id="name" name="name" defaultValue={c?.name} required />
        </Field>
        <Field label="Company" htmlFor="company_name">
          <Input id="company_name" name="company_name" defaultValue={c?.company_name ?? ""} />
        </Field>
        <Field label="Type" htmlFor="customer_type" required hint={c ? undefined : "Sets bottle model, price list and terms"}>
          <Select id="customer_type" name="customer_type" defaultValue={c?.customer_type ?? "household"} required>
            {CUSTOMER_TYPES.map(([v, l]) => (
              <option key={v} value={v}>
                {l}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Contact person" htmlFor="contact_person">
          <Input id="contact_person" name="contact_person" defaultValue={c?.contact_person ?? ""} />
        </Field>
        <Field label="Mobile" htmlFor="phone" required hint="e.g. 077 123 4567">
          <Input id="phone" name="phone" type="tel" inputMode="tel" defaultValue={c ? formatPhone(c.phone) : ""} required />
        </Field>
        <Field label="Other phone" htmlFor="phone2">
          <Input id="phone2" name="phone2" type="tel" inputMode="tel" defaultValue={c?.phone2 ? formatPhone(c.phone2) : ""} />
        </Field>
        <Field label="Email" htmlFor="email">
          <Input id="email" name="email" type="email" defaultValue={c?.email ?? ""} />
        </Field>
        <Field label="VAT number" htmlFor="vat_no" hint="If set, invoices are tax invoices">
          <Input id="vat_no" name="vat_no" defaultValue={c?.vat_no ?? ""} />
        </Field>
        {c && (
          <Field label="Status" htmlFor="status">
            <Select id="status" name="status" defaultValue={c.status}>
              <option value="active">Active</option>
              <option value="on_hold">On hold (orders need approval)</option>
              <option value="inactive">Inactive</option>
            </Select>
          </Field>
        )}
      </fieldset>

      {!c && (
        <fieldset className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <legend className="mb-2 text-sm font-semibold text-navy-900">Delivery address</legend>
          <Field label="Address" htmlFor="address_line" required className="sm:col-span-2">
            <Input id="address_line" name="address_line" required />
          </Field>
          <Field label="City" htmlFor="city">
            <Input id="city" name="city" />
          </Field>
          <Field label="District" htmlFor="district">
            <Input id="district" name="district" />
          </Field>
          <Field label="GPS latitude" htmlFor="gps_lat" hint="Optional, e.g. 6.9022">
            <Input id="gps_lat" name="gps_lat" inputMode="decimal" />
          </Field>
          <Field label="GPS longitude" htmlFor="gps_lng" hint="Optional, e.g. 79.8507">
            <Input id="gps_lng" name="gps_lng" inputMode="decimal" />
          </Field>
          <Field label="Delivery instructions" htmlFor="delivery_instructions" className="sm:col-span-2 lg:col-span-3">
            <Input id="delivery_instructions" name="delivery_instructions" placeholder="e.g. Gate code, call before arriving" />
          </Field>
        </fieldset>
      )}

      <fieldset className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <legend className="mb-2 text-sm font-semibold text-navy-900">Delivery & pricing</legend>
        <Field label="Route" htmlFor="route_id">
          <Select id="route_id" name="route_id" defaultValue={c?.route_id ?? ""}>
            <option value="">Not on a route</option>
            {routes.map((r) => (
              <option key={r.id} value={r.id}>
                {r.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Stop order on route" htmlFor="route_sequence">
          <Input id="route_sequence" name="route_sequence" type="number" min={1} defaultValue={c?.route_sequence ?? ""} />
        </Field>
        <Field label="Price list" htmlFor="price_list_id" hint={c ? undefined : "Leave as default to use the type's list"}>
          <Select id="price_list_id" name="price_list_id" defaultValue={c?.price_list_id ?? ""}>
            {!c && <option value="">Default for this type</option>}
            {priceLists.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </Select>
        </Field>
      </fieldset>

      <fieldset className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <legend className="mb-2 text-sm font-semibold text-navy-900">Bottles & credit</legend>
        <Field label="Bottle model" htmlFor="bottle_model">
          <Select id="bottle_model" name="bottle_model" defaultValue={c?.bottle_model ?? ""}>
            {!c && <option value="">Default for this type</option>}
            <option value="deposit">Deposit per bottle</option>
            <option value="loan">Loan, up to a limit</option>
            <option value="none">No returnable bottles</option>
          </Select>
        </Field>
        <Field label="Bottle limit (loan)" htmlFor="allowed_bottles" hint={c ? undefined : "Blank = default for the type"}>
          <Input id="allowed_bottles" name="allowed_bottles" type="number" min={0} defaultValue={c?.allowed_bottles ?? ""} />
        </Field>
        <Field label="Other companies' bottles" htmlFor="external_policy">
          <Select id="external_policy" name="external_policy" defaultValue={c?.external_policy ?? ""}>
            <option value="">Company default</option>
            {POLICIES.map(([v, l]) => (
              <option key={v} value={v}>
                {l}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Credit limit (Rs.)" htmlFor="credit_limit" hint={canCredit ? "0 = no credit (pay on delivery)" : "A change goes to Finance for approval"}>
          <Input id="credit_limit" name="credit_limit" type="number" min={0} step="0.01" defaultValue={c?.credit_limit ?? 0} />
        </Field>
        <Field label="Payment terms (days)" htmlFor="payment_terms_days" hint={c ? undefined : "Blank = default for the type"}>
          <Input id="payment_terms_days" name="payment_terms_days" type="number" min={0} defaultValue={c?.payment_terms_days ?? ""} />
        </Field>
      </fieldset>

      <Field label="Notes" htmlFor="notes">
        <Textarea id="notes" name="notes" defaultValue={c?.notes ?? ""} />
      </Field>
    </div>
  );
}
