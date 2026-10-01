"use server";

import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

export async function saveTemplate(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  let parameters: unknown[] = [];
  try { parameters = JSON.parse(str(f, "parameters") || "[]"); } catch { parameters = []; }
  return runRpc("save_qc_template", {
    p_id: id,
    p: { code: str(f, "code"), name: str(f, "name"), product_id: str(f, "product_id") || null, description: str(f, "description"),
      is_active: id ? f.get("is_active") === "on" : true, parameters },
    p_reason: str(f, "reason") || (id ? null : "New QC template"),
  }, "Template saved.", ["/quality"]);
}

export async function secureRecall(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "recall_id");
  return runRpc<number>("secure_recalled_stock", { p_recall: id }, (n) => (Number(n) > 0 ? `${n} more unit(s) moved to quarantine.` : "Nothing more to secure."),
    [`/quality/recalls/${id}`, "/quality"]);
}

export async function updateRecallCustomer(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "recall_id");
  return runRpc("record_recall_recovery", {
    p_item: str(f, "item_id"), p_qty: Number(str(f, "qty") || 0), p_status: str(f, "status"), p_note: str(f, "note"),
    p_client_txn_id: str(f, "client_txn_id"),
  }, "Follow-up saved.", [`/quality/recalls/${id}`]);
}

export async function closeRecall(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "recall_id");
  return runRpc("close_batch_recall", { p_recall: id, p_note: str(f, "reason") }, "Recall closed.", [`/quality/recalls/${id}`, "/quality"]);
}
