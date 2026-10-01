"use server";

import { redirect } from "next/navigation";
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

export async function createCustomer(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<string>("save_customer", { p_id: null, p: customerPayload(f), p_reason: "New customer" }, "Customer created.", ["/customers"]);
  if (!res.ok) return res;
  redirect(`/customers/${res.data}`);
}

export async function updateCustomer(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id");
  return runRpc("save_customer", { p_id: id, p: customerPayload(f), p_reason: str(f, "reason") || null }, "Customer saved.", [`/customers/${id}`]);
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
