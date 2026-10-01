import type { Metadata } from "next";
import Link from "next/link";
import { Contact, Plus, Search } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { PAGE_SIZE } from "@/lib/constants";
import { formatLKR, formatPhone } from "@/lib/format";
import { CUSTOMER_TYPES } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Pagination } from "@/components/ui/pagination";
import { Input, Label, Select } from "@/components/ui/field";
import { Button, buttonVariants } from "@/components/ui/button";
import { Alert } from "@/components/ui/alert";

export const metadata: Metadata = { title: "Customers" };

type Row = {
  id: string; customer_no: string; name: string; company_name: string | null; customer_type: string; phone: string;
  route: string | null; status: string; bottle_model: string; ola_bottles: number; outstanding: number; total_count: number;
};
const typeLabel = Object.fromEntries(CUSTOMER_TYPES) as Record<string, string>;

export default async function CustomersPage({ searchParams }: { searchParams: Promise<{ q?: string; type?: string; route?: string; status?: string; page?: string }> }) {
  const access = await requirePermission("customers.view");
  const f = await searchParams;
  const page = Math.max(1, Number(f.page) || 1);
  const supabase = await createClient();
  const [{ data, error }, { data: routes }] = await Promise.all([
    supabase.rpc("customer_list", {
      p_search: f.q ?? null, p_type: f.type ?? null, p_route: f.route || null, p_status: f.status ?? null,
      p_limit: PAGE_SIZE, p_offset: (page - 1) * PAGE_SIZE,
    }),
    supabase.from("routes").select("id, name").order("name"),
  ]);
  const rows = (data ?? []) as Row[];
  const total = rows[0]?.total_count ?? 0;
  const qs = (p: number) => `/customers?${new URLSearchParams(Object.entries({ ...f, page: String(p) }).filter(([, v]) => v) as [string, string][])}`;

  return (
    <>
      <PageHeader
        title="Customers"
        description="Households, businesses, shops and distributors served by OLA."
        actions={can(access, "customers.manage") && (
          <Link href="/customers/new" className={buttonVariants()}>
            <Plus className="h-4 w-4" /> New customer
          </Link>
        )}
      />
      <Card className="mb-4 p-4">
        <form className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5" method="get">
          <div className="lg:col-span-2">
            <Label htmlFor="q">Search</Label>
            <Input id="q" name="q" defaultValue={f.q} placeholder="Name, customer no. or phone" />
          </div>
          <div>
            <Label htmlFor="type">Type</Label>
            <Select id="type" name="type" defaultValue={f.type ?? ""}>
              <option value="">All types</option>
              {CUSTOMER_TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </Select>
          </div>
          <div>
            <Label htmlFor="route">Route</Label>
            <Select id="route" name="route" defaultValue={f.route ?? ""}>
              <option value="">All routes</option>
              {routes?.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
            </Select>
          </div>
          <div>
            <Label htmlFor="status">Status</Label>
            <Select id="status" name="status" defaultValue={f.status ?? ""}>
              <option value="">All</option>
              <option value="active">Active</option>
              <option value="on_hold">On hold</option>
              <option value="inactive">Inactive</option>
            </Select>
          </div>
          <div className="flex gap-2 sm:col-span-2 lg:col-span-5">
            <Button type="submit"><Search className="h-4 w-4" /> Search</Button>
            <Link href="/customers" className={buttonVariants({ variant: "secondary" })}>Clear</Link>
          </div>
        </form>
      </Card>
      <Card>
        {error && <Alert tone="error" className="m-4">{error.message}</Alert>}
        {rows.length === 0 ? (
          <EmptyState icon={Contact} title="No customers found" description={f.q ? "Try a different search." : "Add your first customer."} />
        ) : (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Customer</Th>
                  <Th>Type</Th>
                  <Th>Phone</Th>
                  <Th>Route</Th>
                  <Th className="text-right">OLA bottles</Th>
                  <Th className="text-right">Balance</Th>
                </tr>
              </thead>
              <tbody>
                {rows.map((c) => (
                  <tr key={c.id} className="hover:bg-ola-50/40">
                    <Td>
                      <Link href={`/customers/${c.id}`} className="font-medium text-ola-700 hover:underline">{c.name}</Link>
                      <span className="block text-xs text-muted">{c.customer_no}{c.company_name && ` · ${c.company_name}`}</span>
                      {c.status !== "active" && <Badge tone={c.status === "on_hold" ? "red" : "neutral"} className="mt-1">{c.status === "on_hold" ? "On hold" : "Inactive"}</Badge>}
                    </Td>
                    <Td>{typeLabel[c.customer_type]}</Td>
                    <Td className="whitespace-nowrap">{formatPhone(c.phone)}</Td>
                    <Td>{c.route ?? <span className="text-muted">—</span>}</Td>
                    <Td className="num text-right">{c.ola_bottles}</Td>
                    <Td className={`num text-right ${Number(c.outstanding) > 0 ? "font-medium text-red-700" : ""}`}>{formatLKR(c.outstanding)}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
            <Pagination page={page} pageSize={PAGE_SIZE} total={Number(total)} hrefFor={qs} />
          </>
        )}
      </Card>
    </>
  );
}
