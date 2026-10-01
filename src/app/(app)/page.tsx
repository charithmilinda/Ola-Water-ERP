import Link from "next/link";
import { redirect } from "next/navigation";
import { AlertTriangle, ArrowRight } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatLKR, formatDate } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Alert } from "@/components/ui/alert";
import { Welcome } from "./welcome";

type Dash = {
  today: string;
  sales_today: number;
  invoices_today: number;
  collected_today: number;
  orders_today: number;
  orders_on_hold: number;
  orders_to_dispatch: number;
  deliveries: { total: number; completed: number; failed: number; pending: number };
  runs_out: number;
  customer_outstanding: number;
  overdue: number;
  bottles: { warehouse_full: number; warehouse_empty: number; on_vehicles: number; with_customers: number; external_held: number; external_on_vehicles: number };
  exceptions: { critical: number; warning: number; info: number };
  external_alerts: { company: string; held: number; limit: number }[];
  sales_14d: { date: string; sales: number; deliveries: number }[];
};

const n = (v: number) => Number(v).toLocaleString("en-LK");

export default async function DashboardPage() {
  const access = await getAccess();
  if (!can(access, "dashboard.view")) {
    // drivers go straight to their app
    if (access.permissions.includes("driver.app") && access.permissions.length <= 2) redirect("/driver");
    return <Welcome />;
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("dashboard_summary");
  if (error) return <Alert tone="error">{error.message}</Alert>;
  const d = data as Dash;
  const max = Math.max(1, ...d.sales_14d.map((x) => Number(x.sales)));

  const alerts: { tone: "error" | "warning"; text: string; href: string }[] = [];
  if (d.exceptions.critical > 0) alerts.push({ tone: "error", text: `${d.exceptions.critical} critical exception(s) — missing bottles, stock or cash`, href: "/exceptions" });
  if (d.orders_on_hold > 0) alerts.push({ tone: "warning", text: `${d.orders_on_hold} order(s) on hold for credit or bottle limits`, href: "/orders?status=on_hold" });
  if (d.deliveries.failed > 0) alerts.push({ tone: "warning", text: `${d.deliveries.failed} failed delivery(ies) today`, href: "/dispatch" });
  d.external_alerts.forEach((a) =>
    alerts.push({ tone: "warning", text: `${a.company}: ${a.held} bottles held (alert at ${a.limit}) — arrange a hand-over`, href: "/bottles/external" }),
  );
  if (d.bottles.warehouse_empty < 0 || d.bottles.warehouse_full < 0)
    alerts.push({ tone: "warning", text: "Warehouse bottle count is negative — enter opening bottle balances", href: "/bottles" });

  return (
    <>
      <PageHeader title="Dashboard" description={`Today, ${formatDate(d.today)}`} />

      {alerts.length > 0 && (
        <div className="mb-6 space-y-2">
          {alerts.map((a, i) => (
            <Link key={i} href={a.href} className="block">
              <Alert tone={a.tone}>
                <span className="flex items-center gap-2">
                  {a.text} <ArrowRight className="h-3.5 w-3.5" />
                </span>
              </Alert>
            </Link>
          ))}
        </div>
      )}

      <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Stat label="Sales today" value={formatLKR(d.sales_today)} hint={`${d.invoices_today} invoice(s), incl. VAT, excl. deposits`} />
        <Stat label="Collected today" value={formatLKR(d.collected_today)} hint="All payment methods" />
        <Stat label="Deliveries today" value={`${n(d.deliveries.completed)} / ${n(d.deliveries.total)}`} hint={`${d.deliveries.pending} pending · ${d.deliveries.failed} failed · ${d.runs_out} vehicle(s) out`} />
        <Stat label="Orders to dispatch" value={n(d.orders_to_dispatch)} hint={`${d.orders_today} new today · ${d.orders_on_hold} on hold`} />
        <Stat label="Customers owe" value={formatLKR(d.customer_outstanding)} hint={`${formatLKR(d.overdue)} overdue`} />
        <Stat label="Warehouse bottles" value={`${n(d.bottles.warehouse_full)} full`} hint={`${n(d.bottles.warehouse_empty)} empty · ${n(d.bottles.on_vehicles)} on vehicles`} />
        <Stat label="OLA bottles with customers" value={n(d.bottles.with_customers)} hint="Loaned or under deposit" />
        <Stat label="External bottles held" value={n(d.bottles.external_held)} hint={`${n(d.bottles.external_on_vehicles)} more on vehicles`} />
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title="Sales — last 14 days" description="Invoiced value incl. VAT" />
          <CardBody>
            <div className="flex h-48 items-end gap-1.5" role="img" aria-label="Daily sales for the last 14 days">
              {d.sales_14d.map((x) => (
                <div key={x.date} className="group flex flex-1 flex-col items-center gap-1">
                  <div className="relative flex w-full flex-1 items-end">
                    <div
                      className="w-full rounded-t bg-ola-500 transition-colors group-hover:bg-ola-700"
                      style={{ height: `${(Number(x.sales) / max) * 100}%`, minHeight: Number(x.sales) > 0 ? 3 : 0 }}
                      title={`${formatDate(x.date)}: ${formatLKR(x.sales)} · ${x.deliveries} deliveries`}
                    />
                  </div>
                  <span className="text-[10px] text-muted">{x.date.slice(8)}</span>
                </div>
              ))}
            </div>
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="Open exceptions" />
          <CardBody className="space-y-3 text-sm">
            <Row label="Critical" value={d.exceptions.critical} tone="text-red-700" />
            <Row label="Warnings" value={d.exceptions.warning} tone="text-amber-700" />
            <Row label="For information" value={d.exceptions.info} tone="text-ola-700" />
            <Link href="/exceptions" className="inline-flex items-center gap-1 pt-2 font-medium text-ola-700 hover:underline">
              Review exceptions <ArrowRight className="h-4 w-4" />
            </Link>
            {d.exceptions.critical + d.exceptions.warning === 0 && (
              <p className="flex items-center gap-2 text-muted">
                <AlertTriangle className="h-4 w-4" /> Nothing needs attention.
              </p>
            )}
          </CardBody>
        </Card>
      </div>
    </>
  );
}

function Row({ label, value, tone }: { label: string; value: number; tone: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-muted">{label}</span>
      <span className={`num text-lg font-semibold ${value > 0 ? tone : "text-navy-900"}`}>{value}</span>
    </div>
  );
}
