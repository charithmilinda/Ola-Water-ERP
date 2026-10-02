import type { Metadata } from "next";
import Link from "next/link";
import { Network, Plus } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Progress } from "../sales/progress";
import { DistributorFields } from "./distributor-fields";
import { createDistributor } from "./actions";

export const metadata: Metadata = { title: "Distributors" };

type Row = { id: string; code: string; kind: string; customer_id: string; name: string; customer_no: string; territory: string | null; status: string; manager: string | null;
  monthly_target: number; sales_month: number; sales_last_month: number; outstanding: number; overdue: number; credit_limit: number; ola_bottles: number;
  last_stock_report: string | null; agreement_end: string | null };

export default async function DistributorsPage() {
  await requirePermission("distributors.manage");
  const supabase = await createClient();
  const [{ data }, { data: territories }, { data: staff }, { data: custs }, { data: existing }] = await Promise.all([
    supabase.rpc("distributor_overview"),
    supabase.from("territories").select("id, name").eq("is_active", true).order("name"),
    supabase.rpc("staff_directory"),
    supabase.from("customers").select("id, name, customer_type").in("customer_type", ["distributor", "shop", "supermarket"]).eq("status", "active").order("name"),
    supabase.from("distributors").select("customer_id"),
  ]);
  const rows = (data ?? []) as Row[];
  const taken = new Set((existing ?? []).map((x) => x.customer_id));
  const free = (custs ?? []).filter((c) => !taken.has(c.id)).map((c) => ({ id: c.id, name: `${c.name} (${c.customer_type})` }));
  const staffOpts = ((staff ?? []) as { id: string; full_name: string }[]).map((s) => ({ id: s.id, name: s.full_name }));
  const active = rows.filter((r) => r.status === "active");
  const today = todayISO();

  return (
    <>
      <PageHeader title="Distributors & Dealers" description="Partners who buy in bulk and resell in their area. Orders, invoices, payments, credit and bottles are on their customer account."
        actions={<FormDialog trigger={<><Plus className="h-4 w-4" /> Add distributor</>} triggerVariant="primary" triggerSize="md" title="Add a distributor" submitLabel="Save"
          action={createDistributor} wide>
          {free.length === 0 ? <p className="text-sm text-amber-800">First create a customer with the type Distributor (Customers → New customer).</p>
            : <DistributorFields territories={territories ?? []} staff={staffOpts} customers={free} />}
        </FormDialog>} />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Active distributors" value={active.length} />
        <Stat label="Sales this month" value={formatLKR(active.reduce((a, r) => a + Number(r.sales_month), 0))} hint={`Target ${formatLKR(active.reduce((a, r) => a + Number(r.monthly_target), 0))}`} />
        <Stat label="They owe" value={formatLKR(rows.reduce((a, r) => a + Number(r.outstanding), 0))} hint={`${formatLKR(rows.reduce((a, r) => a + Number(r.overdue), 0))} overdue`} />
        <Stat label="OLA bottles with them" value={rows.reduce((a, r) => a + Number(r.ola_bottles), 0)} />
      </div>

      <Card>
        <CardHeader title="Distributors" />
        {rows.length === 0 ? <EmptyState icon={Network} title="No distributors yet" /> : (
          <Table>
            <thead><tr><Th>Distributor</Th><Th>This month vs target</Th><Th className="text-right">Last month</Th><Th className="text-right">Owes</Th>
              <Th className="text-right">Bottles</Th><Th>Stock count</Th><Th>Agreement</Th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id} className={r.status === "active" ? "" : "opacity-60"}>
                <Td><Link href={`/distributors/${r.id}`} className="font-medium text-ola-700 hover:underline">{r.name}</Link>
                  <span className="block text-xs text-muted">{r.code} · {r.kind}{r.territory ? ` · ${r.territory}` : ""}{r.manager ? ` · ${r.manager}` : ""}</span>
                  {r.status !== "active" && <Badge tone="neutral">{r.status}</Badge>}</Td>
                <Td><Progress actual={Number(r.sales_month)} target={Number(r.monthly_target)} /></Td>
                <Td className="num text-right">{formatLKR(r.sales_last_month)}</Td>
                <Td className="num text-right">{formatLKR(r.outstanding)}{Number(r.overdue) > 0 && <span className="block text-xs text-red-700">{formatLKR(r.overdue)} overdue</span>}
                  <span className="block text-xs text-muted">limit {formatLKR(r.credit_limit)}</span></Td>
                <Td className="num text-right">{r.ola_bottles}</Td>
                <Td>{r.last_stock_report ? formatDate(r.last_stock_report) : <span className="text-muted">Never</span>}</Td>
                <Td className={r.agreement_end && r.agreement_end < today ? "font-semibold text-red-700" : ""}>{r.agreement_end ? `until ${formatDate(r.agreement_end)}` : "—"}</Td>
              </tr>))}</tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
