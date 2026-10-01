"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

function customerPayload(f: FormData) {
  return {
    name: str(f, "name"),
    company_name: str(f, "company_name"),
    customer_type: str(f, "customer_type"),
    contact_person: str(f, "contact_person"),
    phone: str(f, "phone"),
    phone2: str(f, "phone2"),
    email: str(f, "email"),
    vat_no: str(f, "vat_no"),
    route_id: str(f, "route_id"),
    route_sequence: str(f, "route_sequence"),
    price_list_id: str(f, "price_list_id"),
    credit_limit: str(f, "credit_limit") || "0",
    payment_terms_days: str(f, "payment_terms_days"),
    bottle_model: str(f, "bottle_model"),
    allowed_bottles: str(f, "allowed_bottles"),
    external_policy: str(f, "external_policy"),
    status: str(f, "status"),
    notes: str(f, "notes"),
    address: {
      address_line: str(f, "address_line"),
      city: str(f, "city"),
      district: str(f, "district"),
      gps_lat: str(f, "gps_lat"),
      gps_lng: str(f, "gps_lng"),
      delivery_instructions: str(f, "delivery_instructions"),
    },
  };
}

/** A credit limit / payment terms change that went to an approver while saving. */
async function creditRequestNote(customerId: string): Promise<string> {
  const supabase = await createClient();
  const { data } = await supabase.from("approval_requests").select("request_no").eq("entity_id", customerId).eq("kind", "credit_change")
    .eq("status", "pending").gte("requested_at", new Date(Date.now() - 60_000).toISOString()).order("requested_at", { ascending: false }).limit(1);
  return data?.[0] ? ` The credit terms were sent for approval (${data[0].request_no}) — until then the customer stays on the old terms.` : "";
}

export async function createCustomer(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<string>("save_customer", { p_id: null, p: customerPayload(f), p_reason: "New customer" }, "Customer created.", ["/customers"]);
  if (!res.ok) return res;
  redirect(`/customers/${res.data}`);
}

export async function updateCustomer(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id");
  const res = await runRpc("save_customer", { p_id: id, p: customerPayload(f), p_reason: str(f, "reason") || null }, "Customer saved.", [`/customers/${id}`]);
  if (!res.ok) return res;
  return { ...res, message: res.message + (await creditRequestNote(id)) };
}

export async function saveAddress(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const cid = str(f, "customer_id");
  return runRpc("save_customer_address", {
    p_customer: cid,
    p_id: str(f, "id") || null,
    p: {
      label: str(f, "label"), address_line: str(f, "address_line"), city: str(f, "city"), district: str(f, "district"),
      gps_lat: str(f, "gps_lat"), gps_lng: str(f, "gps_lng"), delivery_instructions: str(f, "delivery_instructions"),
      is_default: f.get("is_default") === "on", is_active: f.get("is_active") !== "off",
    },
    p_reason: str(f, "reason") || null,
  }, "Address saved.", [`/customers/${cid}`]);
}

export async function recordPayment(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const cid = str(f, "customer_id");
  return runRpc<{ payment_no: string; outstanding: number }>("record_payment", {
    p_customer: cid, p_method: str(f, "method"), p_amount: Number(str(f, "amount")), p_reference: str(f, "reference"),
    p_invoice: str(f, "invoice_id") || null, p_notes: str(f, "notes"), p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Payment ${d.payment_no} recorded.`, [`/customers/${cid}`, "/payments"]);
}

export async function setOpeningBottles(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const cid = str(f, "customer_id");
  return runRpc("set_opening_bottles", {
    p_holder_type: "customer", p_holder_id: cid, p_company: str(f, "company_id"), p_bottle_type: str(f, "bottle_type_id"),
    p_fill: "full", p_qty: Number(str(f, "qty")), p_reason: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id"),
  }, "Opening bottles recorded.", [`/customers/${cid}`]);
}

export async function issueCreditNote(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const cid = str(f, "customer_id");
  return runRpc<{ credit_note_no: string; total: number; unused_credit: number }>("issue_credit_note", {
    p: { customer_id: cid, invoice_id: str(f, "invoice_id") || null, net: Number(str(f, "net") || 0), tax_rate: Number(str(f, "tax_rate") || 0),
      reason: str(f, "reason") },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Credit note ${d.credit_note_no} issued.${Number(d.unused_credit) > 0 ? ` Rs. ${Number(d.unused_credit).toFixed(2)} is kept as credit.` : ""}`,
  [`/customers/${cid}`, "/accounting"]);
}

export async function reversePayment(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const cid = str(f, "customer_id");
  return runRpc<{ payment_no: string }>("reverse_payment", { p_payment: str(f, "payment_id"), p_reason: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id") },
    (d) => `Payment ${d.payment_no} reversed.`, [`/customers/${cid}`, "/payments", "/accounting"]);
}

export async function applyCredit(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const cid = str(f, "customer_id");
  return runRpc<number>("apply_customer_credit", { p_customer: cid }, (n) => (Number(n) > 0 ? `Rs. ${Number(n).toFixed(2)} applied.` : "No unpaid invoice to apply it to."),
    [`/customers/${cid}`]);
}
