import type { Metadata } from "next";
import Link from "next/link";
import { Briefcase, Plus } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatLKR } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { pickMonth } from "./month";
import { Progress } from "./progress";
import { saveCommissionPlan, saveRep, saveTerritory, setTargets } from "./actions";

export const metadata: Metadata = { title: "Sales Team" };

type Row = { id: string; code: string; full_name: string; territory: string | null; plan: string | null; is_active: boolean; sales_target: number;
  collection_target: number; new_customers_target: number; visits_target: number; sales_net: number; collections: number; new_customers: number;
  visits: number; achievement_pct: number | null; cash_with_rep: number; customers: number; open_leads: number };

export default async function SalesTeamPage({ searchParams }: { searchParams: Promise<{ m?: string }> }) {
  await requirePermission("sales_reps.manage");
  const mo = pickMonth((await searchParams).m);
  const supabase = await createClient();
  const [{ data }, { data: territories }, { data: plans }, { data: logins }, { data: employees }] = await Promise.all([
    supabase.rpc("sales_team_overview", { p_year: mo.year, p_month: mo.month }),
    supabase.from("territories").select("id, code, name, districts, is_active").order("name"),
    supabase.from("commission_plans").select("*").order("name"),
    supabase.rpc("staff_directory"),
    supabase.rpc("employee_directory"),
  ]);
  const rows = (data ?? []) as Row[];
  const active = rows.filter((r) => r.is_active);
  const sum = (k: keyof Row) => active.reduce((a, r) => a + Number(r[k] ?? 0), 0);
  const users = ((logins ?? []) as { id: string; full_name: string }[]);
  const emps = ((employees ?? []) as { id: string; full_name: string; emp_no: string; status: string }[]).filter((e) => e.status === "active");

  return (
    <>
      <PageHeader title="Sales Team" description="Reps, their customers, monthly targets and how they are doing. Each rep's sales are the invoices of the customers assigned to them."
        actions={<div className="flex flex-wrap gap-2">
          <form className="flex items-center gap-1"><Input type="month" name="m" defaultValue={mo.key} className="h-9 w-40" aria-label="Month" />
            <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Show</button></form>
          <FormDialog trigger="Territories" triggerSize="md" title="Add a territory" submitLabel="Add" action={saveTerritory}>
            <ul className="max-h-40 overflow-y-auto text-sm">{(territories ?? []).map((t) => <li key={t.id}>{t.code} — {t.name}{t.districts?.length ? ` (${t.districts.join(", ")})` : ""}</li>)}</ul>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Code" htmlFor="tr-c" required><Input id="tr-c" name="code" required placeholder="CENTRAL" /></Field>
              <Field label="Name" htmlFor="tr-n" required><Input id="tr-n" name="name" required placeholder="Central Province" /></Field>
            </div>
            <Field label="Districts / towns" htmlFor="tr-d" hint="Separate with commas"><Input id="tr-d" name="districts" placeholder="Kandy, Matale" /></Field>
          </FormDialog>
          <FormDialog trigger="Commission plans" triggerSize="md" title="Commission plan" description="Commission = sales × sales % + collections × collection % + (target met: sales × bonus %) + new customers × bonus."
            submitLabel="Save plan" action={saveCommissionPlan} wide>
            <ul className="text-sm">{(plans ?? []).map((p) => <li key={p.id}>{p.code} — {p.name}: {Number(p.sales_rate_pct)}% sales, {Number(p.collection_rate_pct)}% collections,
              +{Number(p.target_bonus_pct)}% at target, Rs. {Number(p.new_customer_bonus)} per new customer</li>)}</ul>
            <Field label="Edit plan" htmlFor="cp-id" hint="Leave as New to create one"><Select id="cp-id" name="id" defaultValue=""><option value="">New plan</option>
              {(plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.code}</option>)}</Select></Field>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Code" htmlFor="cp-c" required><Input id="cp-c" name="code" required /></Field>
              <Field label="Name" htmlFor="cp-n" required className="sm:col-span-2"><Input id="cp-n" name="name" required /></Field>
              <Field label="% of sales (before VAT)" htmlFor="cp-s"><Input id="cp-s" name="sales_rate_pct" type="number" step="0.01" min={0} max={100} defaultValue={0} /></Field>
              <Field label="% of collections" htmlFor="cp-co"><Input id="cp-co" name="collection_rate_pct" type="number" step="0.01" min={0} max={100} defaultValue={0} /></Field>
              <Field label="Extra % of sales at target" htmlFor="cp-t"><Input id="cp-t" name="target_bonus_pct" type="number" step="0.01" min={0} max={100} defaultValue={0} /></Field>
              <Field label="Rs. per new customer" htmlFor="cp-nb"><Input id="cp-nb" name="new_customer_bonus" type="number" step="0.01" min={0} defaultValue={0} /></Field>
            </div>
            <Field label="Notes" htmlFor="cp-no"><Textarea id="cp-no" name="notes" /></Field>
          </FormDialog>
          <FormDialog trigger={<><Plus className="h-4 w-4" /> Add rep</>} triggerVariant="primary" triggerSize="md" title="Add a sales rep"
            description="The rep needs a login (Users) with the Sales Representative role." submitLabel="Save" action={saveRep}>
            <Field label="Login" htmlFor="sr-p" required><Select id="sr-p" name="profile_id" required>{users.map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</Select></Field>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Rep code" htmlFor="sr-c" required><Input id="sr-c" name="code" required placeholder="SR01" /></Field>
              <Field label="Mobile" htmlFor="sr-ph"><Input id="sr-ph" name="phone" type="tel" /></Field>
              <Field label="Territory" htmlFor="sr-t"><Select id="sr-t" name="territory_id" defaultValue=""><option value="">—</option>{(territories ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</Select></Field>
              <Field label="Commission plan" htmlFor="sr-cp"><Select id="sr-cp" name="commission_plan_id" defaultValue=""><option value="">No commission</option>{(plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</Select></Field>
            </div>
            <Field label="Employee record (for payroll)" htmlFor="sr-e" hint="Commission is then paid on the payslip"><Select id="sr-e" name="employee_id" defaultValue=""><option value="">Not on our payroll (paid separately)</option>
              {emps.map((e) => <option key={e.id} value={e.id}>{e.full_name} ({e.emp_no})</option>)}</Select></Field>
          </FormDialog>
        </div>} />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label={`Sales — ${mo.label}`} value={formatLKR(sum("sales_net"))} hint={`Target ${formatLKR(sum("sales_target"))}`} />
        <Stat label="Collections" value={formatLKR(sum("collections"))} hint={`Target ${formatLKR(sum("collection_target"))}`} />
        <Stat label="New customers" value={sum("new_customers")} hint={`${sum("visits")} visits`} />
        <Stat label="Cash held by reps" value={formatLKR(sum("cash_with_rep"))} hint="Collected, not yet handed in" />
      </div>

      <Card className="mb-6">
        <CardHeader title={`Reps — ${mo.label}`} />
        {rows.length === 0 ? <EmptyState icon={Briefcase} title="No reps yet" description="Use Add rep. Each rep needs a login with the Sales Representative role." /> : (
          <Table>
            <thead><tr><Th>Rep</Th><Th>Sales</Th><Th>Collections</Th><Th>New customers</Th><Th>Visits</Th><Th className="text-right">Cash held</Th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id} className={r.is_active ? "" : "opacity-50"}>
                <Td><Link href={`/sales/reps/${r.id}`} className="font-medium text-ola-700 hover:underline">{r.full_name}</Link>
                  <span className="block text-xs text-muted">{r.code}{r.territory ? ` · ${r.territory}` : ""} · {r.customers} customers · {r.open_leads} open leads</span>
                  {!r.is_active && <Badge tone="neutral">Inactive</Badge>}</Td>
                <Td><Progress actual={Number(r.sales_net)} target={Number(r.sales_target)} /></Td>
                <Td><Progress actual={Number(r.collections)} target={Number(r.collection_target)} /></Td>
                <Td><Progress actual={r.new_customers} target={r.new_customers_target} money={false} /></Td>
                <Td><Progress actual={r.visits} target={r.visits_target} money={false} /></Td>
                <Td className={`num text-right ${Number(r.cash_with_rep) > 0 ? "font-semibold text-amber-700" : ""}`}>{formatLKR(r.cash_with_rep)}</Td>
              </tr>))}</tbody>
          </Table>
        )}
      </Card>

      {active.length > 0 && (
        <Card>
          <CardHeader title={`Targets — ${mo.label}`} description="Sales are before VAT. Change the month at the top to set another month." />
          <ActionForm action={setTargets}>
            <input type="hidden" name="month" value={mo.key} />
            <Table>
              <thead><tr><Th>Rep</Th><Th>Sales (Rs.)</Th><Th>Collections (Rs.)</Th><Th>New customers</Th><Th>Visits</Th></tr></thead>
              <tbody>{active.map((r) => (
                <tr key={r.id}><Td className="font-medium">{r.full_name}</Td>
                  <Td><Input aria-label="Sales target" name={`st:${r.id}`} type="number" min={0} step="1000" defaultValue={Number(r.sales_target) || ""} className="w-36" /></Td>
                  <Td><Input aria-label="Collection target" name={`ct:${r.id}`} type="number" min={0} step="1000" defaultValue={Number(r.collection_target) || ""} className="w-36" /></Td>
                  <Td><Input aria-label="New customers target" name={`nc:${r.id}`} type="number" min={0} defaultValue={r.new_customers_target || ""} className="w-24" /></Td>
                  <Td><Input aria-label="Visits target" name={`vs:${r.id}`} type="number" min={0} defaultValue={r.visits_target || ""} className="w-24" /></Td></tr>))}</tbody>
            </Table>
            <div className="p-4"><SubmitButton>Save targets</SubmitButton></div>
          </ActionForm>
        </Card>
      )}
    </>
  );
}
