import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR } from "@/lib/format";
import { DELIVERY_STATUS, RUN_STATUS, SEVERITY, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { LoadForm, CheckinForm } from "./run-forms";

export const metadata: Metadata = { title: "Run" };

export default async function RunPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["deliveries.view", "deliveries.manage"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data: r } = await supabase.from("route_runs").select("*, route:routes(name), vehicle:vehicles(registration_no, location_id), driver:profiles!route_runs_driver_id_fkey(full_name, phone)").eq("id", id).maybeSingle();
  if (!r) notFound();
  const vehLoc = (r.vehicle as { location_id: string }).location_id;
  const [{ data: stops }, { data: suggested }, { data: products }, { data: stock }, { data: vstock }, { data: vbottles }, { data: companies }, { data: types }, { data: cashPay }, { data: exceptions }] = await Promise.all([
    supabase.from("deliveries").select("id, delivery_no, stop_sequence, status, failure_reason, completed_at, invoice_id, summary, customer:customers(id, name, phone)").eq("run_id", id).order("stop_sequence"),
    r.status === "planned" ? supabase.rpc("run_suggested_load", { p_run: id }) : Promise.resolve({ data: [] }),
    supabase.from("products").select("id, name").eq("is_active", true).eq("item_type", "finished_good").order("sort_order"),
    supabase.from("inventory_balances").select("product_id, qty").eq("location_id", r.load_location_id).eq("stock_status", "available"),
    supabase.from("inventory_balances").select("product_id, qty").eq("location_id", vehLoc).eq("stock_status", "available").gt("qty", 0),
    supabase.from("bottle_balances").select("company_id, bottle_type_id, fill_state, qty").eq("holder_type", "location").eq("holder_id", vehLoc).neq("qty", 0),
    supabase.from("bottle_companies").select("id, name, is_own"),
    supabase.from("bottle_types").select("id, name"),
    supabase.from("payments").select("amount").eq("run_id", id).eq("method", "cash").eq("status", "received"),
    supabase.from("operation_exceptions").select("id, exception_type, severity, status, description, resolution, resolution_note").eq("run_id", id).order("created_at"),
  ]);
  const b = statusBadge(RUN_STATUS, r.status);
  const co = Object.fromEntries((companies ?? []).map((c) => [c.id, c]));
  const ty = Object.fromEntries((types ?? []).map((t) => [t.id, t.name]));
  const prodName = Object.fromEntries((products ?? []).map((p) => [p.id, p.name]));
  const cashCollected = (cashPay ?? []).reduce((a, p) => a + Number(p.amount), 0);
  const manageStock = can(access, ["inventory.manage", "deliveries.manage"]);
  type Stop = { id: string; delivery_no: string; stop_sequence: number; status: string; failure_reason: string | null; completed_at: string | null; invoice_id: string | null;
    summary: { total?: number; paid?: number; bottles?: { returned?: Record<string, number>; external?: { company: string; qty: number }[] } } | null; customer: { id: string; name: string; phone: string } | null };
  const stopList = (stops ?? []) as unknown as Stop[];
  const sales = stopList.reduce((a, s) => a + Number(s.summary?.total ?? 0), 0);

  return (
    <>
      <Link href="/dispatch" className="mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> All runs</Link>
      <PageHeader title={r.run_no}
        description={`${formatDate(r.run_date)} · ${(r.route as { name: string } | null)?.name ?? "No route"} · ${(r.vehicle as { registration_no: string }).registration_no} · ${(r.driver as { full_name: string }).full_name}${r.helper_name ? ` + ${r.helper_name}` : ""}`}
        actions={<Badge tone={b.tone} className="self-center">{b.label}</Badge>} />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Stat label="Stops" value={`${stopList.filter((s) => ["delivered", "partially_delivered", "failed"].includes(s.status)).length} / ${stopList.filter((s) => s.status !== "cancelled").length}`} hint={`${stopList.filter((s) => s.status === "failed").length} failed`} />
        <Stat label="Invoiced on this run" value={formatLKR(sales)} />
        <Stat label="Cash with driver" value={formatLKR(Number(r.cash_float) + cashCollected)} hint={`Float ${formatLKR(r.cash_float)} + collected ${formatLKR(cashCollected)}`} />
        <Stat label="Loaded" value={r.loaded_at ? formatDateTime(r.loaded_at) : "Not yet"} hint={r.driver_confirmed_at ? `Driver confirmed ${formatDateTime(r.driver_confirmed_at)}` : "Driver has not confirmed"} />
      </div>

      {r.status === "planned" && manageStock && (
        <Card className="mb-6">
          <CardHeader title="Load-out" description="Warehouse: confirm what goes onto the vehicle. The driver then confirms on their phone." />
          <CardBody>
            <LoadForm runId={id} suggested={(suggested ?? []) as { product_id: string; product_name: string; qty: number; available: number }[]}
              products={(products ?? []).map((p) => ({ id: p.id, name: p.name, available: Number(stock?.find((s) => s.product_id === p.id)?.qty ?? 0) }))} />
          </CardBody>
        </Card>
      )}

      {["loaded", "in_progress"].includes(r.status) && manageStock && (
        <Card className="mb-6">
          <CardHeader title="Check-in" description={r.status === "loaded" ? "The run has not started — checking in returns everything and puts the orders back." : "When the vehicle returns, count everything coming off it."} />
          <CardBody>
            {stopList.some((s) => s.status === "pending") && r.status === "in_progress" ? (
              <Alert tone="info">{stopList.filter((s) => s.status === "pending").length} stop(s) are still pending. The driver must complete or fail every stop before check-in.</Alert>
            ) : (
              <CheckinForm runId={id} cashExpected={Number(r.cash_float) + cashCollected}
                products={(vstock ?? []).map((s) => ({ product_id: s.product_id, name: prodName[s.product_id] ?? "Product", qty: Number(s.qty) }))}
                bottles={(vbottles ?? []).filter((x) => !(co[x.company_id]?.is_own && x.fill_state === "full")).map((x) => ({
                  company_id: x.company_id, company: co[x.company_id]?.name ?? "", bottle_type_id: x.bottle_type_id, type: ty[x.bottle_type_id] ?? "", fill_state: x.fill_state, qty: x.qty }))} />
            )}
          </CardBody>
        </Card>
      )}

      {r.checked_in_at && (
        <Alert tone={r.status === "closed" ? "success" : "warning"} className="mb-6">
          Checked in {formatDateTime(r.checked_in_at)} · cash expected {formatLKR(r.cash_expected)}, handed in {formatLKR(r.cash_handed)}.
          {r.status === "checked_in" && " Resolve the differences below to close the run."}
        </Alert>
      )}

      {(exceptions ?? []).length > 0 && (
        <Card className="mb-6">
          <CardHeader title="Differences & exceptions" actions={<Link href="/exceptions" className="text-sm font-medium text-ola-700 hover:underline">Resolve</Link>} />
          <ul className="divide-y divide-line">
            {exceptions?.map((e) => {
              const s = statusBadge(SEVERITY, e.severity);
              return (
                <li key={e.id} className="flex flex-wrap items-center justify-between gap-2 px-5 py-3 text-sm">
                  <span><Badge tone={s.tone} className="mr-2">{s.label}</Badge>{e.description}</span>
                  {e.status === "resolved" ? <Badge tone="green">Resolved: {e.resolution?.replace("_", " ")}</Badge> : <Badge tone="amber">Open</Badge>}
                </li>
              );
            })}
          </ul>
        </Card>
      )}

      <Card>
        <CardHeader title="Stops" />
        <Table>
          <thead><tr><Th>#</Th><Th>Customer</Th><Th>Status</Th><Th>Bottles back</Th><Th className="text-right">Invoiced</Th><Th className="text-right">Paid</Th></tr></thead>
          <tbody>
            {stopList.map((s) => {
              const sb = statusBadge(DELIVERY_STATUS, s.status);
              const returned = Object.values(s.summary?.bottles?.returned ?? {}).reduce((a, n) => a + Number(n), 0);
              const ext = (s.summary?.bottles?.external ?? []).map((e) => `${e.qty} ${e.company}`).join(", ");
              return (
                <tr key={s.id}>
                  <Td className="num">{s.stop_sequence}</Td>
                  <Td><Link href={`/customers/${s.customer?.id}`} className="font-medium text-ola-700 hover:underline">{s.customer?.name}</Link><span className="block text-xs text-muted">{s.delivery_no}</span></Td>
                  <Td><Badge tone={sb.tone}>{sb.label}</Badge>{s.failure_reason && <span className="block text-xs text-red-700">{s.failure_reason}</span>}{s.completed_at && <span className="block text-xs text-muted">{formatDateTime(s.completed_at)}</span>}</Td>
                  <Td>{s.summary ? `${returned} OLA${ext ? ` · ${ext}` : ""}` : "—"}</Td>
                  <Td className="num text-right">{s.invoice_id ? <a href={`/print/receipt/${s.invoice_id}`} target="_blank" rel="noopener" className="text-ola-700 hover:underline">{formatLKR(s.summary?.total ?? 0)}</a> : "—"}</Td>
                  <Td className="num text-right">{s.summary?.paid ? formatLKR(s.summary.paid) : "—"}</Td>
                </tr>
              );
            })}
          </tbody>
        </Table>
      </Card>
    </>
  );
}
