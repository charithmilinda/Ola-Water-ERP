"use server";

import { redirect } from "next/navigation";
import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";
import { parseLines, num } from "@/lib/lines";

function supplierPayload(f: FormData) {
  return {
    code: str(f, "code"), name: str(f, "name"), contact_person: str(f, "contact_person"), phone: str(f, "phone"), email: str(f, "email"),
    address: str(f, "address"), city: str(f, "city"), vat_no: str(f, "vat_no"), payment_terms_days: str(f, "payment_terms_days") || "30",
    notes: str(f, "notes"), is_active: f.has("id") ? f.get("is_active") === "on" : true,
  };
}

export async function createSupplier(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<string>("save_supplier", { p_id: null, p: supplierPayload(f), p_reason: "New supplier" }, "Supplier added.", ["/suppliers"]);
  if (!res.ok) return res;
  redirect(`/suppliers/${res.data}`);
}

export async function updateSupplier(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id");
  return runRpc("save_supplier", { p_id: id, p: supplierPayload(f), p_reason: str(f, "reason") || null }, "Supplier saved.", [`/suppliers/${id}`, "/suppliers"]);
}

export async function saveSupplierItems(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "supplier_id");
  const lines = parseLines(f.get("lines")).map((l) => ({ product_id: l.item_id, supplier_sku: l.supplier_sku, unit_price: num(l.unit_price),
    lead_time_days: num(l.lead_time_days) }));
  return runRpc<number>("set_supplier_items", { p_supplier: id, p_lines: lines, p_reason: str(f, "reason") || "Supplier prices" },
    (n) => `${n} price(s) saved.`, [`/suppliers/${id}`]);
}

export async function paySupplier(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "supplier_id");
  const [inv, bal] = str(f, "invoice").split("|");
  const amount = Number(str(f, "amount") || 0);
  return runRpc<{ payment_no: string; unallocated: number; outstanding: number }>("record_supplier_payment", {
    p: { supplier_id: id, method: str(f, "method"), amount, reference: str(f, "reference"), notes: str(f, "notes"),
      allocations: inv ? [{ invoice_id: inv, amount: Math.min(amount, Number(bal || amount)) }] : [] },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => `Payment ${r.payment_no} recorded.${Number(r.unallocated) > 0 ? ` Rs. ${Number(r.unallocated).toFixed(2)} kept as an advance.` : ""}`,
  [`/suppliers/${id}`, "/suppliers", "/purchasing"]);
}
