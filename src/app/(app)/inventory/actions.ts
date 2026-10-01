"use server";

import { runRpc, payload } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const P = ["/inventory", "/"];

export async function receiveStock(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ location: string; source: string; reason: string; lines: { product_id: string; qty: string }[] }>(f);
  return runRpc("receive_stock", { p_location: d.location, p_lines: d.lines.filter((l) => Number(l.qty) > 0), p_source: d.source, p_reason: d.reason,
    p_client_txn_id: str(f, "client_txn_id") }, "Stock received.", P);
}

export async function transferStock(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ from: string; to: string; reason: string; lines: { product_id: string; qty: string }[] }>(f);
  return runRpc("transfer_stock", { p_from: d.from, p_to: d.to, p_lines: d.lines.filter((l) => Number(l.qty) > 0), p_reason: d.reason,
    p_client_txn_id: str(f, "client_txn_id") }, "Stock transferred.", P);
}

export async function adjustStock(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ previous: number; counted: number; difference: number }>("adjust_stock", {
    p_location: str(f, "location"), p_product: str(f, "product_id"), p_counted: Number(str(f, "counted")), p_reason: str(f, "reason"),
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => (Number(d.difference) === 0 ? "Count matches — nothing changed." : `Adjusted by ${Number(d.difference) > 0 ? "+" : ""}${Number(d.difference)}.`), P);
}
