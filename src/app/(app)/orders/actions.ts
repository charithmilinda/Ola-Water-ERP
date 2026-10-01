"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { runRpc, runRpcOrApproval, isApproval, payload } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";
import { todayISO } from "@/lib/format";

export type CustomerHit = { id: string; name: string; customer_no: string; phone: string; status: string };
export type Pricing = {
  customer: { id: string; name: string; customer_no: string; bottle_model: string; allowed_bottles: number; status: string; credit_limit: number };
  addresses: { id: string; label: string; address_line: string; is_default: boolean }[];
  products: { id: string; name: string; sku: string; is_returnable: boolean; price: number | null }[];
  ola_bottles: number;
  outstanding: number;
  includes_tax: boolean;
};

export async function searchCustomers(q: string): Promise<CustomerHit[]> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("customer_list", { p_search: q, p_type: null, p_route: null, p_status: null, p_limit: 10, p_offset: 0 });
  return ((data ?? []) as CustomerHit[]).filter((c) => c.status !== "inactive");
}

export async function customerPricing(customerId: string): Promise<Pricing | null> {
  const supabase = await createClient();
  const { data: c } = await supabase.from("customers").select("id, name, customer_no, bottle_model, allowed_bottles, status, credit_limit, price_list_id").eq("id", customerId).maybeSingle();
  if (!c) return null;
  const today = todayISO();
  const [{ data: addresses }, { data: products }, { data: items }, { data: list }, { data: summary }] = await Promise.all([
    supabase.from("customer_addresses").select("id, label, address_line, is_default").eq("customer_id", customerId).eq("is_active", true),
    supabase.from("products").select("id, name, sku, is_returnable").eq("is_active", true).eq("item_type", "finished_good").order("sort_order"),
    supabase.from("price_list_items").select("product_id, unit_price, effective_from").eq("price_list_id", c.price_list_id).lte("effective_from", today).order("effective_from", { ascending: false }),
    supabase.from("price_lists").select("prices_include_tax").eq("id", c.price_list_id).single(),
    supabase.rpc("customer_summary", { p_customer: customerId }),
  ]);
  const price = (pid: string) => items?.find((i) => i.product_id === pid)?.unit_price ?? null;
  return {
    customer: c,
    addresses: addresses ?? [],
    products: (products ?? []).map((p) => ({ ...p, price: price(p.id) === null ? null : Number(price(p.id)) })),
    ola_bottles: summary?.ola_bottles ?? 0,
    outstanding: summary?.outstanding ?? 0,
    includes_tax: list?.prices_include_tax ?? true,
  };
}

type OrderPayload = {
  id?: string; customer_id: string; address_id: string; requested_date: string; time_window: string; source: string;
  notes: string; delivery_charge: string; expected_ola_returns: string; items: { product_id: string; qty: string; discount: string }[];
  confirm: boolean;
};

export async function saveOrder(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<OrderPayload>(f);
  const res = await runRpcOrApproval<{ order_id: string; order_no: string; status: string; hold_reason: string | null }>("save_order", {
    p_id: d.id || null,
    p: {
      customer_id: d.customer_id, address_id: d.address_id, requested_date: d.requested_date, time_window: d.time_window,
      source: d.source, notes: d.notes, delivery_charge: d.delivery_charge || "0", expected_ola_returns: d.expected_ola_returns || "0",
      items: d.items.filter((i) => Number(i.qty) > 0),
    },
    p_confirm: d.confirm,
    p_client_txn_id: d.id ? null : str(f, "client_txn_id"),
  }, "Order saved.", ["/orders"], d.notes || "Discount above the limit");
  if (!res.ok || isApproval(res.data)) return res;
  redirect(`/orders/${res.data!.order_id}`);
}

export async function confirmOrder(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "order_id");
  return runRpc<{ status: string; reasons: string[] }>("confirm_order", { p_order: id },
    (d) => (d.status === "confirmed" ? "Order confirmed." : `On hold: ${d.reasons.join("; ")}`), [`/orders/${id}`, "/orders"]);
}

export async function releaseHold(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "order_id");
  return runRpc("release_order_hold", { p_order: id, p_reason: str(f, "reason") }, "Hold released — order confirmed.", [`/orders/${id}`, "/orders"]);
}

export async function cancelOrder(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "order_id");
  return runRpc("cancel_order", { p_order: id, p_reason: str(f, "reason") }, "Order cancelled.", [`/orders/${id}`, "/orders"]);
}
