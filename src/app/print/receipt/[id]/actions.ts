"use server";

import { runRpc } from "@/lib/rpc";
import type { ActionResult } from "@/lib/actions";

export async function recordReceiptPrint(invoiceId: string, reason: string | null): Promise<ActionResult> {
  return runRpc("record_receipt_print", { p_invoice: invoiceId, p_reason: reason }, "Recorded.");
}
