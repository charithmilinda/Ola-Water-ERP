import type { Metadata } from "next";
import Link from "next/link";
import { Truck } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, todayISO } from "@/lib/format";
import { RUN_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Input, Label } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { PlanRun } from "./plan-run";

export const metadata: Metadata = { title: "Dispatch & Runs" };

export default async function DispatchPage({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
  const access = await requirePermission(["deliveries.view", "deliveries.manage"]);
  const today = todayISO();
  const date = (await searchParams).date ?? today;
  const supabase = await createClient();
  const [{ data: runs }, { data: orders }, { data: routes }, { data: vehicles }, { data: drivers }] = await Promise.all([
    supabase.from("route_runs").select("id, run_no, run_date, status, cash_float, route:routes(name), vehicle:vehicles(registration_no), driver:profiles!route_runs_driver_id_fkey(full_name), deliveries(status)")
      .or(`run_date.eq.${date},status.in.(planned,loaded,in_progress,checked_in)`).order("run_date", { ascending: false }).order("run_no"),
    supabase.from("orders").select("id, order_no, requested_date, route_id, customer:customers(name), items:order_items(qty, product:products(name, is_returnable))")
      .eq("status", "confirmed").order("requested_date"),
    supabase.from("routes").select("id, name, default_vehicle_id, default_driver_id").eq("is_active", true).order("name"),
    supabase.from("vehicles").select("id, registration_no, name").eq("is_active", true).order("registration_no"),
    supabase.rpc("list_drivers"),
  ]);
  type RunRow = { id: string; run_no: string; run_date: string; status: string; route: { name: string } | null; vehicle: { registration_no: string } | null;
    driver: { full_name: string } | null; deliveries: { status: string }[] };
  type OrderRow = { id: string; order_no: string; requested_date: string; route_id: string | null; customer: { name: string } | null;
    items: { qty: number; product: { name: string; is_returnable: boolean } }[] };

  return (
    <>
      <PageHeader title="Dispatch & Runs" description="Plan a run, load the vehicle, and check it back in. Every bottle, product and rupee is reconciled." />
      {can(access, "deliveries.manage") && (
        <Card className="mb-6">
          <CardHeader title="Plan a run" description="Pick confirmed orders, a vehicle and a driver." />
          <CardBody>
            <PlanRun today={today}
              orders={((orders ?? []) as unknown as OrderRow[]).map((o) => ({
                id: o.id, order_no: o.order_no, requested_date: o.requested_date, route_id: o.route_id, customer: o.customer?.name ?? "",
                items: o.items.map((i) => `${Number(i.qty)} × ${i.product.name}`).join(", "),
                returnable: o.items.filter((i) => i.product.is_returnable).reduce((a, i) => a + Number(i.qty), 0),
              }))}
              routes={(routes ?? []).map((r) => ({ id: r.id, name: r.name, default_vehicle_id: r.default_vehicle_id, default_driver_id: r.default_driver_id }))}
              vehicles={(vehicles ?? []).map((v) => ({ id: v.id, name: v.name ? `${v.registration_no} (${v.name})` : v.registration_no }))}
              drivers={((drivers ?? []) as { id: string; full_name: string }[]).map((d) => ({ id: d.id, name: d.full_name }))} />
          </CardBody>
        </Card>
      )}
      <Card>
        <CardHeader title="Runs" description="Open runs and runs on the chosen date" actions={
          <form method="get" className="flex items-end gap-2"><div><Label htmlFor="date" className="sr-only">Date</Label><Input id="date" name="date" type="date" defaultValue={date} /></div><Button type="submit" variant="secondary">Show</Button></form>
        } />
        {(runs ?? []).length === 0 ? <EmptyState icon={Truck} title="No runs" description="Plan a run above." /> : (
          <Table>
            <thead><tr><Th>Run</Th><Th>Date</Th><Th>Route</Th><Th>Vehicle / driver</Th><Th>Stops</Th><Th>Status</Th></tr></thead>
            <tbody>
              {((runs ?? []) as unknown as RunRow[]).map((r) => {
                const b = statusBadge(RUN_STATUS, r.status);
                const done = r.deliveries.filter((d) => ["delivered", "partially_delivered", "failed"].includes(d.status)).length;
                const total = r.deliveries.filter((d) => d.status !== "cancelled").length;
                return (
                  <tr key={r.id} className="hover:bg-ola-50/40">
                    <Td><Link href={`/dispatch/${r.id}`} className="font-medium text-ola-700 hover:underline">{r.run_no}</Link></Td>
                    <Td>{formatDate(r.run_date)}</Td>
                    <Td>{r.route?.name ?? "—"}</Td>
                    <Td>{r.vehicle?.registration_no}<span className="block text-xs text-muted">{r.driver?.full_name}</span></Td>
                    <Td className="num">{done} / {total}</Td>
                    <Td><Badge tone={b.tone}>{b.label}</Badge></Td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
