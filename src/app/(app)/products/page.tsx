import type { Metadata } from "next";
import { Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { CUSTOMER_TYPES } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { PriceEditor } from "./price-editor";
import { saveProduct, setTaxRate, setBottleValue, saveCustomerTypeDefault } from "./actions";

export const metadata: Metadata = { title: "Products & Prices" };

type Product = {
  id: string; sku: string; name: string; category: string; size_label: string | null; unit: string; units_per_pack: number;
  barcode: string | null; is_returnable: boolean; bottle_type_id: string | null; tax_code: string | null; cost_price: number;
  sort_order: number; is_active: boolean; shelf_life_days: number | null; reorder_level: number;
};

function latest<T extends { effective_from: string }>(rows: T[], today: string) {
  return rows.filter((r) => r.effective_from <= today).sort((a, b) => b.effective_from.localeCompare(a.effective_from))[0];
}
function next<T extends { effective_from: string }>(rows: T[], today: string) {
  return rows.filter((r) => r.effective_from > today).sort((a, b) => a.effective_from.localeCompare(b.effective_from))[0];
}

export default async function ProductsPage() {
  const access = await requirePermission("products.view");
  const supabase = await createClient();
  const today = todayISO();
  const [{ data: products }, { data: lists }, { data: items }, { data: taxCodes }, { data: taxRates }, { data: types }, { data: companies }, { data: values }, { data: typeDefaults }] =
    await Promise.all([
      supabase.from("products").select("*").eq("item_type", "finished_good").order("sort_order").order("name"),
      supabase.from("price_lists").select("id, code, name, prices_include_tax").eq("is_active", true).order("name"),
      supabase.from("price_list_items").select("price_list_id, product_id, unit_price, effective_from"),
      supabase.from("tax_codes").select("code, name").eq("is_active", true),
      supabase.from("tax_rates").select("tax_code, rate_percent, effective_from"),
      supabase.from("bottle_types").select("id, code, name").eq("is_active", true),
      supabase.from("bottle_companies").select("id, name, is_own").eq("is_active", true).order("is_own", { ascending: false }).order("name"),
      supabase.from("bottle_values").select("bottle_type_id, company_id, deposit_amount, replacement_value, external_charge, effective_from"),
      supabase.from("customer_type_defaults").select("*"),
    ]);

  const current: Record<string, Record<string, number>> = {};
  (lists ?? []).forEach((l) => {
    current[l.id] = {};
    (products ?? []).forEach((p) => {
      const r = latest((items ?? []).filter((i) => i.price_list_id === l.id && i.product_id === p.id), today);
      if (r) current[l.id][p.id] = Number(r.unit_price);
    });
  });
  const canManage = can(access, "products.manage");
  const canPrice = can(access, "prices.manage");
  const vatRate = latest((taxRates ?? []).filter((r) => r.tax_code === "VAT"), today);
  const ownId = companies?.find((c) => c.is_own)?.id;
  const ownDeposit = types?.[0] ? latest((values ?? []).filter((v) => v.bottle_type_id === types[0].id && v.company_id === ownId), today) : undefined;
  const missingPrices = (products ?? []).filter((p) => p.is_active && current[lists?.find((l) => l.code === "RETAIL")?.id ?? ""]?.[p.id] === undefined);

  const productFields = (p?: Product) => (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="SKU" htmlFor={`sku-${p?.id ?? "new"}`} required hint="Capitals, numbers, dots and dashes">
          <Input id={`sku-${p?.id ?? "new"}`} name="sku" defaultValue={p?.sku} required disabled={!!p} />
        </Field>
        <Field label="Name" htmlFor={`name-${p?.id ?? "new"}`} required>
          <Input id={`name-${p?.id ?? "new"}`} name="name" defaultValue={p?.name} required />
        </Field>
        <Field label="Size" htmlFor={`size-${p?.id ?? "new"}`}>
          <Input id={`size-${p?.id ?? "new"}`} name="size_label" defaultValue={p?.size_label ?? ""} placeholder="e.g. 19 L" />
        </Field>
        <Field label="Unit" htmlFor={`unit-${p?.id ?? "new"}`}>
          <Select id={`unit-${p?.id ?? "new"}`} name="unit" defaultValue={p?.unit ?? "bottle"}>
            <option value="bottle">Bottle</option>
            <option value="case">Case</option>
            <option value="pack">Pack</option>
            <option value="unit">Unit</option>
          </Select>
        </Field>
        <Field label="Units per pack" htmlFor={`upp-${p?.id ?? "new"}`}>
          <Input id={`upp-${p?.id ?? "new"}`} name="units_per_pack" type="number" min={1} defaultValue={p?.units_per_pack ?? 1} />
        </Field>
        <Field label="Product barcode" htmlFor={`bc-${p?.id ?? "new"}`} hint="EAN on the packaging, if any">
          <Input id={`bc-${p?.id ?? "new"}`} name="barcode" defaultValue={p?.barcode ?? ""} />
        </Field>
        <Field label="Tax" htmlFor={`tax-${p?.id ?? "new"}`}>
          <Select id={`tax-${p?.id ?? "new"}`} name="tax_code" defaultValue={p?.tax_code ?? "VAT"}>
            {taxCodes?.map((t) => (
              <option key={t.code} value={t.code}>
                {t.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Average cost (Rs.)" htmlFor={`cost-${p?.id ?? "new"}`} hint="Set before go-live; afterwards production and purchases keep it up to date">
          <Input id={`cost-${p?.id ?? "new"}`} name="cost_price" type="number" step="0.0001" min={0} defaultValue={p?.cost_price ?? 0} />
        </Field>
        <Field label="Shelf life (days)" htmlFor={`sl-${p?.id ?? "new"}`} hint="Sets the expiry date of each production batch">
          <Input id={`sl-${p?.id ?? "new"}`} name="shelf_life_days" type="number" min={1} defaultValue={p?.shelf_life_days ?? ""} />
        </Field>
        <Field label="Reorder / low-stock level" htmlFor={`rl-${p?.id ?? "new"}`} hint="Warn when stock falls to this">
          <Input id={`rl-${p?.id ?? "new"}`} name="reorder_level" type="number" min={0} defaultValue={p?.reorder_level ?? 0} />
        </Field>
        <Field label="Returnable bottle type" htmlFor={`bt-${p?.id ?? "new"}`} hint="Tick 'Returnable' below too">
          <Select id={`bt-${p?.id ?? "new"}`} name="bottle_type_id" defaultValue={p?.bottle_type_id ?? ""}>
            <option value="">None</option>
            {types?.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Sort order" htmlFor={`so-${p?.id ?? "new"}`}>
          <Input id={`so-${p?.id ?? "new"}`} name="sort_order" type="number" defaultValue={p?.sort_order ?? 0} />
        </Field>
      </div>
      <div className="flex flex-wrap gap-6 text-sm">
        <label className="flex items-center gap-2">
          <input type="checkbox" name="is_returnable" defaultChecked={p?.is_returnable} /> Returnable bottle (tracked in the bottle ledger)
        </label>
        {p && (
          <label className="flex items-center gap-2">
            <input type="checkbox" name="is_active" defaultChecked={p.is_active} /> Active
          </label>
        )}
      </div>
      {p && (
        <Field label="Reason for change" htmlFor={`r-${p.id}`}>
          <Input id={`r-${p.id}`} name="reason" />
        </Field>
      )}
    </>
  );

  return (
    <>
      <PageHeader
        title="Products & Prices"
        description="Products for sale, price lists, VAT and bottle deposits. Every price change takes effect from a date and the history is kept. Materials (caps, labels, chemicals) are under Production → Materials."
        actions={
          canManage && (
            <FormDialog trigger={<><Plus className="h-4 w-4" /> New product</>} triggerVariant="primary" triggerSize="md" title="New product" submitLabel="Add product" action={saveProduct} wide>
              {productFields()}
            </FormDialog>
          )
        }
      />

      {(!vatRate || missingPrices.length > 0 || !ownDeposit) && (
        <Alert tone="warning" className="mb-6">
          <strong>Before taking orders:</strong>
          <ul className="mt-1 list-disc pl-5">
            {!vatRate && <li>Set the VAT rate (Tax section below).</li>}
            {missingPrices.length > 0 && <li>Set Retail prices for: {missingPrices.map((p) => p.name).join(", ")}.</li>}
            {!ownDeposit && <li>Set the 19L bottle deposit and replacement value (Bottle values below).</li>}
          </ul>
        </Alert>
      )}

      <div className="space-y-6">
        <Card>
          <CardHeader title="Products" />
          <Table>
            <thead>
              <tr>
                <Th>Product</Th>
                <Th>Unit</Th>
                <Th>Tax</Th>
                <Th className="text-right">Cost</Th>
                {lists?.map((l) => (
                  <Th key={l.id} className="text-right">
                    {l.name}
                  </Th>
                ))}
                <Th />
              </tr>
            </thead>
            <tbody>
              {(products as Product[] | null)?.map((p) => (
                <tr key={p.id} className={p.is_active ? "" : "opacity-50"}>
                  <Td>
                    <span className="font-medium">{p.name}</span>
                    <span className="block font-mono text-xs text-muted">{p.sku}</span>
                    {p.is_returnable && <Badge tone="blue" className="mt-1">Returnable</Badge>}
                  </Td>
                  <Td>
                    {p.unit}
                    {p.units_per_pack > 1 && ` × ${p.units_per_pack}`}
                  </Td>
                  <Td>{p.tax_code}</Td>
                  <Td className="num text-right">{formatLKR(p.cost_price)}{p.shelf_life_days && <span className="block text-xs text-muted">{p.shelf_life_days} days shelf life</span>}</Td>
                  {lists?.map((l) => (
                    <Td key={l.id} className="num text-right">
                      {current[l.id]?.[p.id] !== undefined ? formatLKR(current[l.id][p.id]) : <span className="text-muted">—</span>}
                    </Td>
                  ))}
                  <Td className="text-right">
                    {canManage && (
                      <FormDialog trigger="Edit" triggerVariant="ghost" title={`Edit ${p.name}`} submitLabel="Save" action={saveProduct} hidden={{ id: p.id, sku: p.sku }} wide>
                        {productFields(p)}
                      </FormDialog>
                    )}
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </Card>

        {canPrice && (
          <Card>
            <CardHeader title="Change prices" description="Choose a price list, enter only the prices that change." />
            <CardBody>
              <PriceEditor products={(products ?? []).filter((p) => p.is_active)} priceLists={lists ?? []} current={current} today={today} />
            </CardBody>
          </Card>
        )}

        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader title="Tax" description="Rates apply from a date. Ask your accountant to confirm them." />
            <ul className="divide-y divide-line">
              {taxCodes?.map((t) => {
                const r = latest((taxRates ?? []).filter((x) => x.tax_code === t.code), today);
                const n = next((taxRates ?? []).filter((x) => x.tax_code === t.code), today);
                return (
                  <li key={t.code} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm">
                    <span>
                      <span className="font-medium">{t.name}</span> <span className="text-muted">({t.code})</span>
                      {n && <Badge tone="amber" className="ml-2">{n.rate_percent}% from {formatDate(n.effective_from)}</Badge>}
                    </span>
                    <span className="flex items-center gap-3">
                      <span className="num font-semibold">{r ? `${Number(r.rate_percent)}%` : <span className="text-red-700">Not set</span>}</span>
                      {canPrice && (
                        <FormDialog trigger="Set rate" title={`${t.name} rate`} submitLabel="Save rate" action={setTaxRate} hidden={{ code: t.code }}>
                          <Field label="Rate (%)" htmlFor={`rate-${t.code}`} required>
                            <Input id={`rate-${t.code}`} name="rate" type="number" step="0.001" min={0} max={100} required />
                          </Field>
                          <Field label="Applies from" htmlFor={`eff-${t.code}`} required>
                            <Input id={`eff-${t.code}`} name="effective_from" type="date" min={today} defaultValue={today} required />
                          </Field>
                          <Field label="Reason" htmlFor={`trr-${t.code}`} required>
                            <Input id={`trr-${t.code}`} name="reason" required />
                          </Field>
                        </FormDialog>
                      )}
                    </span>
                  </li>
                );
              })}
            </ul>
          </Card>

          <Card>
            <CardHeader title="Bottle values" description="Deposit charged to deposit customers, replacement value for losses, and the charge for other companies' bottles." />
            <Table>
              <thead>
                <tr>
                  <Th>Bottle</Th>
                  <Th className="text-right">Deposit</Th>
                  <Th className="text-right">Replacement</Th>
                  <Th className="text-right">Ext. charge</Th>
                  <Th />
                </tr>
              </thead>
              <tbody>
                {types?.flatMap((t) =>
                  (companies ?? []).map((c) => {
                    const v = latest((values ?? []).filter((x) => x.bottle_type_id === t.id && x.company_id === c.id), today);
                    return (
                      <tr key={`${t.id}-${c.id}`}>
                        <Td>
                          {c.name} {t.name}
                        </Td>
                        <Td className="num text-right">{c.is_own ? (v ? formatLKR(v.deposit_amount) : "—") : ""}</Td>
                        <Td className="num text-right">{v ? formatLKR(v.replacement_value) : "—"}</Td>
                        <Td className="num text-right">{!c.is_own ? (v ? formatLKR(v.external_charge) : "—") : ""}</Td>
                        <Td className="text-right">
                          {canPrice && (
                            <FormDialog trigger="Set" triggerVariant="ghost" title={`${c.name} ${t.name} values`} submitLabel="Save" action={setBottleValue}
                              hidden={{ bottle_type_id: t.id, company_id: c.id }}>
                              {c.is_own && (
                                <Field label="Deposit per bottle (Rs.)" htmlFor={`dep-${t.id}-${c.id}`} hint="0 = no deposit">
                                  <Input id={`dep-${t.id}-${c.id}`} name="deposit" type="number" min={0} step="0.01" defaultValue={v?.deposit_amount ?? 0} />
                                </Field>
                              )}
                              <Field label="Replacement value (Rs.)" htmlFor={`rep-${t.id}-${c.id}`} hint="Used for losses and exposure reports">
                                <Input id={`rep-${t.id}-${c.id}`} name="replacement" type="number" min={0} step="0.01" defaultValue={v?.replacement_value ?? 0} />
                              </Field>
                              {!c.is_own && (
                                <Field label="Charge when accepted with a charge (Rs.)" htmlFor={`ch-${t.id}-${c.id}`}>
                                  <Input id={`ch-${t.id}-${c.id}`} name="external_charge" type="number" min={0} step="0.01" defaultValue={v?.external_charge ?? 0} />
                                </Field>
                              )}
                              <Field label="Applies from" htmlFor={`bve-${t.id}-${c.id}`} required>
                                <Input id={`bve-${t.id}-${c.id}`} name="effective_from" type="date" min={today} defaultValue={today} required />
                              </Field>
                              <Field label="Reason" htmlFor={`bvr-${t.id}-${c.id}`} required>
                                <Input id={`bvr-${t.id}-${c.id}`} name="reason" required />
                              </Field>
                            </FormDialog>
                          )}
                        </Td>
                      </tr>
                    );
                  }),
                )}
              </tbody>
            </Table>
          </Card>
        </div>

        <Card>
          <CardHeader title="Customer type defaults" description="Applied when a new customer is created; each customer can be changed individually." />
          <Table>
            <thead>
              <tr>
                <Th>Type</Th>
                <Th>Bottles</Th>
                <Th className="text-right">Bottle limit</Th>
                <Th>Price list</Th>
                <Th className="text-right">Payment terms</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {CUSTOMER_TYPES.map(([code, label]) => {
                const d = typeDefaults?.find((t) => t.customer_type === code);
                if (!d) return null;
                return (
                  <tr key={code}>
                    <Td className="font-medium">{label}</Td>
                    <Td>{d.bottle_model === "deposit" ? "Deposit" : d.bottle_model === "loan" ? "Loan" : "No bottles"}</Td>
                    <Td className="num text-right">{d.bottle_model === "loan" ? d.allowed_bottles : "—"}</Td>
                    <Td>{lists?.find((l) => l.id === d.price_list_id)?.name ?? "—"}</Td>
                    <Td className="num text-right">{d.payment_terms_days === 0 ? "Cash" : `${d.payment_terms_days} days`}</Td>
                    <Td className="text-right">
                      {can(access, "customers.credit") && (
                        <FormDialog trigger="Edit" triggerVariant="ghost" title={`${label} defaults`} submitLabel="Save" action={saveCustomerTypeDefault} hidden={{ customer_type: code }}>
                          <Field label="Bottles" htmlFor={`bm-${code}`}>
                            <Select id={`bm-${code}`} name="bottle_model" defaultValue={d.bottle_model}>
                              <option value="deposit">Deposit per bottle</option>
                              <option value="loan">Loan, up to a limit</option>
                              <option value="none">No returnable bottles</option>
                            </Select>
                          </Field>
                          <Field label="Bottle limit (loan)" htmlFor={`al-${code}`}>
                            <Input id={`al-${code}`} name="allowed_bottles" type="number" min={0} defaultValue={d.allowed_bottles} />
                          </Field>
                          <Field label="Price list" htmlFor={`pl-${code}`}>
                            <Select id={`pl-${code}`} name="price_list_id" defaultValue={d.price_list_id ?? ""}>
                              {lists?.map((l) => (
                                <option key={l.id} value={l.id}>
                                  {l.name}
                                </option>
                              ))}
                            </Select>
                          </Field>
                          <Field label="Payment terms (days, 0 = cash)" htmlFor={`pt-${code}`}>
                            <Input id={`pt-${code}`} name="payment_terms_days" type="number" min={0} defaultValue={d.payment_terms_days} />
                          </Field>
                          <Field label="Reason" htmlFor={`ctr-${code}`} required>
                            <Input id={`ctr-${code}`} name="reason" required />
                          </Field>
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
