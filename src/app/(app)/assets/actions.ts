"use server";

import { redirect } from "next/navigation";
import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";
import { num } from "@/lib/lines";

const P = (id?: string) => ["/assets", "/fleet", "/accounting", "/", ...(id ? [`/assets/${id}`] : [])];

export async function registerAsset(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const funding = str(f, "funding");
  const res = await runRpc<{ asset_id: string; asset_no: string }>("register_asset", {
    p: { name: str(f, "name"), category_id: str(f, "category_id"), serial_no: str(f, "serial_no"), description: str(f, "description"),
      location_id: str(f, "location_id") || null, responsible_employee_id: str(f, "responsible_employee_id") || null, supplier_name: str(f, "supplier_name"),
      purchase_date: str(f, "purchase_date"), cost: num(str(f, "cost")), residual_value: num(str(f, "residual_value")),
      useful_life_months: num(str(f, "useful_life_years")) !== null ? Math.round(Number(str(f, "useful_life_years")) * 12) : null,
      warranty_until: str(f, "warranty_until") || null, funding, money_account_id: funding === "paid" ? str(f, "money_account_id") : null,
      opening_accumulated: funding === "opening" ? num(str(f, "opening_accumulated")) : null, vehicle_id: str(f, "vehicle_id") || null },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Asset ${d.asset_no} registered.`, P());
  if (!res.ok) return res;
  redirect(`/assets/${res.data?.asset_id}`);
}

export async function runDepreciation(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const [y, m] = str(f, "month").split("-").map(Number);
  return runRpc<{ run_no: string; assets: number; total: number }>("run_depreciation", { p_year: y, p_month: m },
    (d) => `${d.run_no}: Rs. ${Number(d.total).toFixed(2)} for ${d.assets} asset(s).`, P());
}

export async function updateAsset(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "asset_id");
  return runRpc("update_asset", { p_id: id, p: { name: str(f, "name"), serial_no: str(f, "serial_no"), description: str(f, "description"),
    location_id: str(f, "location_id") || null, responsible_employee_id: str(f, "responsible_employee_id") || null,
    warranty_until: str(f, "warranty_until") || null, supplier_name: str(f, "supplier_name") }, p_reason: str(f, "reason") || null }, "Saved.", P(id));
}

export async function disposeAsset(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "asset_id");
  return runRpc<{ book_value: number; gain: number }>("dispose_asset", { p_id: id, p: { disposed_on: str(f, "disposed_on") || null,
    proceeds: num(str(f, "proceeds")) ?? 0, money_account_id: str(f, "money_account_id") || null, reason: str(f, "reason") },
    p_client_txn_id: str(f, "client_txn_id") },
    (d) => `Disposed. ${Number(d.gain) >= 0 ? "Gain" : "Loss"} of Rs. ${Math.abs(Number(d.gain)).toFixed(2)} against the book value.`, P(id));
}

export async function recordMaintenance(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "asset_id");
  const method = str(f, "pay_method") || "cash";
  return runRpc<{ status: string }>("record_asset_maintenance", { p_asset: id, p: { date: str(f, "date") || null, description: str(f, "description"),
    vendor: str(f, "vendor"), cost: num(str(f, "cost")), vat_amount: num(str(f, "vat_amount")), pay_method: method,
    money_account_id: method === "on_credit" ? null : str(f, `account_${method}`) || null, reference: str(f, "reference") },
    p_client_txn_id: str(f, "client_txn_id") },
    (d) => (d.status === "pending_approval" ? "Recorded — over the limit, waiting for approval in Expenses." : "Maintenance recorded."), [...P(id), "/expenses"]);
}

export async function saveAssetCategory(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_asset_category", { p_id: null, p: { code: str(f, "code"), name: str(f, "name"), asset_account_id: str(f, "asset_account_id"),
    method: str(f, "method"), useful_life_months: num(str(f, "life_years")) !== null ? Math.round(Number(str(f, "life_years")) * 12) : null,
    rate_percent: num(str(f, "rate_percent")), residual_percent: num(str(f, "residual_percent")) }, p_reason: "New asset category" }, "Category added.", P());
}
