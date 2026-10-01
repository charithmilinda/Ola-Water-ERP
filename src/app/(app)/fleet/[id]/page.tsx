import type { Metadata } from "next";
import { DocumentsCard } from "@/components/documents/documents-card";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatLKR, formatQty, humanize, todayISO } from "@/lib/format";
import { FUEL_TYPES } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { DocumentFields, FuelFields, ServiceFields } from "../fleet-forms";
import { recordDocument, recordFuel, recordService, saveVehicleDetails } from "../actions";

export const metadata: Metadata = { title: "Vehicle" };

type Details = {
  vehicle: { id: string; registration_no: string; name: string | null; vehicle_type: string; capacity_19l: number | null; make: string | null; model: string | null;
    year_made: number | null; fuel_type: string | null; odometer_km: number | null; assigned_driver_id: string | null; driver: string | null;
    service_interval_km: number | null; service_interval_days: number | null; last_service_km: number | null; last_service_date: string | null; is_active: boolean };
  overview: { alerts: string[]; km_per_litre: number | null; next_service_km: number | null; next_service_date: string | null } | null;
  documents: { id: string; doc_type: string; doc_no: string | null; provider: string | null; issued_on: string | null; expires_on: string; cost: number | null }[];
  fuel: { date: string; litres: number; amount: number; odometer_km: number | null; station: string | null; driver: string | null; run_no: string | null }[];
  services: { id: string; service_date: string; kind: string; description: string; odometer_km: number | null; cost: number; vendor: string | null; next_due_km: number | null }[];
  expenses: { id: string; expense_no: string; date: string; category: string; description: string; total: number; status: string; pay_method: string }[];
  asset: { id: string; asset_no: string; cost: number; accumulated: number; book_value: number } | null;
  runs_this_month: number;
};

