"use server";

import { runRpcOrApproval } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

export async function resolveException(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpcOrApproval("resolve_exception", {
    p_id: str(f, "id"), p_resolution: str(f, "resolution"), p_note: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id"),
  }, "Resolved.", ["/exceptions", "/dispatch", "/shops", "/"], str(f, "reason"));
}
