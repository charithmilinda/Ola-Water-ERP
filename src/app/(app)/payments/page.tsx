import type { Metadata } from "next";
import Link from "next/link";
import { Search, Wallet } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { PAGE_SIZE } from "@/lib/constants";
import { formatDateTime, formatLKR, humanize, todayISO } from "@/lib/format";
import { PAYMENT_METHODS } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { Pagination } from "@/components/ui/pagination";
import { Input, Label, Select } from "@/components/ui/field";
import { Button, buttonVariants } from "@/components/ui/button";

export const metadata: Metadata = { title: "Payments" };

export default async function PaymentsPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string; method?: string; page?: string }> }) {
  await requirePermission("payments.view");
  const f = await searchParams;
  const from = f.from ?? todayISO();
  const to = f.to ?? todayISO();
  const page = Math.max(1, Number(f.page) || 1);
  const supabase = await createClient();
  const start = new Date(`${from}T00:00:00+05:30`).toISOString();
  const end = new Date(new Date(`${to}T00:00:00+05:30`).getTime() + 86400000).toISOString();
  let q = supabase.from("payments").select("id, payment_no, received_at, method, amount, reference, unallocated, status, customer:customers(id, name), run:route_runs(run_no)", { count: "exact" })
    .gte("received_at", start).lt("received_at", end).order("received_at", { ascending: false }).range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  let tq = supabase.from("payments").select("method, amount").gte("received_at", start).lt("received_at", end).eq("status", "received");
  if (f.method) { q = q.eq("method", f.method); tq = tq.eq("method", f.method); }
  const [{ data, count }, { data: totals }] = await Promise.all([q, tq]);
  type Row = { id: string; payment_no: string; received_at: string; method: string; amount: number; reference: string | null; unallocated: number; status: string;
    customer: { id: string; name: string } | null; run: { run_no: string } | null };
  const byMethod = new Map<string, number>();
  totals?.forEach((t) => byMethod.set(t.method, (byMethod.get(t.method) ?? 0) + Number(t.amount)));
  const sum = [...byMethod.values()].reduce((a, b) => a + b, 0);
  const qs = (p: number) => `/payments?${new URLSearchParams(Object.entries({ ...f, from, to, page: String(p) }).filter(([, v]) => v) as [string, string][])}`;

  return (
    <>
      <PageHeader title="Payments" description="Money received from customers — at the office and by drivers." />
      <Card className="mb-4 p-4">
        <form className="flex flex-wrap items-end gap-3" method="get">
          <div><Label htmlFor="from">From</Label><Input id="from" name="from" type="date" defaultValue={from} /></div>
          <div><Label htmlFor="to">To</Label><Input id="to" name="to" type="date" defaultValue={to} /></div>
          <div><Label htmlFor="method">Method</Label>
            <Select id="method" name="method" defaultValue={f.method ?? ""}><option value="">All</option>{PAYMENT_METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></div>
          <Button type="submit"><Search className="h-4 w-4" /> Show</Button>
          <Link href="/payments" className={buttonVariants({ variant: "secondary" })}>Today</Link>
        </form>
      </Card>
      <div className="mb-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Total received" value={formatLKR(sum)} hint={`${count ?? 0} payment(s)`} />
        {[...byMethod.entries()].slice(0, 3).map(([m, v]) => <Stat key={m} label={humanize(m)} value={formatLKR(v)} />)}
      </div>
      <Card>
        {(data ?? []).length === 0 ? <EmptyState icon={Wallet} title="No payments in this period" /> : (
          <>
            <Table>
              <thead><tr><Th>Payment</Th><Th>Customer</Th><Th>When</Th><Th>Method</Th><Th>Collected on</Th><Th className="text-right">Amount</Th></tr></thead>
              <tbody>
                {(data as unknown as Row[]).map((p) => (
                  <tr key={p.id}>
                    <Td className="font-medium">{p.payment_no}{p.reference && <span className="block text-xs text-muted">{p.reference}</span>}</Td>
                    <Td><Link href={`/customers/${p.customer?.id}`} className="text-ola-700 hover:underline">{p.customer?.name}</Link></Td>
                    <Td className="whitespace-nowrap">{formatDateTime(p.received_at)}</Td>
                    <Td>{humanize(p.method)}</Td>
                    <Td>{p.run?.run_no ?? "Office"}</Td>
                    <Td className="num text-right">{formatLKR(p.amount)}{Number(p.unallocated) > 0 && <span className="block text-xs text-ola-700">{formatLKR(p.unallocated)} on account</span>}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
            <Pagination page={page} pageSize={PAGE_SIZE} total={count ?? 0} hrefFor={qs} />
          </>
        )}
      </Card>
    </>
  );
}
