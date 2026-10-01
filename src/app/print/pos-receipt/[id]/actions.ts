"use server";

import { runRpc } from "@/lib/rpc";
import type { ActionResult } from "@/lib/actions";

export async function recordPosReceiptPrint(saleId: string, reason: string | null): Promise<ActionResult> {
  return runRpc("record_pos_receipt_print", { p_sale: saleId, p_reason: reason }, "Recorded.");
}
