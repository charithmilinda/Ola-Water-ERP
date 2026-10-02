"use server";

import { redirect } from "next/navigation";
import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

function payload(f: FormData) {
  return {
    customer_id: str(f, "customer_id") || null, code: str(f, "code"), kind: str(f, "kind") || null, territory_id: str(f, "territory_id") || null,
    manager_id: str(f, "manager_id") || null, agreement_start: str(f, "agreement_start") || null, agreement_end: str(f, "agreement_end") || null,
    monthly_target: str(f, "monthly_target") ? Number(str(f, "monthly_target")) : 0, min_stock_19l: str(f, "min_stock_19l") ? Number(str(f, "min_stock_19l")) : null,
    exclusive: f.get("exclusive") === "on", status: str(f, "status") || null, notes: str(f, "notes"),
  };
}

export async function createDistributor(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<string>("save_distributor", { p_id: null, p: payload(f), p_reason: "New distributor" }, "Distributor added.", ["/distributors"]);
  if (!res.ok) return res;
  redirect(`/distributors/${res.data}`);
}

export async function updateDistributor(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id");
  return runRpc("save_distributor", { p_id: id, p: payload(f), p_reason: str(f, "reason") || null }, "Saved.", ["/distributors", `/distributors/${id}`]);
}

export async function recordStock(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "distributor_id");
  const lines = [...f.keys()].filter((k) => k.startsWith("q:")).map((k) => ({ product_id: k.slice(2), qty: str(f, k) })).filter((l) => l.qty !== "")
    .map((l) => ({ product_id: l.product_id, qty: Number(l.qty) }));
  return runRpc("record_distributor_stock", { p_distributor: id, p_date: str(f, "report_date") || null, p_lines: lines,
    p_empty: str(f, "empty_bottles") ? Number(str(f, "empty_bottles")) : null, p_notes: str(f, "notes") || null }, "Stock count saved.", [`/distributors/${id}`, "/distributors"]);
}
