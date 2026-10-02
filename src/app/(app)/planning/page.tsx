import type { Metadata } from "next";
import Link from "next/link";
import { CalendarClock, Phone } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatPhone, formatQty } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { EmptyState } from "@/components/ui/empty-state";
import { buttonVariants } from "@/components/ui/button";
import { ColumnChart, Sparkline } from "@/components/charts/charts";
import { OrderPanel } from "@/components/map/order-panel";
import { WarehouseGps } from "./warehouse-gps";
import { applyRouteSequence, setWarehouseGps } from "./actions";

export const metadata: Metadata = { title: "Planning" };

type Fc = { weeks: number; week_starts: string[]; weekday_share: { dow: number; share: number }[]; by_route: { route: string; stops_week: number; qty_week: number }[];
  products: { product_id: string; product: string; sku: string; history: number[]; trend_pct: number | null; forecast_week: number; forecast_total: number;
    recurring_week: number; open_orders: number; available: number; qc_hold: number; cover_days: number | null; suggested_production: number }[] };
type Need = { material: string; sku: string; item_type: string; needed: number; available: number; reorder_level: number; on_order: number; to_buy: number };
type Refill = { customer_id: string; customer_no: string; customer: string; phone: string; customer_type: string; route: string | null; last_date: string;
  usual_gap_days: number; due_date: string; days_late: number; usual_qty: number | null; outstanding: number };
type RouteSug = { route: { id: string; name: string }; start: { name: string; lat: number; lng: number } | null; current_km: number | null; suggested_km: number | null;
  suggested: { customer_id: string; customer: string; customer_no: string; address: string | null; lat: number; lng: number; current_seq: number | null }[];
  no_gps: { customer_id: string; customer: string; customer_no: string; current_seq: number | null }[] };

const TABS = [["forecast", "Demand forecast"], ["materials", "Materials to buy"], ["refill", "Due for a refill"], ["routes", "Route order"]] as const;
const DAYS = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

