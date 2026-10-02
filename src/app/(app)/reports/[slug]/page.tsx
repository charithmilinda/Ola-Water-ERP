import type { Metadata } from "next";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ArrowLeft, Download } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatDateTime, formatLKR, formatQty, humanize, todayISO } from "@/lib/format";
import { CUSTOMER_TYPES } from "@/lib/labels";
import { GROUP_PERMISSIONS, reportBySlug, reportFilters, type Col, type Row } from "@/lib/report-catalog";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Alert } from "@/components/ui/alert";
import { EmptyState } from "@/components/ui/empty-state";
import { Input } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { PrintButton } from "../../accounting/reports/[report]/print-button";

export const metadata: Metadata = { title: "Report" };

const RIGHT = new Set(["money", "qty", "int", "pct"]);

function cell(c: Col, v: unknown) {
  if (v === null || v === undefined || v === "") return <span className="text-muted">—</span>;
  switch (c.kind) {
    case "money": return formatLKR(Number(v));
    case "qty": return formatQty(Number(v));
    case "int": return Number(v).toLocaleString("en-LK");
    case "pct": return `${Number(v).toLocaleString("en-LK", { maximumFractionDigits: 1 })}%`;
    case "date": return formatDate(String(v));
    case "datetime": return formatDateTime(String(v));
    default: return /^[a-z]+(_[a-z]+)+$/.test(String(v)) ? humanize(String(v)) : String(v);
  }
}

const sel = "h-9 rounded-lg border border-line bg-white px-2 text-sm";

