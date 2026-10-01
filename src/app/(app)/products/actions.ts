"use server";

import { runRpc, runRpcOrApproval, payload } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const P = ["/products"];

export async function saveProduct(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_product", {
    p_id: id,
    p: {
      sku: str(f, "sku"),
      name: str(f, "name"),
      category: str(f, "category") || "water",
      size_label: str(f, "size_label"),
      unit: str(f, "unit") || (str(f, "item_type") && str(f, "item_type") !== "finished_good" ? "piece" : "bottle"),
      units_per_pack: str(f, "units_per_pack") || "1",
      barcode: str(f, "barcode"),
      is_returnable: f.get("is_returnable") === "on",
      bottle_type_id: str(f, "bottle_type_id"),
      tax_code: str(f, "tax_code"),
      cost_price: str(f, "cost_price") || "0",
      sort_order: str(f, "sort_order") || "0",
      is_active: id ? f.get("is_active") === "on" : true,
      item_type: str(f, "item_type") || "finished_good",
      reorder_level: str(f, "reorder_level") || "0",
      shelf_life_days: str(f, "shelf_life_days") || null,
    },
    p_reason: str(f, "reason") || (id ? null : "New product"),
  }, id ? "Saved." : "Added.", [...P, "/materials", "/inventory"]);
}

export async function setPrices(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ price_list_id: string; prices: { product_id: string; unit_price: string }[]; effective_from: string; reason: string }>(f);
  if (!d.reason?.trim()) return { ok: false, message: "A reason is required to change prices." };
  return runRpcOrApproval<number>("set_prices", {
    p_price_list: d.price_list_id,
    p_prices: d.prices.filter((x) => x.unit_price !== ""),
    p_effective_from: d.effective_from,
    p_reason: d.reason,
  }, (n) => (n === 0 ? "No prices changed." : `${n} price(s) saved.`), P, d.reason);
}

export async function setTaxRate(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("set_tax_rate", {
    p_code: str(f, "code"),
    p_rate: Number(str(f, "rate")),
    p_effective_from: str(f, "effective_from"),
    p_reason: str(f, "reason"),
  }, "Tax rate saved.", P);
}

export async function setBottleValue(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("set_bottle_value", {
    p_bottle_type: str(f, "bottle_type_id"),
    p_company: str(f, "company_id"),
    p_deposit: Number(str(f, "deposit") || 0),
    p_replacement: Number(str(f, "replacement") || 0),
    p_external_charge: Number(str(f, "external_charge") || 0),
    p_effective_from: str(f, "effective_from"),
    p_reason: str(f, "reason"),
  }, "Bottle values saved.", [...P, "/bottles"]);
}

export async function savePriceList(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_price_list", {
    p_id: id, p_code: str(f, "code"), p_name: str(f, "name"),
    p_includes_tax: f.get("prices_include_tax") === "on", p_active: true, p_reason: str(f, "reason") || "New price list",
  }, "Price list saved.", P);
}

export async function saveCustomerTypeDefault(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_customer_type_default", {
    p_type: str(f, "customer_type"), p_bottle_model: str(f, "bottle_model"), p_allowed: Number(str(f, "allowed_bottles") || 0),
    p_price_list: str(f, "price_list_id") || null, p_terms: Number(str(f, "payment_terms_days") || 0), p_reason: str(f, "reason"),
  }, "Defaults saved. They apply to new customers.", P);
}
