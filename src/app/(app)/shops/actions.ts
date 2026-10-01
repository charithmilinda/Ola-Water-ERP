"use server";

import { redirect } from "next/navigation";
import { runRpc, payload } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

function shopPayload(f: FormData) {
  return {
    code: str(f, "code"), name: str(f, "name"), operating_model: str(f, "operating_model"), owner_name: str(f, "owner_name"),
    contact_person: str(f, "contact_person"), phone: str(f, "phone"), email: str(f, "email"), address: str(f, "address"),
    city: str(f, "city"), district: str(f, "district"), territory: str(f, "territory"), gps_lat: str(f, "gps_lat"), gps_lng: str(f, "gps_lng"),
    retail_price_list_id: str(f, "retail_price_list_id"), transfer_price_list_id: str(f, "transfer_price_list_id"),
    credit_limit: str(f, "credit_limit"), payment_terms_days: str(f, "payment_terms_days"),
    commission_percent: str(f, "commission_percent"), status: str(f, "status"), notes: str(f, "notes"),
  };
}

export async function createShop(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<string>("save_water_shop", { p_id: null, p: shopPayload(f), p_reason: "New water shop" }, "Shop created.", ["/shops"]);
  if (!res.ok) return res;
  redirect(`/shops/${res.data}`);
}

export async function updateShop(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id");
  return runRpc("save_water_shop", { p_id: id, p: shopPayload(f), p_reason: str(f, "reason") || null }, "Shop saved.", [`/shops/${id}`, "/shops"]);
}

export async function createRequest(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const shop = str(f, "shop_id");
  const lines = [...f.entries()].filter(([k, v]) => k.startsWith("qty:") && Number(v) > 0).map(([k, v]) => ({ product_id: k.slice(4), qty: Number(v) }));
  if (lines.length === 0) return { ok: false, message: "Enter a quantity for at least one product." };
  return runRpc<{ request_no: string }>("create_stock_request", {
    p_shop: shop, p_lines: lines, p_needed_by: str(f, "needed_by") || null, p_notes: str(f, "notes"), p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Request ${d.request_no} sent to the warehouse.`, [`/shops/${shop}`, "/shops/requests"]);
}

export async function receiveRequest(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const shop = str(f, "shop_id");
  const lines = [...f.entries()].filter(([k]) => k.startsWith("qty:")).map(([k, v]) => ({ product_id: k.slice(4), qty: Number(v || 0) }));
  return runRpc<{ differences: number; invoice_no: string | null }>("receive_stock_request", {
    p_id: str(f, "request_id"), p_lines: lines, p_notes: str(f, "notes"), p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Received.${d.differences ? ` ${d.differences} difference(s) reported to the warehouse.` : " Everything matched."}${d.invoice_no ? ` Invoice ${d.invoice_no} added to the shop's account.` : ""}`,
  [`/shops/${shop}`, "/shops/requests"]);
}

export async function withdrawRequest(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("reject_stock_request", { p_id: str(f, "request_id"), p_reason: str(f, "reason") }, "Request updated.",
    [`/shops/${str(f, "shop_id")}`, "/shops/requests"]);
}

export async function approveRequest(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const lines = [...f.entries()].filter(([k]) => k.startsWith("qty:")).map(([k, v]) => ({ product_id: k.slice(4), qty: Number(v || 0) }));
  return runRpc<{ warning: string | null }>("approve_stock_request", { p_id: str(f, "request_id"), p_lines: lines, p_note: str(f, "note") },
    (d) => (d.warning ? `Approved. Note: ${d.warning}` : "Approved — ready for the warehouse."), ["/shops/requests"]);
}

export async function dispatchRequest(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const lines = [...f.entries()].filter(([k]) => k.startsWith("qty:")).map(([k, v]) => ({ product_id: k.slice(4), qty: Number(v || 0) }));
  return runRpc<{ dispatch_no: string }>("dispatch_stock_request", { p_id: str(f, "request_id"), p_lines: lines, p_client_txn_id: str(f, "client_txn_id") },
    (d) => `Dispatched (${d.dispatch_no}). The shop confirms what arrives.`, ["/shops/requests", "/inventory"]);
}

export async function receiveShopBottles(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ shop_id: string; lines: { company_id: string; bottle_type_id: string; qty: string }[]; codes: string; notes: string }>(f);
  const codes = (d.codes ?? "").split(/[\s,;]+/).map((c) => c.trim().toUpperCase()).filter(Boolean);
  return runRpc<{ document_no: string; bottles: number }>("receive_shop_bottles", {
    p_shop: d.shop_id, p_lines: d.lines.filter((l) => Number(l.qty) > 0).map((l) => ({ ...l, qty: Number(l.qty) })), p_codes: codes,
    p_notes: d.notes, p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => `${r.document_no}: ${r.bottles} bottle(s) received from the shop.`, ["/shops/requests", "/bottles", "/bottles/external"]);
}

export async function settleShop(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const shop = str(f, "shop_id");
  return runRpc<{ settlement_no: string; expected: number; received: number; commission: number }>("create_shop_settlement", {
    p_shop: shop, p_from: str(f, "from"), p_to: str(f, "to"),
    p: { amount_received: Number(str(f, "amount") || 0), method: str(f, "method"), reference: str(f, "reference"), notes: str(f, "notes") },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Settlement ${d.settlement_no} saved.${Number(d.received) < Number(d.expected) ? " The shortfall was reported as an exception." : ""}`,
  [`/shops/${shop}`]);
}
