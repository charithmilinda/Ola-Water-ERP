import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { Plus, Store } from "lucide-react";
import { requireAnywhere, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatLKR } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { ShopFields } from "./shop-fields";
import { createShop } from "./actions";

export const metadata: Metadata = { title: "Water Shops" };

type Row = { id: string; code: string; name: string; operating_model: string; status: string; city: string | null; sales_today: number;
  outstanding: number; pending_requests: number; till_open: boolean; open_exceptions: number; ola_bottles: number; external_bottles: number };

export default async function ShopsPage() {
  const access = await requireAnywhere(["shops.view", "shop_pos.use"]);
  const supabase = await createClient();
  const [{ data }, { data: lists }] = await Promise.all([
    supabase.rpc("shop_list"),
    supabase.from("price_lists").select("id, name, code").eq("is_active", true).order("name"),
  ]);
  const rows = (data ?? []) as Row[];
  if (!can(access, "shops.view") && rows.length === 1) redirect(`/shops/${rows[0].id}`);

  return (
    <>
      <PageHeader title="Water Shops" description="OLA-owned and dealer-owned shops: stock, tills, bottles and what each shop owes."
        actions={can(access, "shops.manage") && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New shop</>} triggerVariant="primary" triggerSize="md" title="New water shop"
            description="Creates the shop's stock location, its till and a walk-in customer account." submitLabel="Create shop" action={createShop} wide>
            <ShopFields priceLists={lists ?? []} canCredit={can(access, "customers.credit")} />
          </FormDialog>
        )} />
      <Card>
        {rows.length === 0 ? <EmptyState icon={Store} title="No water shops yet" description="Add your first shop with New shop." /> : (
          <Table>
            <thead><tr><Th>Shop</Th><Th>Owner</Th><Th>Till</Th><Th className="text-right">Sales today</Th><Th className="text-right">Owes OLA</Th>
              <Th className="text-right">OLA bottles</Th><Th className="text-right">Other bottles</Th><Th>Needs attention</Th></tr></thead>
            <tbody>
              {rows.map((s) => (
                <tr key={s.id} className="hover:bg-ola-50/40">
                  <Td><Link href={`/shops/${s.id}`} className="font-medium text-ola-700 hover:underline">{s.name}</Link>
                    <span className="block text-xs text-muted">{s.code}{s.city && ` · ${s.city}`}</span>
                    {s.status !== "active" && <Badge tone="neutral" className="mt-1 capitalize">{s.status}</Badge>}</Td>
                  <Td><Badge tone={s.operating_model === "dealer" ? "amber" : "blue"}>{s.operating_model === "dealer" ? "Dealer" : "OLA-owned"}</Badge></Td>
                  <Td>{s.till_open ? <Badge tone="green">Open</Badge> : <span className="text-muted">Closed</span>}</Td>
                  <Td className="num text-right">{formatLKR(s.sales_today)}</Td>
                  <Td className={`num text-right ${Number(s.outstanding) > 0 ? "font-medium text-red-700" : ""}`}>{s.operating_model === "dealer" ? formatLKR(s.outstanding) : "—"}</Td>
                  <Td className="num text-right">{s.ola_bottles}</Td>
                  <Td className="num text-right">{s.external_bottles}</Td>
                  <Td className="space-x-1">
                    {Number(s.pending_requests) > 0 && <Badge tone="blue">{s.pending_requests} request(s)</Badge>}
                    {Number(s.open_exceptions) > 0 && <Badge tone="red">{s.open_exceptions} exception(s)</Badge>}
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