export default async function VehiclePage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["fleet.manage", "deliveries.manage"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [{ data, error }, { data: money }, { data: logins }] = await Promise.all([
    supabase.rpc("vehicle_details", { p_vehicle: id }),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).order("is_default", { ascending: false }),
    supabase.rpc("list_user_logins"),
  ]);
  if (error || !data) notFound();
  const d = data as Details;
  const v = d.vehicle;
  const manage = can(access, "fleet.manage") && v.is_active;
  const today = todayISO();
  const drivers = ((logins ?? []) as { id: string; full_name: string; is_driver: boolean }[]).filter((x) => x.is_driver).map((x) => ({ id: x.id, name: x.full_name }));
  const one = [{ id: v.id, name: v.name ?? "", registration_no: v.registration_no }];

  return (
    <>
      <Link href="/fleet" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Fleet</Link>
      <PageHeader title={v.registration_no}
        description={[v.name, v.make, v.model, v.year_made, v.fuel_type && humanize(v.fuel_type), v.capacity_19l && `${v.capacity_19l} × 19L`, v.driver && `driver ${v.driver}`].filter(Boolean).join(" · ")}
        actions={manage && <>
          <FormDialog trigger="Fuel" triggerVariant="primary" triggerSize="md" title={`Fuel — ${v.registration_no}`} submitLabel="Save" action={recordFuel}>
            <FuelFields vehicles={one} fixed={v.id} drivers={drivers} money={money ?? []} today={today} />
          </FormDialog>
          <FormDialog trigger="Service / repair" triggerSize="md" title={`Service or repair — ${v.registration_no}`} submitLabel="Save" action={recordService} wide>
            <ServiceFields vehicles={one} fixed={v.id} money={money ?? []} today={today} />
          </FormDialog>
          <FormDialog trigger="Document" triggerSize="md" title={`Document — ${v.registration_no}`} submitLabel="Save" action={recordDocument}>
            <DocumentFields vehicles={one} fixed={v.id} money={money ?? []} />
          </FormDialog>
          <FormDialog trigger="Edit details" triggerSize="md" title={`Details — ${v.registration_no}`} submitLabel="Save" action={saveVehicleDetails} hidden={{ vehicle_id: v.id }}>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Make" htmlFor="vd-mk"><Input id="vd-mk" name="make" defaultValue={v.make ?? ""} /></Field>
              <Field label="Model" htmlFor="vd-md"><Input id="vd-md" name="model" defaultValue={v.model ?? ""} /></Field>
              <Field label="Year" htmlFor="vd-y"><Input id="vd-y" name="year_made" type="number" defaultValue={v.year_made ?? ""} /></Field>
              <Field label="Fuel" htmlFor="vd-f"><Select id="vd-f" name="fuel_type" defaultValue={v.fuel_type ?? ""}><option value="">—</option>
                {FUEL_TYPES.map(([x, l]) => <option key={x} value={x}>{l}</option>)}</Select></Field>
              <Field label="Regular driver" htmlFor="vd-dr" className="sm:col-span-2"><Select id="vd-dr" name="assigned_driver_id" defaultValue={v.assigned_driver_id ?? ""}>
                <option value="">—</option>{drivers.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
              <Field label="Odometer now (km)" htmlFor="vd-o"><Input id="vd-o" name="odometer_km" type="number" min={0} defaultValue={v.odometer_km ?? ""} /></Field>
              <Field label="Service every (km)" htmlFor="vd-sk"><Input id="vd-sk" name="service_interval_km" type="number" min={1} defaultValue={v.service_interval_km ?? ""} /></Field>
              <Field label="…or every (days)" htmlFor="vd-sd"><Input id="vd-sd" name="service_interval_days" type="number" min={1} defaultValue={v.service_interval_days ?? ""} /></Field>
              <Field label="Last service (km)" htmlFor="vd-lk"><Input id="vd-lk" name="last_service_km" type="number" min={0} defaultValue={v.last_service_km ?? ""} /></Field>
              <Field label="Last service (date)" htmlFor="vd-ld"><Input id="vd-ld" name="last_service_date" type="date" defaultValue={v.last_service_date ?? ""} /></Field>
            </div>
          </FormDialog>
        </>} />

      {(d.overview?.alerts ?? []).length > 0 && <div className="mb-4 flex flex-wrap gap-2">{d.overview!.alerts.map((a) => <Badge key={a} tone={a.includes("expired") ? "red" : "amber"}>{a}</Badge>)}</div>}

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Card className="p-5"><p className="text-sm text-muted">Odometer</p><p className="num mt-1 text-2xl font-semibold">{v.odometer_km !== null ? `${formatQty(v.odometer_km)} km` : "—"}</p>
          <p className="text-xs text-muted">{d.overview?.km_per_litre ? `${d.overview.km_per_litre} km per litre (recent fills)` : "Record odometer with fuel for km/L"}</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">Next service</p><p className="num mt-1 text-2xl font-semibold">{d.overview?.next_service_km ? `${formatQty(d.overview.next_service_km)} km` : "—"}</p>
          <p className="text-xs text-muted">{d.overview?.next_service_date ? `or by ${formatDate(d.overview.next_service_date)}` : ""}</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">Runs this month</p><p className="num mt-1 text-2xl font-semibold">{d.runs_this_month}</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">Book value</p><p className="num mt-1 text-2xl font-semibold">{d.asset ? formatLKR(d.asset.book_value) : "—"}</p>
          <p className="text-xs text-muted">{d.asset ? <Link href={`/assets/${d.asset.id}`} className="text-ola-700 hover:underline">{d.asset.asset_no}</Link> : "Not in the asset register"}</p></Card>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Documents" />
          {d.documents.length === 0 ? <CardBody><p className="text-sm text-muted">No insurance, licence or emission test recorded.</p></CardBody> : (
            <Table>
              <thead><tr><Th>Document</Th><Th>Number</Th><Th>Expires</Th></tr></thead>
              <tbody>{d.documents.map((x) => (
                <tr key={x.id}><Td>{humanize(x.doc_type)}{x.provider && <span className="block text-xs text-muted">{x.provider}</span>}</Td><Td>{x.doc_no ?? "—"}</Td>
                  <Td className={x.expires_on < today ? "font-semibold text-red-700" : ""}>{formatDate(x.expires_on)}</Td></tr>))}</tbody>
            </Table>
          )}
        </Card>
        <Card>
          <CardHeader title="Services & repairs" />
          {d.services.length === 0 ? <CardBody><p className="text-sm text-muted">None recorded.</p></CardBody> : (
            <Table>
              <thead><tr><Th>Date</Th><Th>Work</Th><Th className="text-right">Km</Th><Th className="text-right">Cost</Th></tr></thead>
              <tbody>{d.services.map((x) => (
                <tr key={x.id}><Td className="whitespace-nowrap">{formatDate(x.service_date)}</Td>
                  <Td>{humanize(x.kind)} — {x.description}{x.vendor && <span className="block text-xs text-muted">{x.vendor}</span>}</Td>
                  <Td className="num text-right">{x.odometer_km ? formatQty(x.odometer_km) : "—"}</Td><Td className="num text-right">{formatLKR(x.cost)}</Td></tr>))}</tbody>
            </Table>
          )}
        </Card>
        <Card>
          <CardHeader title="Fuel" />
          {d.fuel.length === 0 ? <CardBody><p className="text-sm text-muted">None recorded.</p></CardBody> : (
            <Table>
              <thead><tr><Th>Date</Th><Th className="text-right">Litres</Th><Th className="text-right">Amount</Th><Th className="text-right">Km</Th><Th>By</Th></tr></thead>
              <tbody>{d.fuel.map((x, i) => (
                <tr key={i}><Td className="whitespace-nowrap">{formatDate(x.date)}</Td><Td className="num text-right">{formatQty(x.litres)}</Td>
                  <Td className="num text-right">{formatLKR(x.amount)}</Td><Td className="num text-right">{x.odometer_km ? formatQty(x.odometer_km) : "—"}</Td>
                  <Td>{x.driver ?? "—"}{x.run_no && <span className="block text-xs text-muted">{x.run_no}</span>}</Td></tr>))}</tbody>
            </Table>
          )}
        </Card>
        <Card>
          <CardHeader title="All costs" description="Every expense booked to this vehicle, including driver expenses on the road." />
          {d.expenses.length === 0 ? <CardBody><p className="text-sm text-muted">None.</p></CardBody> : (
            <Table>
              <thead><tr><Th>Date</Th><Th>Expense</Th><Th className="text-right">Amount</Th><Th>Status</Th></tr></thead>
              <tbody>{d.expenses.map((x) => (
                <tr key={x.id}><Td className="whitespace-nowrap">{formatDate(x.date)}</Td>
                  <Td>{x.category}<span className="block text-xs text-muted">{x.expense_no} · {x.description}{x.pay_method === "driver_cash" ? " · paid by driver" : ""}</span></Td>
                  <Td className="num text-right">{formatLKR(x.total)}</Td>
                  <Td><Badge tone={x.status === "rejected" ? "red" : x.status === "pending_approval" ? "amber" : "green"}>{humanize(x.status)}</Badge></Td></tr>))}</tbody>
            </Table>
          )}
        </Card>
      </div>
      <div className="mt-6"><DocumentsCard access={access} entityType="vehicle" entityId={id} categories={["vehicle","insurance","other"]} returnTo={`/fleet/${id}`} /></div>
    </>
  );
}
