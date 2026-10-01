"use client";

import { useMemo, useState } from "react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { formatDate } from "@/lib/format";
import { createRun } from "./actions";

type Order = { id: string; order_no: string; requested_date: string; route_id: string | null; customer: string; items: string; returnable: number };
type Opt = { id: string; name: string };
type RouteOpt = Opt & { default_vehicle_id: string | null; default_driver_id: string | null };

export function PlanRun({ orders, routes, vehicles, drivers, today }: { orders: Order[]; routes: RouteOpt[]; vehicles: Opt[]; drivers: Opt[]; today: string }) {
  const [date, setDate] = useState(today);
  const [route, setRoute] = useState("");
  const [vehicle, setVehicle] = useState("");
  const [driver, setDriver] = useState("");
  const [helper, setHelper] = useState("");
  const [picked, setPicked] = useState<Set<string>>(new Set());

  const visible = orders.filter((o) => o.requested_date <= date && (!route || o.route_id === route || (route === "none" && !o.route_id)));
  const bottles = visible.filter((o) => picked.has(o.id)).reduce((a, o) => a + o.returnable, 0);
  const json = useMemo(() => JSON.stringify({ run_date: date, route_id: route === "none" ? "" : route, vehicle_id: vehicle, driver_id: driver,
    order_ids: [...picked], helper, notes: "" }), [date, route, vehicle, driver, picked, helper]);

  const chooseRoute = (id: string) => {
    setRoute(id);
    const r = routes.find((x) => x.id === id);
    if (r?.default_vehicle_id) setVehicle(r.default_vehicle_id);
    if (r?.default_driver_id) setDriver(r.default_driver_id);
    setPicked(new Set(orders.filter((o) => o.requested_date <= date && (o.route_id === id)).map((o) => o.id)));
  };

  return (
    <ActionForm action={createRun}>
      <input type="hidden" name="payload" value={json} />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
        <Field label="Date" htmlFor="pr-date"><Input id="pr-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
        <Field label="Route" htmlFor="pr-route">
          <Select id="pr-route" value={route} onChange={(e) => chooseRoute(e.target.value)}>
            <option value="">All routes</option>
            {routes.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
            <option value="none">Customers without a route</option>
          </Select>
        </Field>
        <Field label="Vehicle" htmlFor="pr-veh" required>
          <Select id="pr-veh" value={vehicle} onChange={(e) => setVehicle(e.target.value)} required>
            <option value="">Choose…</option>
            {vehicles.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
          </Select>
        </Field>
        <Field label="Driver" htmlFor="pr-drv" required>
          <Select id="pr-drv" value={driver} onChange={(e) => setDriver(e.target.value)} required>
            <option value="">Choose…</option>
            {drivers.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
          </Select>
        </Field>
        <Field label="Helper" htmlFor="pr-help"><Input id="pr-help" value={helper} onChange={(e) => setHelper(e.target.value)} /></Field>
      </div>
      <div className="rounded-lg border border-line">
        <div className="flex items-center justify-between border-b border-line bg-surface px-4 py-2 text-sm">
          <label className="flex items-center gap-2 font-medium">
            <input type="checkbox" checked={visible.length > 0 && visible.every((o) => picked.has(o.id))}
              onChange={(e) => setPicked(e.target.checked ? new Set(visible.map((o) => o.id)) : new Set())} />
            Confirmed orders due by {formatDate(date)} ({visible.length})
          </label>
          <span className="num text-muted">{picked.size} selected · {bottles} returnable bottles</span>
        </div>
        <ul className="max-h-80 divide-y divide-line overflow-auto">
          {visible.length === 0 && <li className="px-4 py-6 text-center text-sm text-muted">No confirmed orders waiting.</li>}
          {visible.map((o) => (
            <li key={o.id}>
              <label className="flex cursor-pointer items-start gap-3 px-4 py-2.5 text-sm hover:bg-ola-50/50">
                <input type="checkbox" className="mt-1" checked={picked.has(o.id)} onChange={(e) => setPicked((s) => { const n = new Set(s); if (e.target.checked) n.add(o.id); else n.delete(o.id); return n; })} />
                <span className="flex-1">
                  <span className="font-medium">{o.customer}</span> <span className="text-muted">· {o.order_no}{o.requested_date < date && ` · due ${formatDate(o.requested_date)}`}</span>
                  <span className="block text-muted">{o.items}</span>
                </span>
              </label>
            </li>
          ))}
        </ul>
      </div>
      <SubmitButton disabled={picked.size === 0}>Create run with {picked.size} stop(s)</SubmitButton>
    </ActionForm>
  );
}
