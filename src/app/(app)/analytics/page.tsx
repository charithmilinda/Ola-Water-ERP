import type { Metadata } from "next";
import Link from "next/link";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatLKR } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Alert } from "@/components/ui/alert";
import { buttonVariants } from "@/components/ui/button";
import { RankChart, TrendChart } from "@/components/charts/charts";

export const metadata: Metadata = { title: "Analytics" };

type M = { month: string; sales: number; last_year: number; collected: number; customers: number; qty_19l: number; delivery_success: number | null;
  complaints: number; expenses: number };
type A = { months: M[]; by_type: { name: string; value: number }[]; by_product: { name: string; value: number }[]; by_route: { name: string; value: number }[];
  top_customers: { id: string; name: string; value: number }[];
  kpis: { avg_invoice: number | null; active_customers: number; repeat_rate: number | null; ola_bottles_out: number } };

export default async function AnalyticsPage({ searchParams }: { searchParams: Promise<{ months?: string }> }) {
  await requirePermission(["reports.view", "accounting.view"]);
  const months = [6, 12, 24].includes(Number((await searchParams).months)) ? Number((await searchParams).months) : 12;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("analytics_overview", { p_months: months });
  if (error) return <Alert tone="error">{error.message}</Alert>;
  const a = data as A;
  const ms = a.months.map((m) => ({ ...m, sales: Number(m.sales), last_year: Number(m.last_year), collected: Number(m.collected), expenses: Number(m.expenses),
    qty_19l: Number(m.qty_19l), customers: Number(m.customers), delivery_success: m.delivery_success === null ? null : Number(m.delivery_success), complaints: Number(m.complaints) }));
  const thisTotal = ms.reduce((s, m) => s + m.sales, 0);
  const lastTotal = ms.reduce((s, m) => s + m.last_year, 0);
  const growth = lastTotal > 0 ? Math.round(((thisTotal - lastTotal) / lastTotal) * 1000) / 10 : null;
  const num = (rows: { name: string; value: number }[]) => rows.map((r) => ({ name: r.name, value: Number(r.value) }));

  return (
    <>
      <PageHeader title="Analytics" description="Trends over time. Sales are before VAT, by invoice date."
        actions={<div className="flex gap-1">{[6, 12, 24].map((m) => (
          <Link key={m} href={`/analytics?months=${m}`} className={buttonVariants({ variant: m === months ? "primary" : "secondary", size: "sm" })}>{m} months</Link>))}</div>} />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label={`Sales, last ${months} months`} value={formatLKR(thisTotal)} hint={growth === null ? "No sales a year earlier to compare" : `${growth > 0 ? "+" : ""}${growth}% on a year earlier`} />
        <Stat label="Average invoice" value={formatLKR(a.kpis.avg_invoice)} />
        <Stat label="Customers who bought (90 days)" value={Number(a.kpis.active_customers).toLocaleString("en-LK")}
          hint={a.kpis.repeat_rate !== null ? `${a.kpis.repeat_rate}% bought more than once` : undefined} />
        <Stat label="OLA bottles with customers" value={Number(a.kpis.ola_bottles_out).toLocaleString("en-LK")} />
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card className="lg:col-span-2">
          <CardHeader title="Sales — this year against last year" />
          <CardBody><TrendChart data={ms} x="month" series={[{ key: "sales", label: "Sales" }, { key: "last_year", label: "A year earlier", dashed: true }]} /></CardBody>
        </Card>
        <Card>
          <CardHeader title="Sales, cash collected and expenses" />
          <CardBody><TrendChart data={ms} x="month" series={[{ key: "sales", label: "Sales" }, { key: "collected", label: "Collected" }, { key: "expenses", label: "Expenses" }]} height={240} /></CardBody>
        </Card>
        <Card>
          <CardHeader title="19L bottles sold and customers served" />
          <CardBody><TrendChart data={ms} x="month" money={false} series={[{ key: "qty_19l", label: "19L sold" }, { key: "customers", label: "Customers" }]} height={240} /></CardBody>
        </Card>
        <Card>
          <CardHeader title="Delivery success" description="Delivered or part delivered, of all attempted stops" />
          <CardBody><TrendChart data={ms} x="month" money={false} unit="%" series={[{ key: "delivery_success", label: "Success %" }]} height={220} /></CardBody>
        </Card>
        <Card>
          <CardHeader title="Complaints logged" />
          <CardBody><TrendChart data={ms} x="month" money={false} series={[{ key: "complaints", label: "Complaints" }]} height={220} /></CardBody>
        </Card>
        <Card>
          <CardHeader title="Sales by customer type" />
          <CardBody><RankChart data={num(a.by_type)} /></CardBody>
        </Card>
        <Card>
          <CardHeader title="Sales by product" />
          <CardBody><RankChart data={num(a.by_product)} /></CardBody>
        </Card>
        <Card>
          <CardHeader title="Sales by route" description="Customers' routes (top 12)" />
          <CardBody><RankChart data={num(a.by_route)} /></CardBody>
        </Card>
        <Card>
          <CardHeader title="Top 10 customers" actions={<Link href="/reports/sales-by-customer" className="text-sm font-medium text-ola-700 hover:underline">All customers</Link>} />
          <CardBody><RankChart data={num(a.top_customers)} /></CardBody>
        </Card>
      </div>
    </>
  );
}
