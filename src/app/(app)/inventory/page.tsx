import type { Metadata } from "next";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import Link from "next/link";
import { formatDateTime, formatLKR, formatQty, humanize } from "@/lib/format";
import { Badge } from "@/components/ui/badge";
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
  const [{ data: balances }, { data: locations }, { data: items }, { data: tx }, { data: summary }, { data: expiring }] = await Promise.all([
    supabase.from("inventory_balances").select("location_id, product_id, stock_status, qty"),
    supabase.from("locations").select("id, code, name, location_type").eq("is_active", true).in("location_type", ["warehouse", "head_office", "vehicle", "water_shop"]).order("location_type").order("code"),
    supabase.from("products").select("id, name, sku, unit, item_type").eq("is_active", true).order("item_type", { ascending: false }).order("sort_order").order("name"),
    supabase.from("inventory_transactions").select("id, created_at, txn_type, qty, from_location, to_location, reason, product:products(name), batch:production_batches(batch_no)").order("created_at", { ascending: false }).limit(30),
    supabase.rpc("stock_summary", { p_item_type: null }),
    supabase.rpc("expiring_stock", { p_days: null }),
  ]);
  const products = (items ?? []).filter((p) => p.item_type === "finished_good");
  const allItems = (items ?? []).map((p) => ({ id: p.id, name: p.name, unit: p.unit, finished: p.item_type === "finished_good" }));
  type Sum = { product_id: string; name: string; item_type: string; unit: string; available: number; qc_hold: number; quarantine: number; damaged: number; value: number; low: boolean };
  const sums = (summary ?? []) as Sum[];
  const fg = sums.filter((x) => x.item_type === "finished_good");
  const mats = sums.filter((x) => x.item_type !== "finished_good");
  const low = sums.filter((x) => x.low);
  const qty = (l: string, p: string) => balances?.filter((b) => b.location_id === l && b.product_id === p && b.stock_status === "available").reduce((a, b) => a + Number(b.qty), 0) ?? 0;
  const locs = (locations ?? []).filter((l) => (balances ?? []).some((b) => b.location_id === l.id && Number(b.qty) !== 0) || l.location_type !== "vehicle");
  const locName = Object.fromEntries((locations ?? []).map((l) => [l.id, l.name]));
  const stores = (locations ?? []).filter((l) => l.location_type !== "vehicle");
  const manage = can(access, "inventory.manage");

  return (
    <>
      <PageHeader title="Inventory" description="Sellable stock by location, stock waiting for QC or in quarantine, and materials. Empty and external bottles are tracked under Bottles." />
      {(low.length > 0 || (expiring ?? []).length > 0) && (
        <div className="mb-6 grid gap-4 lg:grid-cols-2">
          {low.length > 0 && (
            <Card className="border-amber-200"><CardHeader title="Low stock" description="At or below the reorder level." />
              <ul className="divide-y divide-line text-sm">{low.map((x) => <li key={x.product_id} className="flex justify-between px-5 py-2"><span>{x.name}</span>
                <span className="num font-semibold text-amber-800">{formatQty(x.available)} {x.unit}</span></li>)}</ul>
              <p className="px-5 py-2 text-xs"><Link href="/purchasing" className="text-ola-700 hover:underline">Raise a purchase request →</Link></p></Card>
          )}
          {(expiring ?? []).length > 0 && (
            <Card className="border-amber-200"><CardHeader title="Expiring soon" />
              <ul className="divide-y divide-line text-sm">{(expiring as { batch_id: string; batch_no: string; product: string; location: string; qty: number; days_left: number }[]).slice(0, 8).map((x, i) => (
                <li key={i} className="flex justify-between px-5 py-2"><span><Link href={`/production/${x.batch_id}`} className="text-ola-700 hover:underline">{x.batch_no}</Link> {x.product} · {x.location}</span>
                  <span className={x.days_left < 0 ? "font-semibold text-red-700" : "text-amber-800"}>{formatQty(x.qty)} · {x.days_left < 0 ? "expired" : `${x.days_left} days`}</span></li>))}</ul></Card>
          )}
        </div>
      )}
      <Card className="mb-6">
        <CardHeader title="Sellable stock by location" />
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

      <div className="mb-6 grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Products by status" description="Only available stock can be picked, transferred or sold." />
          <Table>
            <thead><tr><Th>Product</Th><Th className="text-right">Available</Th><Th className="text-right">QC hold</Th><Th className="text-right">Quarantine</Th><Th className="text-right">Value</Th></tr></thead>
            <tbody>{fg.map((x) => (
              <tr key={x.product_id}><Td className="font-medium">{x.name}{x.low && <Badge tone="red" className="ml-2">Low</Badge>}</Td>
                <Td className="num text-right">{formatQty(x.available)}</Td>
                <Td className={`num text-right ${Number(x.qc_hold) ? "text-amber-700" : "text-muted"}`}>{formatQty(x.qc_hold)}</Td>
                <Td className={`num text-right ${Number(x.quarantine) ? "text-red-700" : "text-muted"}`}>{formatQty(x.quarantine)}</Td>
                <Td className="num text-right">{formatLKR(x.value)}</Td></tr>))}</tbody>
          </Table>
        </Card>
        <Card>
          <CardHeader title="Materials" description="Caps, labels, chemicals and parts." actions={<Link href="/materials" className="text-sm text-ola-700 hover:underline">All materials →</Link>} />
          {mats.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No materials set up yet.</p> : (
            <Table>
              <thead><tr><Th>Material</Th><Th className="text-right">Available</Th><Th className="text-right">Value</Th></tr></thead>
              <tbody>{mats.map((x) => (
                <tr key={x.product_id}><Td>{x.name}{x.low && <Badge tone="red" className="ml-2">Low</Badge>}</Td>
                  <Td className="num text-right">{formatQty(x.available)} <span className="text-xs text-muted">{x.unit}</span></Td><Td className="num text-right">{formatLKR(x.value)}</Td></tr>))}</tbody>
            </Table>
          )}
        </Card>
      </div>

      {manage && (
        <div className="mb-6 grid gap-6 lg:grid-cols-2">
          <Card><CardHeader title="Opening stock" description="Stock counted at go-live. Water from now on comes through Production; materials through Purchasing." /><CardBody><ReceiveForm locations={stores} products={allItems} /></CardBody></Card>
          <Card>
            <CardHeader title="Transfer & count" actions={
              <FormDialog trigger="Stock count / adjust" title="Stock count" description="Enter what you physically counted. The difference is posted and audited." submitLabel="Save count" action={adjustStock}>
                <Field label="Location" htmlFor="adj-loc"><Select id="adj-loc" name="location">{stores.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
                <Field label="Item" htmlFor="adj-p"><Select id="adj-p" name="product_id">{allItems.map((p) => <option key={p.id} value={p.id}>{p.name}{p.finished ? "" : ` (${p.unit})`}</option>)}</Select></Field>
                <Field label="Counted quantity (available only)" htmlFor="adj-c" required><Input id="adj-c" name="counted" type="number" min={0} step="any" required /></Field>
                <Field label="Reason" htmlFor="adj-r" required><Input id="adj-r" name="reason" required placeholder="e.g. Monthly count, 3 bottles leaking" /></Field>
              </FormDialog>
            } />
            <CardBody><TransferForm locations={stores} products={allItems} /></CardBody>
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
                <Td>{humanize(t.txn_type)}{(t.batch as unknown as { batch_no: string } | null)?.batch_no && <span className="ml-1 font-mono text-xs text-muted">{(t.batch as unknown as { batch_no: string }).batch_no}</span>}{t.reason && <span className="block text-xs text-muted">{t.reason}</span>}</Td>
                <Td>{(t.product as unknown as { name: string })?.name}</Td>
                <Td>{t.from_location ? locName[t.from_location] ?? "Vehicle" : "In"} → {t.to_location ? locName[t.to_location] ?? "Vehicle" : "Out"}</Td>
                <Td className="num text-right">{formatQty(t.qty)}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </Card>
    </>
  );
}
