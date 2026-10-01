"use server";

import { runRpc } from "@/lib/rpc";
import { createClient } from "@/lib/supabase/server";
import { str, type ActionResult } from "@/lib/actions";

const P = ["/expenses", "/accounting", "/"];

export async function recordExpense(_p: ActionResult, f: FormData): Promise<ActionResult> {
  let receiptPath: string | null = null;
  const file = f.get("receipt");
  if (file instanceof File && file.size > 0) {
    if (file.size > 10 * 1024 * 1024) return { ok: false, message: "The receipt file is larger than 10 MB." };
    const ext = (file.name.split(".").pop() ?? "jpg").toLowerCase().replace(/[^a-z0-9]/g, "") || "jpg";
    receiptPath = `${new Date().toISOString().slice(0, 7)}/${crypto.randomUUID()}.${ext}`;
    const supabase = await createClient();
    const { error } = await supabase.storage.from("expense-receipts").upload(receiptPath, file, { contentType: file.type || undefined });
    if (error) return { ok: false, message: `Could not upload the receipt: ${error.message}` };
  }
  const method = str(f, "pay_method");
  return runRpc<{ expense_no: string; status: string }>("record_expense", {
    p: { expense_date: str(f, "expense_date") || null, category_id: str(f, "category_id"), description: str(f, "description"), payee: str(f, "payee"),
      supplier_id: str(f, "supplier_id") || null, location_id: str(f, "location_id") || null, vehicle_id: str(f, "vehicle_id") || null,
      net_amount: Number(str(f, "net_amount") || 0), vat_amount: Number(str(f, "vat_amount") || 0), pay_method: method,
      money_account_id: method === "on_credit" ? null : str(f, `account_${method}`) || null, reference: str(f, "reference"), receipt_path: receiptPath },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => (d.status === "pending_approval" ? `${d.expense_no} sent for approval (over the limit).` : d.status === "approved" ? `${d.expense_no} recorded as a bill to pay.` : `${d.expense_no} recorded and paid.`), P);
}

export async function decideExpense(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = str(f, "decision") === "approve";
  return runRpc("decide_expense", { p_id: str(f, "expense_id"), p_approve: approve, p_note: str(f, "reason") }, approve ? "Approved and posted." : "Rejected.", P);
}

export async function payExpense(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ expense_no: string }>("pay_expense", { p_id: str(f, "expense_id"), p_money_account: str(f, "money_account_id"), p_reference: str(f, "reference"),
    p_client_txn_id: str(f, "client_txn_id") }, (d) => `${d.expense_no} paid.`, P);
}

export async function saveCategory(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_expense_category", { p_id: id, p: { code: str(f, "code"), name: str(f, "name"), account_id: str(f, "account_id"),
    is_active: id ? f.get("is_active") === "on" : true }, p_reason: str(f, "reason") || null }, "Category saved.", P);
}
