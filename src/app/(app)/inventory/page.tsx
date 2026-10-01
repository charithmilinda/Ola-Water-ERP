import type { Metadata } from "next";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDateTime, humanize } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { ReceiveForm, TransferForm } from "./stock-forms";
import { adjustStock } from "./actions";

export const metadata: Metadata = { title: "Inventory" };

export default async function InventoryPage() {
  const access = await requirePermission("inventory.view");
  const supabase = await createClient();
  const [{ data: balances }, { data: locations }, { data: products }, { data: tx }] = await Promise.all([
    supabase.from("inventory_balances").select("location_id, product_id, stock_status, qty"),
    supabase.from("locations").select("id, code, name, location_type").eq("is_active", true).in("location_type", ["warehouse", "head_office", "vehicle", "water_shop"]).order("location_type").order("code"),
    supabase.from("products").select("id, name, sku").eq("is_active", true).order("sort_order"),
    supabase.from("inventory_transactions").select("id, created_at, txn_type, qty, from_location, to_location, reason, product:products(name)").order("created_at", { ascending: false }).limit(25),
  ]);
  const qty = (l: string, p: string) => balances?.filter((b) => b.location_id === l && b.product_id === p && b.stock_status === "available").reduce((a, b) => a + Number(b.qty), 0) ?? 0;
  const locs = (locations ?? []).filter((l) => (balances ?? []).some((b) => b.location_id === l.id && Number(b.qty) !== 0) || l.location_type !== "vehicle");
  const locName = Object.fromEntries((locations ?? []).map((l) => [l.id, l.name]));
  const stores = (locations ?? []).filter((l) => l.location_type !== "vehicle");
  const manage = can(access, "inventory.manage");

  return (
    <>
      <PageHeader title="Inventory" description="Filled product stock by location. Empty and external bottles are tracked separately under Bottles." />
      <Card className="mb-6">
        <CardHeader title="Stock on hand" />
        <Table>
          <thead><tr><Th>Product</Th>{locs.map((l) => <Th key={l.id} className="text-right">{l.name}</Th>)}<Th className="text-right">Total</Th></tr></thead>
          <tbody>
            {products?.map((p) => {
              const total = locs.reduce((a, l) => a + qty(l.id, p.id), 0);
              return (
                <tr key={p.id}>
                  <Td className="font-medium">{p.name}</Td>
                  {locs.map((l) => <Td key={l.id} className={`num text-right ${qty(l.id, p.id) === 0 ? "text-muted" : ""}`}>{qty(l.id, p.id)}</Td>)}
                  <Td className="num text-right font-semibold">{total}</Td>
                </tr>
              );
            })}
          </tbody>
        </Table>
      </Card>

      {manage && (
        <div className="mb-6 grid gap-6 lg:grid-cols-2">
          <Card><CardHeader title="Receive stock" description="Production output or go-live opening stock." /><CardBody><ReceiveForm locations={stores} products={products ?? []} /></CardBody></Card>
          <Card>
            <CardHeader title="Transfer & count" actions={
              <FormDialog trigger="Stock count / adjust" title="Stock count" description="Enter what you physically counted. The difference is posted and audited." submitLabel="Save count" action={adjustStock}>
                <Field label="Location" htmlFor="adj-loc"><Select id="adj-loc" name="location">{stores.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
                <Field label="Product" htmlFor="adj-p"><Select id="adj-p" name="product_id">{products?.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</Select></Field>
                <Field label="Counted quantity" htmlFor="adj-c" required><Input id="adj-c" name="counted" type="number" min={0} required /></Field>
                <Field label="Reason" htmlFor="adj-r" required><Input id="adj-r" name="reason" required placeholder="e.g. Monthly count, 3 bottles leaking" /></Field>
              </FormDialog>
            } />
            <CardBody><TransferForm locations={stores} products={products ?? []} /></CardBody>
          </Card>
        </div>
      )}

      <Card>
        <CardHeader title="Recent stock movements" />
        <Table>
          <thead><tr><Th>When</Th><Th>Movement</Th><Th>Product</Th><Th>From → To</Th><Th className="text-right">Qty</Th></tr></thead>
          <tbody>
            {tx?.map((t) => (
              <tr key={t.id}>
                <Td className="whitespace-nowrap">{formatDateTime(t.created_at)}</Td>
                <Td>{humanize(t.txn_type)}{t.reason && <span className="block text-xs text-muted">{t.reason}</span>}</Td>
                <Td>{(t.product as unknown as { name: string })?.name}</Td>
                <Td>{t.from_location ? locName[t.from_location] ?? "Vehicle" : "In"} → {t.to_location ? locName[t.to_location] ?? "Vehicle" : "Out"}</Td>
                <Td className="num text-right">{Number(t.qty)}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </Card>
    </>
  );
}
