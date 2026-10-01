"use server";

import { runRpc, payload } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const P = ["/bottles", "/bottles/external", "/"];

export async function registerBottles(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const codes = str(f, "codes").split(/[\s,;]+/).map((c) => c.trim().toUpperCase()).filter(Boolean);
  if (codes.length === 0) return { ok: false, message: "Scan or type at least one label." };
  return runRpc<{ registered: number }>("register_bottles", {
    p_codes: codes, p_bottle_type: str(f, "bottle_type_id"), p_location: str(f, "location"), p_fill: str(f, "fill") || "empty",
    p_reason: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.registered} bottle(s) registered.`, P);
}

export async function openingBottlesAtLocation(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("set_opening_bottles", {
    p_holder_type: "location", p_holder_id: str(f, "location"), p_company: str(f, "company_id"), p_bottle_type: str(f, "bottle_type_id"),
    p_fill: str(f, "fill"), p_qty: Number(str(f, "qty")), p_reason: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id"),
  }, "Opening bottles recorded.", P);
}

export async function markBottle(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("mark_bottle", { p_code: str(f, "code"), p_action: str(f, "action"), p_reason: str(f, "reason") }, "Bottle updated.", P);
}

export async function recordHandover(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ company_id: string; codes: string; give: { bottle_type_id: string; qty: string }[]; receive: { bottle_type_id: string; qty: string }[];
    rep_name: string; rep_phone: string; notes: string }>(f);
  const codes = (d.codes ?? "").split(/[\s,;]+/).map((c) => c.trim().toUpperCase()).filter(Boolean);
  return runRpc<{ handover_no: string; given: number; received: number }>("record_external_handover", {
    p_company: d.company_id, p_give_codes: codes,
    p_give_counts: d.give.filter((g) => Number(g.qty) > 0).map((g) => ({ bottle_type_id: g.bottle_type_id, qty: Number(g.qty) })),
    p_receive_codes: [], p_receive_counts: d.receive.filter((g) => Number(g.qty) > 0).map((g) => ({ bottle_type_id: g.bottle_type_id, qty: Number(g.qty) })),
    p_rep_name: d.rep_name, p_rep_phone: d.rep_phone || null, p_notes: d.notes, p_proof_path: null, p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => `${r.handover_no}: ${r.given} bottle(s) handed over, ${r.received} OLA bottle(s) received.`, P);
}

export async function saveCompany(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_bottle_company", {
    p_id: id,
    p: { code: str(f, "code"), name: str(f, "name"), acceptance_policy: str(f, "acceptance_policy"), contact_person: str(f, "contact_person"),
         contact_phone: str(f, "contact_phone"), address: str(f, "address"), holding_alert_qty: str(f, "holding_alert_qty"), notes: str(f, "notes"),
         is_active: id ? f.get("is_active") === "on" : true },
    p_reason: str(f, "reason") || (id ? null : "New company"),
  }, "Company saved.", P);
}
