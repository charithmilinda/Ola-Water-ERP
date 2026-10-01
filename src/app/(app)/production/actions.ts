"use server";

import { redirect } from "next/navigation";
import { runRpc, payload } from "@/lib/rpc";
import { createClient } from "@/lib/supabase/server";
import { str, isUuid, type ActionResult } from "@/lib/actions";

const paths = (id?: string) => ["/production", "/quality", "/inventory", "/", ...(id ? [`/production/${id}`] : [])];

export async function saveLine(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_production_line", {
    p_id: id, p: { code: str(f, "code"), name: str(f, "name"), location_id: str(f, "location_id"), notes: str(f, "notes"),
      is_active: id ? f.get("is_active") === "on" : true },
    p_reason: str(f, "reason") || (id ? null : "New production line"),
  }, id ? "Line saved." : "Line added.", ["/production"]);
}

export async function planBatch(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<{ batch_id: string; batch_no: string }>("plan_production_batch", {
    p: { product_id: str(f, "product_id"), line_id: str(f, "line_id"), planned_qty: Number(str(f, "planned_qty") || 0),
      production_date: str(f, "production_date") || null, shift: str(f, "shift"), operator_name: str(f, "operator_name"), notes: str(f, "notes") },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Batch ${d.batch_no} planned.`, paths());
  if (!res.ok) return res;
  redirect(`/production/${res.data?.batch_id}`);
}

export async function startBatch(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "batch_id");
  return runRpc("start_production_batch", { p_batch: id, p_operator: str(f, "operator_name") }, "Production started.", paths(id));
}

export async function cancelBatch(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "batch_id");
  return runRpc("cancel_production_batch", { p_batch: id, p_reason: str(f, "reason") }, "Batch cancelled.", paths(id));
}

export async function recordStage(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "batch_id");
  return runRpc("record_production_stage", { p_batch: id, p_stage: str(f, "stage"), p_reading: str(f, "reading"), p_notes: str(f, "notes") },
    "Stage recorded.", paths(id));
}

export async function completeBatch(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const d = payload<{ batch_id: string; produced_qty: string; rejected_qty: string; wastage_qty: string; wastage_note: string; operator_name: string;
    materials: { material_id: string; qty: string }[]; codes: string }>(f);
  const codes = (d.codes ?? "").split(/[\s,;]+/).map((c) => c.trim().toUpperCase()).filter(Boolean);
  return runRpc<{ batch_no: string; produced: number; material_cost: number; warnings: string[] }>("complete_production_batch", {
    p_batch: d.batch_id,
    p: { produced_qty: Number(d.produced_qty || 0), rejected_qty: Number(d.rejected_qty || 0), wastage_qty: d.wastage_qty ? Number(d.wastage_qty) : null,
      wastage_note: d.wastage_note, operator_name: d.operator_name,
      materials: d.materials.filter((m) => Number(m.qty) > 0).map((m) => ({ material_id: m.material_id, qty: Number(m.qty) })),
      bottle_codes: codes },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => `${r.batch_no}: ${r.produced} unit(s) on QC hold.${r.warnings?.length ? ` Note: ${r.warnings.join(" ")}` : ""}`, paths(d.batch_id));
}

export async function recordQcTest(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const batch = str(f, "batch_id");
  if (!isUuid(batch)) return { ok: false, message: "Batch not found." };
  const results = [...f.entries()].filter(([k]) => k.startsWith("param:")).map(([k, v]) => ({ parameter_id: k.slice(6), value: String(v) }));
  let certificatePath: string | null = null;
  const file = f.get("certificate");
  if (file instanceof File && file.size > 0) {
    if (file.size > 10 * 1024 * 1024) return { ok: false, message: "The certificate file is larger than 10 MB." };
    const ext = (file.name.split(".").pop() ?? "pdf").toLowerCase().replace(/[^a-z0-9]/g, "");
    certificatePath = `${batch}/${crypto.randomUUID()}.${ext || "pdf"}`;
    const supabase = await createClient();
    const { error } = await supabase.storage.from("qc-certificates").upload(certificatePath, file, { contentType: file.type || undefined });
    if (error) return { ok: false, message: `Could not upload the certificate: ${error.message}` };
  }
  return runRpc<{ test_no: string; result: string; failed: string[] }>("record_qc_test", {
    p_batch: batch,
    p: { template_id: str(f, "template_id"), tested_at: str(f, "tested_at") || null, sample_ref: str(f, "sample_ref"), lab_name: str(f, "lab_name"),
      notes: str(f, "notes"), certificate_path: certificatePath, results },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => (r.result === "pass" ? `${r.test_no}: PASSED — the batch can be released.` : `${r.test_no}: FAILED (${r.failed.join(", ")}).`), paths(batch));
}

export async function releaseBatch(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "batch_id");
  return runRpc<{ released_qty: number; override: boolean }>("release_production_batch", {
    p_batch: id, p_override: str(f, "override") === "1", p_reason: str(f, "reason") || null, p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => `${r.released_qty} unit(s) released for sale${r.override ? " (override recorded)" : ""}.`, paths(id));
}

export async function rejectBatch(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "batch_id");
  return runRpc<{ quarantined_qty: number }>("reject_production_batch", { p_batch: id, p_reason: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id") },
    (r) => `Batch failed. ${r.quarantined_qty} unit(s) moved to quarantine.`, paths(id));
}

export async function disposeStock(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "batch_id");
  return runRpc<{ disposed: number; value: number }>("dispose_quarantined_stock", {
    p_batch: id, p_location: str(f, "location_id"), p_qty: Number(str(f, "qty") || 0), p_reason: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => `${r.disposed} unit(s) destroyed and written off.`, paths(id));
}

export async function recallBatch(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "batch_id");
  const res = await runRpc<{ recall_id: string; recall_no: string }>("recall_production_batch", {
    p_batch: id, p_reason: str(f, "reason"), p_client_txn_id: str(f, "client_txn_id"),
  }, (r) => `Recall ${r.recall_no} started.`, paths(id));
  if (!res.ok) return res;
  redirect(`/quality/recalls/${res.data?.recall_id}`);
}
