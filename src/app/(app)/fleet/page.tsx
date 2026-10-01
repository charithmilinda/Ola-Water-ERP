import type { Metadata } from "next";
import Link from "next/link";
import { Car } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatQty, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Input } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { DocumentFields, FuelFields, ServiceFields } from "./fleet-forms";
import { recordDocument, recordFuel, recordService } from "./actions";

export const metadata: Metadata = { title: "Fleet" };

type Row = { id: string; registration_no: string; name: string | null; vehicle_type: string; make: string | null; model: string | null; odometer_km: number | null;
  is_active: boolean; driver: string | null; documents: Record<string, { expires_on: string }>; next_service_km: number | null; next_service_date: string | null;
  fuel_month_litres: number; fuel_month_amount: number; km_per_litre: number | null; alerts: string[] };
type Profit = { vehicle_id: string; registration_no: string; runs: number; sales: number; fuel: number; repairs: number; other_costs: number; depreciation: number;
  contribution: number };

export default async function FleetPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const access = await requirePermission(["fleet.manage", "deliveries.manage"]);
  const sp = await searchParams;
  const today = todayISO();
  const to = sp.to && /^\d{4}-\d{2}-\d{2}$/.test(sp.to) ? sp.to : today;
  const from = sp.from && /^\d{4}-\d{2}-\d{2}$/.test(sp.from) ? sp.from : `${to.slice(0, 7)}-01`;
  const supabase = await createClient();
  const [{ data }, { data: profit }, { data: money }, { data: logins }, { count: pendingDriver }] = await Promise.all([
    supabase.rpc("fleet_overview"),
    supabase.rpc("vehicle_profitability", { p_from: from, p_to: to }),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).order("is_default", { ascending: false }),
    supabase.rpc("list_user_logins"),
    supabase.from("expenses").select("id", { count: "exact", head: true }).eq("pay_method", "driver_cash").eq("status", "pending_approval"),
  ]);
  const rows = (data ?? []) as Row[];
  const active = rows.filter((v) => v.is_active);
  const vehicles = active.map((v) => ({ id: v.id, name: v.name ?? "", registration_no: v.registration_no }));
  const drivers = ((logins ?? []) as { id: string; full_name: string; is_driver: boolean }[]).filter((x) => x.is_driver).map((x) => ({ id: x.id, name: x.full_name }));
  const manage = can(access, "fleet.manage");
  const docExp = (r: Row, t: string) => r.documents?.[t]?.expires_on;
  const late = (d?: string) => d && d < today;

  return (
    <>
      <PageHeader title="Fleet" description="Vehicle documents, fuel, services and repairs, and what each vehicle earns and costs. Add vehicles under Routes & Vehicles."
        actions={manage && active.length > 0 && <>
          <FormDialog trigger="Record fuel" triggerVariant="primary" triggerSize="md" title="Fuel" submitLabel="Save" action={recordFuel}>
            <FuelFields vehicles={vehicles} drivers={drivers} money={money ?? []} today={today} />
          </FormDialog>
          <FormDialog trigger="Service / repair" triggerSize="md" title="Service or repair" submitLabel="Save" action={recordService} wide>
            <ServiceFields vehicles={vehicles} money={money ?? []} today={today} />
          </FormDialog>
          <FormDialog trigger="Licence / insurance" triggerSize="md" title="Vehicle document" submitLabel="Save" action={recordDocument}>
            <DocumentFields vehicles={vehicles} money={money ?? []} />
          </FormDialog>
        </>} />

      {(pendingDriver ?? 0) > 0 && <Alert tone="warning" className="mb-4">{pendingDriver} driver expense(s) wait for approval — <Link href="/expenses" className="font-semibold underline">Expenses</Link>.</Alert>}

      <Card className="mb-6">
        <CardHeader title="Vehicles" />
        {rows.length === 0 ? <EmptyState icon={Car} title="No vehicles" description="Add vehicles under Delivery → Routes & Vehicles." /> : (
          <Table>
            <thead><tr><Th>Vehicle</Th><Th>Driver</Th><Th className="text-right">Odometer</Th><Th>Insurance</Th><Th>Revenue licence</Th><Th>Emission</Th>
              <Th>Next service</Th><Th className="text-right">Fuel this month</Th><Th>Needs attention</Th></tr></thead>
            <tbody>{rows.map((v) => (
              <tr key={v.id} className={v.is_active ? "hover:bg-ola-50/40" : "opacity-50"}>
                <Td><Link href={`/fleet/${v.id}`} className="font-medium text-ola-700 hover:underline">{v.registration_no}</Link>
                  <span className="block text-xs text-muted">{[v.name, v.make, v.model].filter(Boolean).join(" · ") || v.vehicle_type}</span></Td>
                <Td>{v.driver ?? "—"}</Td>
                <Td className="num text-right">{v.odometer_km !== null ? `${formatQty(v.odometer_km)} km` : "—"}</Td>
                {(["insurance", "revenue_licence", "emission_test"] as const).map((t) => (
                  <Td key={t} className={late(docExp(v, t)) ? "font-semibold text-red-700" : ""}>{docExp(v, t) ? formatDate(docExp(v, t)!) : <span className="text-muted">—</span>}</Td>))}
                <Td>{v.next_service_km ? `${formatQty(v.next_service_km)} km` : ""}{v.next_service_date && <span className="block text-xs">{formatDate(v.next_service_date)}</span>}
                  {!v.next_service_km && !v.next_service_date && <span className="text-muted">—</span>}</Td>
                <Td className="num text-right">{formatLKR(v.fuel_month_amount)}<span className="block text-xs text-muted">{formatQty(v.fuel_month_litres)} L
                  {v.km_per_litre ? ` · ${v.km_per_litre} km/L` : ""}</span></Td>
                <Td>{v.alerts.map((a) => <Badge key={a} tone={a.includes("expired") ? "red" : "amber"} className="mb-1 mr-1">{a}</Badge>)}</Td>
              </tr>))}</tbody>
          </Table>
        )}
      </Card>

      <Card>
        <CardHeader title="Vehicle profitability" description="Sales delivered by each vehicle (before VAT) less its fuel, repairs, other costs and depreciation. Driver wages are not included."
          actions={<form className="flex flex-wrap items-center gap-1">
            <Input type="date" name="from" defaultValue={from} className="h-8 w-40" aria-label="From" />
            <Input type="date" name="to" defaultValue={to} className="h-8 w-40" aria-label="To" />
            <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Show</button></form>} />
        <Table>
          <thead><tr><Th>Vehicle</Th><Th className="text-right">Runs</Th><Th className="text-right">Sales</Th><Th className="text-right">Fuel</Th><Th className="text-right">Repairs</Th>
            <Th className="text-right">Other</Th><Th className="text-right">Depreciation</Th><Th className="text-right">Contribution</Th></tr></thead>
          <tbody>{((profit ?? []) as Profit[]).map((p) => (
            <tr key={p.vehicle_id}><Td className="font-medium">{p.registration_no}</Td><Td className="num text-right">{p.runs}</Td>
              <Td className="num text-right">{formatLKR(p.sales)}</Td><Td className="num text-right">{formatLKR(p.fuel)}</Td><Td className="num text-right">{formatLKR(p.repairs)}</Td>
              <Td className="num text-right">{formatLKR(p.other_costs)}</Td><Td className="num text-right">{formatLKR(p.depreciation)}</Td>
              <Td className={`num text-right font-semibold ${Number(p.contribution) < 0 ? "text-red-700" : ""}`}>{formatLKR(p.contribution)}</Td></tr>))}</tbody>
        </Table>
      </Card>
    </>
  );
}
