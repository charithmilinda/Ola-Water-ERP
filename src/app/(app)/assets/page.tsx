import type { Metadata } from "next";
import Link from "next/link";
import { Cog, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { registerAsset, runDepreciation, saveAssetCategory } from "./actions";
import { FundingFields } from "./funding-fields";

export const metadata: Metadata = { title: "Fixed Assets" };

type Row = { id: string; asset_no: string; name: string; category: string; serial_no: string | null; location: string | null; responsible: string | null;
  purchase_date: string; cost: number; accumulated: number; book_value: number; status: string; warranty_until: string | null; vehicle: string | null;
  last_depreciation: string | null };

export default async function AssetsPage() {
  const access = await requirePermission(["assets.manage", "accounting.view"]);
  const supabase = await createClient();
  const [{ data }, { data: cats }, { data: locations }, { data: staff }, { data: money }, { data: vehicles }, { data: runs }, { data: faAccounts }] = await Promise.all([
    supabase.rpc("asset_register"),
    supabase.from("asset_categories").select("id, code, name, method, useful_life_months, rate_percent, residual_percent").eq("is_active", true).order("name"),
    supabase.from("locations").select("id, name").eq("is_active", true).neq("location_type", "virtual").order("name"),
    supabase.rpc("employee_directory"),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).in("kind", ["bank", "cash", "petty_cash"]).order("is_default", { ascending: false }),
    supabase.from("vehicles").select("id, registration_no, asset_id").eq("is_active", true).is("asset_id", null).order("registration_no"),
    supabase.from("depreciation_runs").select("id, run_no, dep_year, dep_month, assets, total").order("dep_year", { ascending: false }).order("dep_month", { ascending: false }).limit(12),
    supabase.from("accounts").select("id, code, name").eq("account_type", "asset").like("code", "16%").eq("is_postable", true).order("code"),
  ]);
  const rows = (data ?? []) as Row[];
  const active = rows.filter((r) => r.status === "active");
  const manage = can(access, "assets.manage");
  const today = todayISO();
  const totals = active.reduce((a, r) => ({ cost: a.cost + Number(r.cost), acc: a.acc + Number(r.accumulated) }), { cost: 0, acc: 0 });
  const lastMonth = (() => { const d = new Date(`${today.slice(0, 7)}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 1); return d.toISOString().slice(0, 7); })();
  const people = ((staff ?? []) as { id: string; full_name: string; status: string }[]).filter((s) => s.status === "active");

  return (
    <>
      <PageHeader title="Fixed Assets" description="RO plants, filling machines, generators, vehicles, computers and furniture: what they cost, their depreciation and book value."
        actions={manage && <>
          <FormDialog trigger="Asset categories" triggerSize="md" title="New asset category" submitLabel="Add category" action={saveAssetCategory}>
            <p className="text-sm text-muted">{cats?.map((c) => c.name).join(" · ")}</p>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Code" htmlFor="ac-c" required><Input id="ac-c" name="code" required placeholder="TOOLS" /></Field>
              <Field label="Name" htmlFor="ac-n" required className="sm:col-span-2"><Input id="ac-n" name="name" required /></Field>
              <Field label="Ledger account" htmlFor="ac-a" className="sm:col-span-3"><Select id="ac-a" name="asset_account_id">
                {faAccounts?.filter((a) => a.code !== "1690").map((a) => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</Select></Field>
              <Field label="Method" htmlFor="ac-m"><Select id="ac-m" name="method"><option value="straight_line">Straight line</option><option value="reducing_balance">Reducing balance</option></Select></Field>
              <Field label="Life (years)" htmlFor="ac-l" hint="Straight line"><Input id="ac-l" name="life_years" type="number" min={1} step="0.5" /></Field>
              <Field label="Rate (% a year)" htmlFor="ac-r" hint="Reducing balance"><Input id="ac-r" name="rate_percent" type="number" min={1} max={100} step="0.01" /></Field>
              <Field label="Residual (%)" htmlFor="ac-rv"><Input id="ac-rv" name="residual_percent" type="number" min={0} max={90} step="0.01" defaultValue={0} /></Field>
            </div>
          </FormDialog>
          <FormDialog trigger="Run depreciation" triggerSize="md" title="Monthly depreciation" description="Run once a month, in order. It posts Depreciation / Accumulated Depreciation."
            submitLabel="Run" action={runDepreciation}>
            <Field label="Month" htmlFor="dr-m" required><Input id="dr-m" name="month" type="month" defaultValue={lastMonth} max={today.slice(0, 7)} required /></Field>
            {runs?.[0] && <p className="text-sm text-muted">Last run: {runs[0].run_no} ({runs[0].dep_year}-{String(runs[0].dep_month).padStart(2, "0")}, {formatLKR(runs[0].total)})</p>}
          </FormDialog>
          <FormDialog trigger={<><Plus className="h-4 w-4" /> Register asset</>} triggerVariant="primary" triggerSize="md" title="Register a fixed asset" submitLabel="Register"
            action={registerAsset} wide>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Name" htmlFor="ra-n" required className="sm:col-span-2"><Input id="ra-n" name="name" required placeholder="RO plant 2,000 L/h" /></Field>
              <Field label="Category" htmlFor="ra-c"><Select id="ra-c" name="category_id">{cats?.map((c) => <option key={c.id} value={c.id}>{c.name}
                {c.method === "straight_line" ? ` (${Number(c.useful_life_months) / 12} yrs)` : ` (${c.rate_percent}%)`}</option>)}</Select></Field>
              <Field label="Serial no." htmlFor="ra-s"><Input id="ra-s" name="serial_no" /></Field>
              <Field label="Supplier" htmlFor="ra-su"><Input id="ra-su" name="supplier_name" /></Field>
              <Field label="Warranty until" htmlFor="ra-w"><Input id="ra-w" name="warranty_until" type="date" /></Field>
              <Field label="Location" htmlFor="ra-l"><Select id="ra-l" name="location_id"><option value="">—</option>{locations?.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
              <Field label="Responsible person" htmlFor="ra-r"><Select id="ra-r" name="responsible_employee_id"><option value="">—</option>{people.map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}</Select></Field>
              <Field label="Is this vehicle" htmlFor="ra-v" hint="Links fleet costs to the asset"><Select id="ra-v" name="vehicle_id"><option value="">Not a vehicle</option>
                {vehicles?.map((v) => <option key={v.id} value={v.id}>{v.registration_no}</option>)}</Select></Field>
              <Field label="Bought on" htmlFor="ra-d" required><Input id="ra-d" name="purchase_date" type="date" max={today} required /></Field>
              <Field label="Cost (Rs., before VAT)" htmlFor="ra-co" required><Input id="ra-co" name="cost" type="number" min={1} step="0.01" required /></Field>
              <Field label="Residual value (Rs.)" htmlFor="ra-rv" hint="Blank = category %"><Input id="ra-rv" name="residual_value" type="number" min={0} step="0.01" /></Field>
              <Field label="Useful life (years)" htmlFor="ra-ul" hint="Blank = category"><Input id="ra-ul" name="useful_life_years" type="number" min={1} step="0.5" /></Field>
            </div>
            <FundingFields money={money ?? []} />
            <Field label="Description" htmlFor="ra-de"><Textarea id="ra-de" name="description" /></Field>
          </FormDialog>
        </>} />

      <div className="mb-6 grid gap-4 sm:grid-cols-3">
        <Stat label="Assets in use" value={active.length} />
        <Stat label="Cost" value={formatLKR(totals.cost)} hint={`Accumulated depreciation ${formatLKR(totals.acc)}`} />
        <Stat label="Book value" value={formatLKR(totals.cost - totals.acc)} hint={runs?.[0] ? `Depreciated up to ${runs[0].dep_year}-${String(runs[0].dep_month).padStart(2, "0")}` : "Depreciation not run yet"} />
      </div>

      <Card>
        <CardHeader title="Asset register" />
        {rows.length === 0 ? <EmptyState icon={Cog} title="No assets registered" description={manage ? "Register your RO plant, machines, vehicles and equipment." : undefined} /> : (
          <Table>
            <thead><tr><Th>Asset</Th><Th>Category</Th><Th>Where / who</Th><Th>Bought</Th><Th className="text-right">Cost</Th><Th className="text-right">Depreciation</Th>
              <Th className="text-right">Book value</Th></tr></thead>
            <tbody>{rows.map((a) => (
              <tr key={a.id} className={a.status === "active" ? "hover:bg-ola-50/40" : "opacity-50"}>
                <Td><Link href={`/assets/${a.id}`} className="font-medium text-ola-700 hover:underline">{a.name}</Link>
                  <span className="block text-xs text-muted">{a.asset_no}{a.serial_no && ` · ${a.serial_no}`}{a.vehicle && ` · ${a.vehicle}`}</span>
                  {a.status !== "active" && <Badge tone="neutral" className="mt-1">Disposed</Badge>}</Td>
                <Td>{a.category}</Td><Td>{a.location ?? "—"}<span className="block text-xs text-muted">{a.responsible}</span></Td>
                <Td className="whitespace-nowrap">{formatDate(a.purchase_date)}{a.warranty_until && <span className={`block text-xs ${a.warranty_until < today ? "text-muted" : "text-emerald-700"}`}>Warranty {formatDate(a.warranty_until)}</span>}</Td>
                <Td className="num text-right">{formatLKR(a.cost)}</Td><Td className="num text-right">{formatLKR(a.accumulated)}</Td>
                <Td className="num text-right font-medium">{a.status === "active" ? formatLKR(a.book_value) : "—"}</Td></tr>))}</tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
