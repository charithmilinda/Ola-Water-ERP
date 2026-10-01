import type { Metadata } from "next";
import { Plus, Layers } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatLKR, formatQty } from "@/lib/format";
import { ITEM_TYPES, UNITS } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { LineEditor } from "@/components/ui/line-editor";
import { saveMaterial, saveBom } from "./actions";

export const metadata: Metadata = { title: "Materials" };

type Material = { id: string; sku: string; name: string; item_type: string; unit: string; size_label: string | null; tax_code: string | null;
  cost_price: number; reorder_level: number; is_active: boolean };
type Summary = { product_id: string; available: number; value: number; low: boolean; by_location: { location: string; status: string; qty: number }[] };

export default async function MaterialsPage() {
  const access = await requirePermission(["products.view", "production.view", "procurement.view"]);
  const supabase = await createClient();
  const [{ data: mats }, { data: summary }, { data: products }, { data: bom }, { data: taxCodes }] = await Promise.all([
    supabase.from("products").select("id, sku, name, item_type, unit, size_label, tax_code, cost_price, reorder_level, is_active")
      .neq("item_type", "finished_good").order("item_type").order("name"),
    supabase.rpc("stock_summary", { p_item_type: "materials" }),
    supabase.from("products").select("id, name, sku").eq("item_type", "finished_good").eq("is_active", true).order("sort_order"),
    supabase.from("product_materials").select("product_id, material_id, qty_per_unit"),
    supabase.from("tax_codes").select("code, name").eq("is_active", true),
  ]);
  const materials = (mats ?? []) as Material[];
  const sum = Object.fromEntries(((summary ?? []) as Summary[]).map((s) => [s.product_id, s]));
  const canManage = can(access, "products.manage");
  const canBom = can(access, ["products.manage", "production.manage"]);
  const typeLabel = Object.fromEntries(ITEM_TYPES.map(([k, v]) => [k, v.split(" (")[0]]));
  const matName = Object.fromEntries(materials.map((m) => [m.id, m]));
  const options = materials.filter((m) => m.is_active).map((m) => ({ id: m.id, name: m.name, unit: m.unit }));

  const fields = (m?: Material) => {
    const k = m?.id ?? "new";
    return (
      <>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Code (SKU)" htmlFor={`msku-${k}`} required hint="Capitals, numbers, dots and dashes">
            <Input id={`msku-${k}`} name="sku" defaultValue={m?.sku} required disabled={!!m} placeholder="e.g. CAP-19L" />
          </Field>
          <Field label="Name" htmlFor={`mname-${k}`} required>
            <Input id={`mname-${k}`} name="name" defaultValue={m?.name} required />
          </Field>
          <Field label="Type" htmlFor={`mtype-${k}`}>
            <Select id={`mtype-${k}`} name="item_type" defaultValue={m?.item_type ?? "packaging"}>
              {ITEM_TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </Select>
          </Field>
          <Field label="Unit of measure" htmlFor={`munit-${k}`}>
            <Select id={`munit-${k}`} name="unit" defaultValue={m?.unit ?? "piece"}>
              {UNITS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </Select>
          </Field>
          <Field label="Size / spec" htmlFor={`msize-${k}`}>
            <Input id={`msize-${k}`} name="size_label" defaultValue={m?.size_label ?? ""} placeholder="e.g. 55 mm, blue" />
          </Field>
          <Field label="VAT when bought" htmlFor={`mtax-${k}`} hint="Used to suggest VAT on purchase orders">
            <Select id={`mtax-${k}`} name="tax_code" defaultValue={m?.tax_code ?? ""}>
              <option value="">No VAT</option>
              {taxCodes?.map((t) => <option key={t.code} value={t.code}>{t.name}</option>)}
            </Select>
          </Field>
          <Field label="Average cost (Rs.)" htmlFor={`mcost-${k}`} hint="Only for go-live; purchases update it automatically">
            <Input id={`mcost-${k}`} name="cost_price" type="number" step="0.0001" min={0} defaultValue={m?.cost_price ?? 0} />
          </Field>
          <Field label="Reorder level" htmlFor={`mrl-${k}`} hint="Warn when stock falls to this">
            <Input id={`mrl-${k}`} name="reorder_level" type="number" step="any" min={0} defaultValue={m?.reorder_level ?? 0} />
          </Field>
        </div>
        {m && (
          <>
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={m.is_active} /> Active</label>
            <Field label="Reason for change" htmlFor={`mr-${k}`}><Input id={`mr-${k}`} name="reason" /></Field>
          </>
        )}
      </>
    );
  };

  return (
    <>
      <PageHeader title="Materials" description="Caps, labels, preforms, chemicals, filters and spare parts. Bought through Purchasing, used by Production, counted like any other stock."
        actions={canManage && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New material</>} triggerVariant="primary" triggerSize="md" title="New material" submitLabel="Add material"
            action={saveMaterial} wide>
            {fields()}
          </FormDialog>
        )} />

      <div className="space-y-6">
        <Card>
          <CardHeader title="Materials in stock" description="Available quantity across all stores, value at average cost." />
          {materials.length === 0 ? <EmptyState icon={Layers} title="No materials yet" description="Add caps, labels and chemicals with New material." /> : (
            <Table>
              <thead><tr><Th>Material</Th><Th>Type</Th><Th className="text-right">In stock</Th><Th className="text-right">Reorder at</Th>
                <Th className="text-right">Avg cost</Th><Th className="text-right">Value</Th><Th /></tr></thead>
              <tbody>
                {materials.map((m) => {
                  const s = sum[m.id];
                  return (
                    <tr key={m.id} className={m.is_active ? "" : "opacity-50"}>
                      <Td><span className="font-medium">{m.name}</span><span className="block font-mono text-xs text-muted">{m.sku}{m.size_label && ` · ${m.size_label}`}</span></Td>
                      <Td>{typeLabel[m.item_type] ?? m.item_type}</Td>
                      <Td className="num text-right">{formatQty(s?.available ?? 0)} <span className="text-xs text-muted">{m.unit}</span>
                        {s?.low && <Badge tone="red" className="ml-2">Low</Badge>}
                        {s?.by_location?.length > 1 && <span className="block text-xs text-muted">{s.by_location.filter((b) => b.status === "available").map((b) => `${b.location}: ${formatQty(b.qty)}`).join(" · ")}</span>}</Td>
                      <Td className="num text-right">{Number(m.reorder_level) > 0 ? formatQty(m.reorder_level) : "—"}</Td>
                      <Td className="num text-right">{formatLKR(m.cost_price)}</Td>
                      <Td className="num text-right">{formatLKR(s?.value ?? 0)}</Td>
                      <Td className="text-right">
                        {canManage && (
                          <FormDialog trigger="Edit" triggerVariant="ghost" title={`Edit ${m.name}`} submitLabel="Save" action={saveMaterial}
                            hidden={{ id: m.id, sku: m.sku }} wide>
                            {fields(m)}
                          </FormDialog>
                        )}
                      </Td>
                    </tr>
                  );
                })}
              </tbody>
            </Table>
          )}
        </Card>

        <Card>
          <CardHeader title="Bills of materials" description="What one unit of each product uses. Production suggests these quantities; the operator enters what was actually used." />
          <Table>
            <thead><tr><Th>Product</Th><Th>Uses per unit</Th><Th className="text-right">Material cost per unit</Th><Th /></tr></thead>
            <tbody>
              {products?.map((p) => {
                const rows = (bom ?? []).filter((b) => b.product_id === p.id);
                const cost = rows.reduce((a, b) => a + Number(b.qty_per_unit) * Number(matName[b.material_id]?.cost_price ?? 0), 0);
                return (
                  <tr key={p.id}>
                    <Td className="font-medium">{p.name}</Td>
                    <Td>{rows.length === 0 ? <span className="text-muted">Not set</span> : rows.map((b) => (
                      <span key={b.material_id} className="mr-3 inline-block">{formatQty(b.qty_per_unit)} {matName[b.material_id]?.unit} {matName[b.material_id]?.name}</span>))}</Td>
                    <Td className="num text-right">{rows.length ? formatLKR(cost) : "—"}</Td>
                    <Td className="text-right">
                      {canBom && (
                        <FormDialog trigger={rows.length ? "Edit" : "Set"} triggerVariant="ghost" title={`Bill of materials — ${p.name}`}
                          description="Quantity of each material for ONE unit." submitLabel="Save" action={saveBom} hidden={{ product_id: p.id }} wide>
                          <LineEditor name="lines" items={options} itemLabel="Material" addLabel="Add material"
                            columns={[{ key: "qty_per_unit", label: "Per unit", type: "number", step: "any", min: 0 }]}
                            initial={rows.map((b) => ({ item_id: b.material_id, qty_per_unit: String(Number(b.qty_per_unit)) }))} />
                          <Field label="Reason" htmlFor={`bomr-${p.id}`}><Input id={`bomr-${p.id}`} name="reason" placeholder="e.g. New cap supplier" /></Field>
                        </FormDialog>
                      )}
                    </Td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        </Card>
      </div>
    </>
  );
}
