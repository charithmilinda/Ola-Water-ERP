import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { SERVICE_KINDS, VEHICLE_DOC_TYPES } from "@/lib/labels";
import { MethodFields } from "../expenses/method-fields";

type Opt = { id: string; name: string };
type Money = { id: string; name: string; kind: string };

function VehicleSelect({ vehicles, fixed, k }: { vehicles: (Opt & { registration_no: string })[]; fixed?: string; k: string }) {
  if (fixed) return <input type="hidden" name="vehicle_id" value={fixed} />;
  return (
    <Field label="Vehicle" htmlFor={`v-${k}`}><Select id={`v-${k}`} name="vehicle_id">
      {vehicles.map((v) => <option key={v.id} value={v.id}>{v.registration_no}{v.name ? ` — ${v.name}` : ""}</option>)}</Select></Field>
  );
}

export function FuelFields({ vehicles, fixed, drivers, money, today }: { vehicles: (Opt & { registration_no: string })[]; fixed?: string; drivers: Opt[]; money: Money[]; today: string }) {
  return (
    <>
      <VehicleSelect vehicles={vehicles} fixed={fixed} k="fu" />
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Date" htmlFor="fu-d"><Input id="fu-d" name="date" type="date" defaultValue={today} max={today} /></Field>
        <Field label="Litres" htmlFor="fu-l" required><Input id="fu-l" name="litres" type="number" min={0.1} step="0.01" required /></Field>
        <Field label="Amount (Rs.)" htmlFor="fu-a" required><Input id="fu-a" name="amount" type="number" min={1} step="0.01" required /></Field>
        <Field label="Odometer (km)" htmlFor="fu-o" hint="For km per litre"><Input id="fu-o" name="odometer_km" type="number" min={0} /></Field>
        <Field label="Station" htmlFor="fu-s" className="sm:col-span-2"><Input id="fu-s" name="station" /></Field>
      </div>
      <Field label="Driver" htmlFor="fu-dr"><Select id="fu-dr" name="driver_id"><option value="">—</option>{drivers.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
      <MethodFields accounts={money} prefix="fu" />
    </>
  );
}

export function ServiceFields({ vehicles, fixed, money, today }: { vehicles: (Opt & { registration_no: string })[]; fixed?: string; money: Money[]; today: string }) {
  return (
    <>
      <VehicleSelect vehicles={vehicles} fixed={fixed} k="sv" />
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Date" htmlFor="sv-d"><Input id="sv-d" name="date" type="date" defaultValue={today} max={today} /></Field>
        <Field label="Kind" htmlFor="sv-k"><Select id="sv-k" name="kind">{SERVICE_KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
        <Field label="Odometer (km)" htmlFor="sv-o"><Input id="sv-o" name="odometer_km" type="number" min={0} /></Field>
      </div>
      <Field label="Work done" htmlFor="sv-w" required><Textarea id="sv-w" name="description" required /></Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Cost (Rs.)" htmlFor="sv-c" hint="0 if free / under warranty"><Input id="sv-c" name="cost" type="number" min={0} step="0.01" defaultValue={0} /></Field>
        <Field label="Garage" htmlFor="sv-g"><Input id="sv-g" name="vendor" /></Field>
        <Field label="Next service at (km)" htmlFor="sv-nk" hint="Blank = this km + the service interval"><Input id="sv-nk" name="next_due_km" type="number" min={0} /></Field>
        <Field label="Next service by (date)" htmlFor="sv-nd"><Input id="sv-nd" name="next_due_date" type="date" /></Field>
      </div>
      <MethodFields accounts={money} prefix="sv" />
    </>
  );
}

export function DocumentFields({ vehicles, fixed, money }: { vehicles: (Opt & { registration_no: string })[]; fixed?: string; money: Money[] }) {
  return (
    <>
      <VehicleSelect vehicles={vehicles} fixed={fixed} k="dc" />
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Document" htmlFor="dc-t"><Select id="dc-t" name="doc_type">{VEHICLE_DOC_TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
        <Field label="Number" htmlFor="dc-n"><Input id="dc-n" name="doc_no" /></Field>
        <Field label="Issued by" htmlFor="dc-p"><Input id="dc-p" name="provider" placeholder="Insurer / authority" /></Field>
        <Field label="Issued on" htmlFor="dc-i"><Input id="dc-i" name="issued_on" type="date" /></Field>
        <Field label="Expires on" htmlFor="dc-e" required><Input id="dc-e" name="expires_on" type="date" required /></Field>
        <Field label="Cost (Rs.)" htmlFor="dc-c" hint="Leave empty if already recorded as an expense"><Input id="dc-c" name="cost" type="number" min={0} step="0.01" /></Field>
      </div>
      <MethodFields accounts={money} prefix="dc" />
    </>
  );
}
