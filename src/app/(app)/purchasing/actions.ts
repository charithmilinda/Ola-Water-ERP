"use server";

import { redirect } from "next/navigation";
import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";
import { parseLines, num } from "@/lib/lines";

const P = (id?: string) => ["/purchasing", "/suppliers", "/inventory", "/", ...(id ? [`/purchasing/${id}`] : [])];

export async function createRequest(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const items = parseLines(f.get("lines")).map((l) => ({ product_id: l.item_id, qty: num(l.qty), est_unit_price: num(l.est_unit_price), notes: l.notes }));
  if (items.length === 0) return { ok: false, message: "Add at least one item." };
  return runRpc<{ request_no: string }>("create_purchase_request", {
    p: { location_id: str(f, "location_id"), needed_by: str(f, "needed_by") || null, notes: str(f, "notes"), items },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Request ${d.request_no} sent for approval.`, P());
}

export async function decideRequest(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = str(f, "decision");
  return runRpc("decide_purchase_request", { p_id: str(f, "request_id"), p_approve: d === "approve" ? true : d === "reject" ? false : null,
    p_note: str(f, "reason") }, d === "approve" ? "Request approved." : d === "reject" ? "Request rejected." : "Request withdrawn.", P());
}

export async function createOrder(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const lines = parseLines(f.get("lines")).map((l) => ({ product_id: l.item_id, qty: num(l.qty), unit_price: num(l.unit_price), tax_rate: num(l.tax_rate) }));
  if (lines.length === 0) return { ok: false, message: "Add at least one item." };
  const res = await runRpc<{ po_id: string; po_no: string; status: string }>("create_purchase_order", {
    p: { supplier_id: str(f, "supplier_id"), location_id: str(f, "location_id"), expected_date: str(f, "expected_date") || null,
      request_id: str(f, "request_id") || null, notes: str(f, "notes"), lines },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Order ${d.po_no} created.`, P());
  if (!res.ok) return res;
  redirect(`/purchasing/${res.data?.po_id}`);
}

export async function decideOrder(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "po_id");
  const approve = str(f, "decision") === "approve";
  return runRpc("decide_purchase_order", { p_po: id, p_approve: approve, p_note: str(f, "reason") }, approve ? "Order approved." : "Order cancelled.", P(id));
}

export async function closeOrder(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "po_id");
  return runRpc("close_purchase_order", { p_po: id, p_note: str(f, "reason") }, "Order closed.", P(id));
}

/** Fields are named per order line: rcv:<id>, rej:<id>, why:<id>, lot:<id>, exp:<id>. */
export async function receiveOrder(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "po_id");
  const ids = [...new Set([...f.keys()].filter((k) => k.startsWith("rcv:")).map((k) => k.slice(4)))];
  const lines = ids.map((l) => ({ po_line_id: l, qty_received: Number(str(f, `rcv:${l}`) || 0), qty_rejected: Number(str(f, `rej:${l}`) || 0),
    reject_reason: str(f, `why:${l}`), supplier_lot: str(f, `lot:${l}`), expiry_date: str(f, `exp:${l}`) || null }))
    .filter((l) => l.qty_received > 0 || l.qty_rejected > 0);
  if (lines.length === 0) return { ok: false, message: "Enter what arrived." };
  return runRpc<{ grn_no: string; value: number; complete: boolean }>("receive_purchase_order", {
    p_po: id, p: { delivery_note_no: str(f, "delivery_note_no"), notes: str(f, "notes"), lines }, p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.grn_no}: goods received into stock.${d.complete ? " The order is complete." : ""}`, P(id));
}

/** Fields per order line: iq:<id> (qty), ip:<id> (price), iv:<id> (VAT %). */
export async function recordInvoice(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "po_id");
  const ids = [...new Set([...f.keys()].filter((k) => k.startsWith("iq:")).map((k) => k.slice(3)))];
  const lines = ids.map((l) => ({ po_line_id: l, qty: Number(str(f, `iq:${l}`) || 0), unit_price: num(str(f, `ip:${l}`)), tax_rate: num(str(f, `iv:${l}`)) }))
    .filter((l) => l.qty > 0);
  if (lines.length === 0) return { ok: false, message: "Enter the invoiced quantities." };
  return runRpc<{ ref_no: string; status: string; mismatches: string[] }>("record_supplier_invoice", {
    p_po: id, p: { supplier_invoice_no: str(f, "supplier_invoice_no"), invoice_date: str(f, "invoice_date") || null, due_date: str(f, "due_date") || null, lines },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => (d.status === "approved" ? `${d.ref_no}: matches the order and goods received — ready to pay.`
    : `${d.ref_no} is ON HOLD: ${d.mismatches.join("; ")}. An approver must accept or reject it.`), P(id));
}

export async function decideInvoice(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "po_id");
  const approve = str(f, "decision") === "approve";
  return runRpc("decide_supplier_invoice", { p_inv: str(f, "invoice_id"), p_approve: approve, p_note: str(f, "reason") },
    approve ? "Invoice accepted and posted." : "Invoice rejected (void).", P(id));
}