export default async function PlanningPage({ searchParams }: { searchParams: Promise<{ tab?: string; weeks?: string; route?: string; days?: string }> }) {
  const access = await getAccess();
  const canForecast = can(access, ["production.view", "inventory.view", "reports.view"]);
  const canRefill = can(access, ["orders.manage", "crm.manage"]);
  const canRoutes = can(access, ["routes.manage", "deliveries.manage"]);
  if (!canForecast && !canRefill && !canRoutes) redirect("/forbidden");
  const sp = await searchParams;
  const allowed = TABS.filter(([k]) => (k === "refill" ? canRefill : k === "routes" ? canRoutes : canForecast));
  const tab = allowed.some(([k]) => k === sp.tab) ? sp.tab! : allowed[0][0];
  const weeks = Math.min(8, Math.max(1, Number(sp.weeks) || 4));
  const supabase = await createClient();

  let body: React.ReactNode = null;
  if (tab === "forecast") {
    const { data, error } = await supabase.rpc("demand_forecast", { p_weeks: weeks });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const f = data as Fc;
    const total = f.products.reduce((a, p) => a + Number(p.forecast_week), 0);
    body = (
      <div className="space-y-6">
        <Card>
          <CardHeader title={`Next ${f.weeks} week(s)`} description="Forecast = recent weeks count double; never less than what recurring orders already need. Suggested production covers the forecast plus safety stock, less stock on hand and on QC hold."
            actions={<form className="flex items-center gap-1"><input type="hidden" name="tab" value="forecast" />
              <select name="weeks" defaultValue={String(weeks)} className="h-8 rounded-lg border border-line bg-white px-2 text-sm" aria-label="Weeks">
                {[1, 2, 3, 4, 6, 8].map((w) => <option key={w} value={w}>{w} week{w > 1 ? "s" : ""}</option>)}</select>
              <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Show</button></form>} />
          {f.products.length === 0 ? <EmptyState icon={CalendarClock} title="No sales history yet" /> : (
            <Table>
              <thead><tr><Th>Product</Th><Th>Last 12 weeks</Th><Th className="text-right">Trend</Th><Th className="text-right">Forecast / week</Th>
                <Th className="text-right">Recurring / week</Th><Th className="text-right">Open orders</Th><Th className="text-right">In stock</Th>
                <Th className="text-right">Days of cover</Th><Th className="text-right">Make in {f.weeks} wk</Th></tr></thead>
              <tbody>{f.products.map((p) => (
                <tr key={p.product_id}>
                  <Td className="font-medium">{p.product}<span className="block text-xs text-muted">{p.sku}</span></Td>
                  <Td><Sparkline values={p.history.map(Number)} /></Td>
                  <Td className={`num text-right ${Number(p.trend_pct) < 0 ? "text-red-700" : Number(p.trend_pct) > 0 ? "text-emerald-700" : ""}`}>
                    {p.trend_pct === null ? "—" : `${Number(p.trend_pct) > 0 ? "+" : ""}${p.trend_pct}%`}</Td>
                  <Td className="num text-right font-semibold">{formatQty(p.forecast_week)}</Td>
                  <Td className="num text-right">{formatQty(p.recurring_week)}</Td>
                  <Td className="num text-right">{formatQty(p.open_orders)}</Td>
                  <Td className="num text-right">{formatQty(p.available)}{Number(p.qc_hold) > 0 && <span className="block text-xs text-muted">+{formatQty(p.qc_hold)} QC hold</span>}</Td>
                  <Td className={`num text-right ${p.cover_days !== null && Number(p.cover_days) < 3 ? "font-semibold text-red-700" : ""}`}>{p.cover_days ?? "—"}</Td>
                  <Td className="num text-right font-semibold">{Number(p.suggested_production) > 0 ? formatQty(p.suggested_production) : <span className="text-muted">0</span>}</Td>
                </tr>))}</tbody>
            </Table>)}
        </Card>
        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader title="Busy days" description="Share of units sold on each weekday (last 12 weeks)" />
            <CardBody><ColumnChart data={f.weekday_share.map((d) => ({ day: DAYS[d.dow], share: Number(d.share) }))} x="day" y="share" label="% of units" /></CardBody>
          </Card>
          <Card>
            <CardHeader title="Weekly demand by route" description="Average of the last 12 weeks" />
            <Table>
              <thead><tr><Th>Route</Th><Th className="text-right">Stops / week</Th><Th className="text-right">Units / week</Th></tr></thead>
              <tbody>{f.by_route.map((r) => <tr key={r.route}><Td>{r.route}</Td><Td className="num text-right">{r.stops_week}</Td><Td className="num text-right">{formatQty(r.qty_week)}</Td></tr>)}</tbody>
            </Table>
          </Card>
        </div>
        <p className="text-xs text-muted">Total forecast: {formatQty(total)} units a week. {can(access, "production.manage") && <Link href="/production" className="text-ola-700 hover:underline">Plan production →</Link>}</p>
      </div>
    );
  } else if (tab === "materials") {
    const { data, error } = await supabase.rpc("material_needs", { p_weeks: weeks });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const list = (data ?? []) as Need[];
    body = (
      <Card>
        <CardHeader title={`Materials for ${weeks} week(s) of suggested production`} description="From each product's bill of materials. To buy = needed + reorder level − in stock − already on order." />
        {list.length === 0 ? <EmptyState icon={CalendarClock} title="Nothing to calculate" description="Add bills of materials to products (Materials) and build some sales history." /> : (
          <Table>
            <thead><tr><Th>Material</Th><Th className="text-right">Needed</Th><Th className="text-right">In stock</Th><Th className="text-right">Reorder level</Th>
              <Th className="text-right">On order</Th><Th className="text-right">To buy</Th></tr></thead>
            <tbody>{list.map((m) => (
              <tr key={m.sku}><Td className="font-medium">{m.material}<span className="block text-xs text-muted">{m.sku} · {m.item_type.replace("_", " ")}</span></Td>
                <Td className="num text-right">{formatQty(m.needed)}</Td><Td className="num text-right">{formatQty(m.available)}</Td>
                <Td className="num text-right">{formatQty(m.reorder_level)}</Td><Td className="num text-right">{formatQty(m.on_order)}</Td>
                <Td className="num text-right font-semibold">{Number(m.to_buy) > 0 ? <Badge tone="amber">{formatQty(m.to_buy)}</Badge> : "—"}</Td></tr>))}</tbody>
          </Table>)}
        {can(access, "procurement.manage") && <CardBody><Link href="/purchasing" className={buttonVariants({ variant: "secondary", size: "sm" })}>Create a purchase request</Link></CardBody>}
      </Card>
    );
  } else if (tab === "refill") {
    const { data: routes } = await supabase.from("routes").select("id, name").eq("is_active", true).order("name");
    const days = Math.min(14, Math.max(0, Number(sp.days ?? 2)));
    const { data, error } = await supabase.rpc("refill_due", { p_days: days, p_route: sp.route && /^[0-9a-f-]{36}$/.test(sp.route) ? sp.route : null });
    if (error) return <Alert tone="error">{error.message}</Alert>;
    const list = (data ?? []) as Refill[];
    body = (
      <Card>
        <CardHeader title={`${list.length} customer(s) due for a refill`} description="Customers with at least 3 orders in 6 months whose usual gap says the next order is due, with nothing ordered yet. Customers on recurring orders are left out."
          actions={<form className="flex flex-wrap items-center gap-1"><input type="hidden" name="tab" value="refill" />
            <select name="route" defaultValue={sp.route ?? ""} className="h-8 rounded-lg border border-line bg-white px-2 text-sm" aria-label="Route">
              <option value="">All routes</option>{(routes ?? []).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
            <select name="days" defaultValue={String(days)} className="h-8 rounded-lg border border-line bg-white px-2 text-sm" aria-label="Within">
              {[0, 1, 2, 3, 5, 7].map((d) => <option key={d} value={d}>{d === 0 ? "Due today or late" : `Due within ${d} day(s)`}</option>)}</select>
            <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Show</button></form>} />
        {list.length === 0 ? <EmptyState icon={CalendarClock} title="Nobody is due" /> : (
          <Table>
            <thead><tr><Th>Customer</Th><Th>Route</Th><Th>Last order</Th><Th className="text-right">Usually every</Th><Th>Due</Th>
              <Th className="text-right">Usual qty</Th><Th className="text-right">Owes</Th><Th /></tr></thead>
            <tbody>{list.map((c) => (
              <tr key={c.customer_id}>
                <Td><Link href={`/customers/${c.customer_id}`} className="font-medium text-ola-700 hover:underline">{c.customer}</Link>
                  <span className="block text-xs text-muted">{c.customer_no} · {formatPhone(c.phone)}</span></Td>
                <Td>{c.route ?? "—"}</Td><Td>{formatDate(c.last_date)}</Td><Td className="num text-right">{c.usual_gap_days} days</Td>
                <Td>{formatDate(c.due_date)}{c.days_late > 0 && <Badge tone="amber" className="ml-1">{c.days_late} d late</Badge>}</Td>
                <Td className="num text-right">{c.usual_qty ?? "—"}</Td><Td className="num text-right">{formatLKR(c.outstanding)}</Td>
                <Td className="whitespace-nowrap text-right">
                  <a href={`tel:${c.phone}`} className={buttonVariants({ variant: "ghost", size: "sm" })} aria-label={`Call ${c.customer}`}><Phone className="h-4 w-4" /></a>
                  {can(access, "orders.manage") && <Link href={`/orders/new?customer=${c.customer_id}`} className={buttonVariants({ variant: "secondary", size: "sm" })}>New order</Link>}
                </Td>
              </tr>))}</tbody>
          </Table>)}
      </Card>
    );
  } else {
    const [{ data: routes }, { data: wh }] = await Promise.all([
      supabase.from("routes").select("id, name").eq("is_active", true).order("name"),
      supabase.from("locations").select("id, name, gps_lat, gps_lng").eq("code", "WH1").maybeSingle(),
    ]);
    const routeId = sp.route && (routes ?? []).some((r) => r.id === sp.route) ? sp.route : (routes ?? [])[0]?.id;
    const { data } = routeId ? await supabase.rpc("suggest_route_sequence", { p_route: routeId }) : { data: null };
    const d = data as RouteSug | null;
    const toStop = (x: { customer_id: string; customer: string; customer_no: string; address?: string | null; lat?: number; lng?: number; current_seq: number | null }) =>
      ({ id: x.customer_id, name: x.customer, detail: [x.customer_no, x.address].filter(Boolean).join(" · "), lat: x.lat ?? null, lng: x.lng ?? null, current_seq: x.current_seq });
    body = (
      <div className="space-y-6">
        {wh && (
          <Card>
            <CardHeader title={`Starting point: ${wh.name}`} description={wh.gps_lat ? `GPS ${wh.gps_lat}, ${wh.gps_lng}` : "Not set yet — routes are planned from the first customer until you set it."} />
            <CardBody>{can(access, "routes.manage")
              ? <WarehouseGps locationId={wh.id} lat={wh.gps_lat} lng={wh.gps_lng} action={setWarehouseGps} />
              : <p className="text-sm text-muted">Ask someone who manages routes to set it.</p>}</CardBody>
          </Card>)}
        <Card>
          <CardHeader title="Customer order on each route" description="New runs list their stops in this order. Each run can also be re-ordered on its own page."
            actions={<form className="flex items-center gap-1"><input type="hidden" name="tab" value="routes" />
              <select name="route" defaultValue={routeId} className="h-8 rounded-lg border border-line bg-white px-2 text-sm" aria-label="Route">
                {(routes ?? []).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
              <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Show</button></form>} />
          <CardBody>
            {!d ? <p className="text-sm text-muted">Add a route first (Routes & Vehicles).</p>
              : d.suggested.length + d.no_gps.length === 0 ? <p className="text-sm text-muted">No customers on this route yet.</p> : (
              <OrderPanel start={d.start} current={[...d.suggested].sort((a, b) => (a.current_seq ?? 9999) - (b.current_seq ?? 9999)).map(toStop)}
                suggested={d.suggested.map(toStop)} noGps={d.no_gps.map(toStop)} currentKm={d.current_km} suggestedKm={d.suggested_km}
                closeLoop={!!d.start} canApply={can(access, "routes.manage")} action={applyRouteSequence} hidden={{ route_id: d.route.id }}
                applyLabel="Save this route order" />)}
          </CardBody>
        </Card>
      </div>
    );
  }

  return (
    <>
      <PageHeader title="Planning" description="What to make, what to buy, who to call and the best order to deliver — worked out from your own sales history and GPS locations." />
      <div className="mb-4 flex flex-wrap gap-1">
        {allowed.map(([k, l]) => <Link key={k} href={`/planning?tab=${k}`} className={buttonVariants({ variant: k === tab ? "primary" : "secondary", size: "sm" })}>{l}</Link>)}
      </div>
      {body}
    </>
  );
}
