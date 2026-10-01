import type { Metadata } from "next";
import { Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { saveRoute, saveVehicle } from "./actions";

export const metadata: Metadata = { title: "Routes & Vehicles" };

type Vehicle = { id: string; registration_no: string; name: string | null; vehicle_type: string; capacity_19l: number | null; is_active: boolean; notes: string | null };
type RouteRow = { id: string; code: string; name: string; area: string | null; default_vehicle_id: string | null; default_driver_id: string | null; is_active: boolean; notes: string | null };

export default async function RoutesPage() {
  const access = await requirePermission(["routes.manage", "fleet.manage"]);
  const supabase = await createClient();
  const [{ data: routes }, { data: vehicles }, { data: drivers }, { data: counts }] = await Promise.all([
    supabase.from("routes").select("*").order("code"),
    supabase.from("vehicles").select("*").order("registration_no"),
    supabase.rpc("list_drivers"),
    supabase.from("customers").select("route_id").neq("status", "inactive"),
  ]);
  const perRoute = new Map<string, number>();
  counts?.forEach((c) => c.route_id && perRoute.set(c.route_id, (perRoute.get(c.route_id) ?? 0) + 1));
  const driverName = Object.fromEntries(((drivers ?? []) as { id: string; full_name: string }[]).map((d) => [d.id, d.full_name]));
  const vehicleName = Object.fromEntries((vehicles ?? []).map((v) => [v.id, v.registration_no]));

  const routeFields = (r?: RouteRow) => (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Code" htmlFor={`rc-${r?.id}`} required hint="e.g. COL-03"><Input id={`rc-${r?.id}`} name="code" defaultValue={r?.code} required disabled={!!r} /></Field>
        <Field label="Name" htmlFor={`rn-${r?.id}`} required><Input id={`rn-${r?.id}`} name="name" defaultValue={r?.name} required /></Field>
      </div>
      <Field label="Area" htmlFor={`ra-${r?.id}`}><Input id={`ra-${r?.id}`} name="area" defaultValue={r?.area ?? ""} placeholder="e.g. Kollupitiya, Bambalapitiya" /></Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Usual vehicle" htmlFor={`rv-${r?.id}`}>
          <Select id={`rv-${r?.id}`} name="default_vehicle_id" defaultValue={r?.default_vehicle_id ?? ""}><option value="">None</option>
            {vehicles?.filter((v) => v.is_active).map((v) => <option key={v.id} value={v.id}>{v.registration_no}</option>)}</Select>
        </Field>
        <Field label="Usual driver" htmlFor={`rd-${r?.id}`}>
          <Select id={`rd-${r?.id}`} name="default_driver_id" defaultValue={r?.default_driver_id ?? ""}><option value="">None</option>
            {((drivers ?? []) as { id: string; full_name: string }[]).map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}</Select>
        </Field>
      </div>
      {r && <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={r.is_active} /> Active</label>}
    </>
  );
  const vehicleFields = (v?: Vehicle) => (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Registration no." htmlFor={`vr-${v?.id}`} required hint="e.g. WP LB-4521"><Input id={`vr-${v?.id}`} name="registration_no" defaultValue={v?.registration_no} required disabled={!!v} /></Field>
        <Field label="Name" htmlFor={`vn-${v?.id}`}><Input id={`vn-${v?.id}`} name="name" defaultValue={v?.name ?? ""} placeholder="e.g. Lorry 1" /></Field>
        <Field label="Type" htmlFor={`vt-${v?.id}`}>
          <Select id={`vt-${v?.id}`} name="vehicle_type" defaultValue={v?.vehicle_type ?? "lorry"}>
            <option value="lorry">Lorry</option><option value="van">Van</option><option value="three_wheeler">Three-wheeler</option><option value="motorbike">Motorbike</option><option value="other">Other</option>
          </Select>
        </Field>
        <Field label="Capacity (19L bottles)" htmlFor={`vc-${v?.id}`}><Input id={`vc-${v?.id}`} name="capacity_19l" type="number" min={0} defaultValue={v?.capacity_19l ?? ""} /></Field>
      </div>
      {v && <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={v.is_active} /> Active</label>}
    </>
  );

  return (
    <>
      <PageHeader title="Routes & Vehicles" description="Each vehicle is also a stock location, so every bottle and product on it is accounted for." />
      <div className="grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader title="Routes" actions={can(access, "routes.manage") && (
            <FormDialog trigger={<><Plus className="h-4 w-4" /> New route</>} title="New route" submitLabel="Create route" action={saveRoute}>{routeFields()}</FormDialog>
          )} />
          <Table>
            <thead><tr><Th>Route</Th><Th>Usual vehicle / driver</Th><Th className="text-right">Customers</Th><Th /></tr></thead>
            <tbody>
              {routes?.map((r) => (
                <tr key={r.id} className={r.is_active ? "" : "opacity-50"}>
                  <Td><span className="font-medium">{r.name}</span><span className="block font-mono text-xs text-muted">{r.code}</span>{r.area && <span className="block text-xs text-muted">{r.area}</span>}</Td>
                  <Td>{r.default_vehicle_id ? vehicleName[r.default_vehicle_id] : "—"}<span className="block text-xs text-muted">{r.default_driver_id ? driverName[r.default_driver_id] : ""}</span></Td>
                  <Td className="num text-right">{perRoute.get(r.id) ?? 0}</Td>
                  <Td className="text-right">{can(access, "routes.manage") && <FormDialog trigger="Edit" triggerVariant="ghost" title={`Edit ${r.name}`} submitLabel="Save" action={saveRoute} hidden={{ id: r.id, code: r.code }}>{routeFields(r)}</FormDialog>}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </Card>
        <Card>
          <CardHeader title="Vehicles" actions={can(access, "fleet.manage") && (
            <FormDialog trigger={<><Plus className="h-4 w-4" /> New vehicle</>} title="New vehicle" submitLabel="Add vehicle" action={saveVehicle}>{vehicleFields()}</FormDialog>
          )} />
          <Table>
            <thead><tr><Th>Vehicle</Th><Th>Type</Th><Th className="text-right">Capacity</Th><Th /></tr></thead>
            <tbody>
              {(vehicles as Vehicle[] | null)?.map((v) => (
                <tr key={v.id} className={v.is_active ? "" : "opacity-50"}>
                  <Td><span className="font-medium">{v.registration_no}</span>{v.name && <span className="block text-xs text-muted">{v.name}</span>}{!v.is_active && <Badge className="mt-1">Inactive</Badge>}</Td>
                  <Td className="capitalize">{v.vehicle_type.replace("_", " ")}</Td>
                  <Td className="num text-right">{v.capacity_19l ?? "—"}</Td>
                  <Td className="text-right">{can(access, "fleet.manage") && <FormDialog trigger="Edit" triggerVariant="ghost" title={`Edit ${v.registration_no}`} submitLabel="Save" action={saveVehicle} hidden={{ id: v.id, registration_no: v.registration_no }}>{vehicleFields(v)}</FormDialog>}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </Card>
      </div>
    </>
  );
}