export default async function ReportPage({ params, searchParams }: { params: Promise<{ slug: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const access = await getAccess();
  const { slug } = await params;
  const def = reportBySlug(slug);
  if (!def) notFound();
  if (!can(access, GROUP_PERMISSIONS[def.group])) redirect("/forbidden");
  const sp = await searchParams;
  const today = todayISO();
  const f = reportFilters(sp);
  const period = def.filters.includes("period");
  if (period) {
    f.to = f.to && /^\d{4}-\d{2}-\d{2}$/.test(f.to) ? f.to : today;
    f.from = f.from && /^\d{4}-\d{2}-\d{2}$/.test(f.from) ? f.from
      : def.slug === "sales-monthly" ? `${Number(f.to.slice(0, 4)) - 1}${f.to.slice(4, 8)}01` : `${f.to.slice(0, 8)}01`;
  }
  const supabase = await createClient();
  const has = (x: string) => def.filters.includes(x as never);
  const [{ data, error }, locations, products, companies, routes] = await Promise.all([
    def.filters.includes("company_required") && !f.company_id ? Promise.resolve({ data: [], error: null }) : supabase.rpc("run_report", { p_report: def.slug, p: f }),
    has("location") ? supabase.from("locations").select("id, name").eq("is_active", true).neq("location_type", "virtual").order("name") : Promise.resolve({ data: null }),
    has("product") ? supabase.from("products").select("id, name").eq("is_active", true).order("sort_order") : Promise.resolve({ data: null }),
    has("company") || has("company_required") ? supabase.from("bottle_companies").select("id, name, is_own").eq("is_active", true).order("is_own", { ascending: false }) : Promise.resolve({ data: null }),
    has("route") ? supabase.from("routes").select("id, name").eq("is_active", true).order("name") : Promise.resolve({ data: null }),
  ]);
  const rows = (data ?? []) as Row[];
  const totals = def.columns.filter((c) => c.total && c.kind && RIGHT.has(c.kind));
  const sum = (k: string) => rows.reduce((a, r) => a + (Number(r[k]) || 0), 0);
  const qs = new URLSearchParams(f).toString();
  const chart = def.chart && rows.length > 1 ? rows.map((r) => ({ label: String(r[def.chart!.label]), value: Number(r[def.chart!.value]) || 0 })) : null;
  const max = chart ? Math.max(1, ...chart.map((x) => x.value)) : 1;

  return (
    <>
      <Link href="/reports" className="no-print mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Reports</Link>
      <PageHeader title={def.title}
        description={`${def.description}${period ? ` · ${formatDate(f.from)} – ${formatDate(f.to)}` : ` · as at ${formatDate(today)}`}`}
        actions={<div className="no-print flex flex-wrap gap-2">
          <PrintButton />
          {can(access, "reports.export") && <a href={`/reports/${def.slug}/export?${qs}`} className={buttonVariants({ variant: "secondary", size: "md" })}><Download className="h-4 w-4" /> Excel (CSV)</a>}
        </div>} />

      {def.filters.length > 0 && (
        <form className="no-print mb-4 flex flex-wrap items-end gap-2 rounded-xl border border-line bg-white p-3">
          {period && <>
            <label className="text-xs text-muted">From<Input type="date" name="from" defaultValue={f.from} max={today} className="mt-1 h-9 w-40" /></label>
            <label className="text-xs text-muted">To<Input type="date" name="to" defaultValue={f.to} className="mt-1 h-9 w-40" /></label>
          </>}
          {has("days") && <label className="text-xs text-muted">No invoice for (days)<Input type="number" name="days" min={1} max={730} defaultValue={f.days ?? "30"} className="mt-1 h-9 w-28" /></label>}
          {has("expiry_days") && <label className="text-xs text-muted">Expiring within (days)<Input type="number" name="days" min={1} max={730} defaultValue={f.days ?? "60"} className="mt-1 h-9 w-28" /></label>}
          {has("location") && <label className="text-xs text-muted">Location<select name="location_id" defaultValue={f.location_id ?? ""} className={`mt-1 block ${sel}`}>
            <option value="">All</option>{(locations.data ?? []).map((l: { id: string; name: string }) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></label>}
          {has("customer_type") && <label className="text-xs text-muted">Customer type<select name="customer_type" defaultValue={f.customer_type ?? ""} className={`mt-1 block ${sel}`}>
            <option value="">All</option>{CUSTOMER_TYPES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>}
          {has("product") && <label className="text-xs text-muted">Item<select name="product_id" defaultValue={f.product_id ?? ""} className={`mt-1 block ${sel}`}>
            <option value="">All</option>{(products.data ?? []).map((p: { id: string; name: string }) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>}
          {(has("company") || has("company_required")) && <label className="text-xs text-muted">Company<select name="company_id" defaultValue={f.company_id ?? ""} className={`mt-1 block ${sel}`}>
            {has("company") && <option value="">{def.slug === "bottle-external" || def.slug === "bottle-losses" || def.slug === "bottle-holders" ? "All" : "OLA"}</option>}
            {(companies.data ?? []).filter((c: { is_own: boolean }) => !has("company_required") || !c.is_own).map((c: { id: string; name: string }) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>}
          {has("route") && <label className="text-xs text-muted">Route<select name="route_id" defaultValue={f.route_id ?? ""} className={`mt-1 block ${sel}`}>
            <option value="">All</option>{(routes.data ?? []).map((r: { id: string; name: string }) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></label>}
          <button className={buttonVariants({ variant: "primary", size: "sm" })}>Show</button>
        </form>
      )}

      {error && <Alert tone="error" className="mb-4">{error.message}</Alert>}
      {def.filters.includes("company_required") && !f.company_id && <Alert tone="info" className="mb-4">Choose the company and press Show.</Alert>}

      {chart && (
        <Card className="mb-6">
          <CardBody>
            <div className="flex h-36 items-end gap-1" role="img" aria-label={`${def.title} chart`}>
              {chart.map((x) => (
                <div key={x.label} className="group flex flex-1 flex-col items-center justify-end" title={`${x.label}: ${x.value.toLocaleString("en-LK")}`}>
                  <div className="w-full rounded-t bg-ola-500/80 group-hover:bg-ola-600" style={{ height: `${Math.max(2, (x.value / max) * 100)}%` }} />
                </div>
              ))}
            </div>
            <div className="mt-1 flex justify-between text-[11px] text-muted"><span>{chart[0].label}</span><span>{chart[chart.length - 1].label}</span></div>
          </CardBody>
        </Card>
      )}

      <Card>
        <CardHeader title={`${rows.length.toLocaleString("en-LK")} row(s)`} />
        {rows.length === 0 ? <EmptyState icon={Download} title="Nothing for these filters" /> : (
          <Table>
            <thead><tr>{def.columns.map((c) => <Th key={c.key} className={c.kind && RIGHT.has(c.kind) ? "text-right" : ""}>{c.label}</Th>)}</tr></thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i}>{def.columns.map((c) => {
                  const href = c.href?.(r);
                  const v = cell(c, r[c.key]);
                  return <Td key={c.key} className={c.kind && RIGHT.has(c.kind) ? "num text-right" : ""}>
                    {href ? <Link href={href} className="text-ola-700 hover:underline">{v}</Link> : v}</Td>;
                })}</tr>
              ))}
              {totals.length > 0 && rows.length > 1 && (
                <tr className="bg-surface/60 font-semibold">{def.columns.map((c, i) => (
                  <Td key={c.key} className={c.kind && RIGHT.has(c.kind) ? "num text-right" : ""}>
                    {i === 0 ? "Total" : totals.includes(c) ? cell(c, sum(c.key)) : ""}</Td>))}</tr>
              )}
            </tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
