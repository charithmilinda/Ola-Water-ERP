import type { Metadata } from "next";
import Link from "next/link";
import { ClipboardList, Plus, Search } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { PAGE_SIZE } from "@/lib/constants";
import { formatDate, formatLKR } from "@/lib/format";
import { ORDER_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Pagination } from "@/components/ui/pagination";
import { Input, Label, Select } from "@/components/ui/field";
import { Button, buttonVariants } from "@/components/ui/button";
import { Alert } from "@/components/ui/alert";

export const metadata: Metadata = { title: "Orders" };

type F = { q?: string; status?: string; from?: string; to?: string; customer?: string; page?: string };

export default async function OrdersPage({ searchParams }: { searchParams: Promise<F> }) {
  const access = await requirePermission("orders.view");
  const f = await searchParams;
  const page = Math.max(1, Number(f.page) || 1);
  const supabase = await createClient();
  let q = supabase
    .from("orders")
    .select("id, order_no, status, requested_date, time_window, total, hold_reason, source, customer:customers(id, name, customer_no), route:routes(name)", { count: "exact" })
    .order("requested_date", { ascending: false })
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (f.status) q = q.eq("status", f.status);
  if (f.from) q = q.gte("requested_date", f.from);
  if (f.to) q = q.lte("requested_date", f.to);
  if (f.customer) q = q.eq("customer_id", f.customer);
  if (f.q) q = q.ilike("order_no", `%${f.q.replace(/[%_]/g, "")}%`);
  const { data, count, error } = await q;
  type Row = { id: string; order_no: string; status: string; requested_date: string; time_window: string | null; total: number; hold_reason: string | null; source: string;
    customer: { id: string; name: string; customer_no: string } | null; route: { name: string } | null };
  const rows = (data ?? []) as unknown as Row[];
  const qs = (p: number) => `/orders?${new URLSearchParams(Object.entries({ ...f, page: String(p) }).filter(([, v]) => v) as [string, string][])}`;

  return (
    <>
      <PageHeader title="Orders" description="From draft to delivered. Orders on hold need credit approval."
        actions={can(access, "orders.manage") && <Link href="/orders/new" className={buttonVariants()}><Plus className="h-4 w-4" /> New order</Link>} />
      <Card className="mb-4 p-4">
        <form className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5" method="get">
          <div><Label htmlFor="q">Order no.</Label><Input id="q" name="q" defaultValue={f.q} /></div>
          <div>
            <Label htmlFor="status">Status</Label>
            <Select id="status" name="status" defaultValue={f.status ?? ""}>
              <option value="">All</option>
              {Object.entries(ORDER_STATUS).map(([v, s]) => <option key={v} value={v}>{s.label}</option>)}
            </Select>
          </div>
          <div><Label htmlFor="from">Delivery from</Label><Input id="from" name="from" type="date" defaultValue={f.from} /></div>
          <div><Label htmlFor="to">Delivery to</Label><Input id="to" name="to" type="date" defaultValue={f.to} /></div>
          <div className="flex items-end gap-2">
            {f.customer && <input type="hidden" name="customer" value={f.customer} />}
            <Button type="submit"><Search className="h-4 w-4" /> Filter</Button>
            <Link href="/orders" className={buttonVariants({ variant: "secondary" })}>Clear</Link>
          </div>
        </form>
      </Card>
      <Card>
        {error && <Alert tone="error" className="m-4">{error.message}</Alert>}
        {rows.length === 0 ? (
          <EmptyState icon={ClipboardList} title="No orders found" />
        ) : (
          <>
            <Table>
              <thead><tr><Th>Order</Th><Th>Customer</Th><Th>Deliver on</Th><Th>Route</Th><Th>Status</Th><Th className="text-right">Total</Th></tr></thead>
              <tbody>
                {rows.map((o) => {
                  const b = statusBadge(ORDER_STATUS, o.status);
                  return (
                    <tr key={o.id} className="hover:bg-ola-50/40">
                      <Td><Link href={`/orders/${o.id}`} className="font-medium text-ola-700 hover:underline">{o.order_no}</Link>
                        <span className="block text-xs capitalize text-muted">{o.source.replace("_", " ")}</span></Td>
                      <Td>{o.customer?.name}<span className="block text-xs text-muted">{o.customer?.customer_no}</span></Td>
                      <Td className="whitespace-nowrap">{formatDate(o.requested_date)}{o.time_window && <span className="block text-xs text-muted">{o.time_window}</span>}</Td>
                      <Td>{o.route?.name ?? <span className="text-muted">—</span>}</Td>
                      <Td><Badge tone={b.tone}>{b.label}</Badge>{o.hold_reason && <span className="mt-1 block max-w-64 text-xs text-red-700">{o.hold_reason}</span>}</Td>
                      <Td className="num text-right">{formatLKR(o.total)}</Td>
                    </tr>
                  );
                })}
              </tbody>
            </Table>
            <Pagination page={page} pageSize={PAGE_SIZE} total={count ?? 0} hrefFor={qs} />
          </>
        )}
      </Card>
    </>
  );
}
