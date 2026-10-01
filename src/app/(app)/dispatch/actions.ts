"use server";

import { redirect } from "next/navigation";
import { runRpc, payload } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

export async function createRun(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ run_date: string; route_id: string; vehicle_id: string; driver_id: string; order_ids: string[]; helper: string; notes: string }>(f);
  if (!d.vehicle_id || !d.driver_id) return { ok: false, message: "Choose a vehicle and a driver." };
  const res = await runRpc<{ run_id: string; run_no: string }>("create_route_run", {
    p_run_date: d.run_date, p_route: d.route_id || null, p_vehicle: d.vehicle_id, p_driver: d.driver_id, p_order_ids: d.order_ids,
    p_helper: d.helper, p_notes: d.notes, p_client_txn_id: str(f, "client_txn_id"),
  }, "Run created.", ["/dispatch", "/orders"]);
  if (!res.ok) return res;
  redirect(`/dispatch/${res.data!.run_id}`);
}

export async function loadRun(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ run_id: string; lines: { product_id: string; qty: string }[]; cash_float: string }>(f);
  return runRpc("load_route_run", {
    p_run: d.run_id, p_lines: d.lines.filter((l) => Number(l.qty) > 0).map((l) => ({ product_id: l.product_id, qty: Number(l.qty) })),
    p_cash_float: Number(d.cash_float || 0), p_client_txn_id: str(f, "client_txn_id"),
  }, "Vehicle loaded. The driver can now confirm and start.", [`/dispatch/${d.run_id}`, "/dispatch"]);
}

export async function checkinRun(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ run_id: string; products: { product_id: string; qty: string }[]; bottles: { company_id: string; bottle_type_id: string; fill_state: string; qty: string }[];
    scanned: string; cash_handed: string; notes: string }>(f);
  const codes = (d.scanned ?? "").split(/[\s,;]+/).map((c) => c.trim().toUpperCase()).filter(Boolean);
  return runRpc<{ exceptions: number; status: string }>("checkin_route_run", {
    p_run: d.run_id,
    p: {
      products: d.products.map((p) => ({ product_id: p.product_id, qty: Number(p.qty || 0) })),
      bottles: d.bottles.map((b) => ({ ...b, qty: Number(b.qty || 0) })),
      scanned_codes: codes, cash_handed: Number(d.cash_handed || 0), notes: d.notes,
    },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => (r.exceptions === 0 ? "Checked in — everything matched. Run closed." : `Checked in with ${r.exceptions} difference(s). Resolve them under Exceptions.`),
  [`/dispatch/${d.run_id}`, "/dispatch", "/exceptions", "/"]);
}
