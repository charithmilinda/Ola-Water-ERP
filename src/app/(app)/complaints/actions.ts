"use server";

import { redirect } from "next/navigation";
import { runRpc } from "@/lib/rpc";
import { createClient } from "@/lib/supabase/server";
import { str, type ActionResult } from "@/lib/actions";
import { normalizeSriLankanPhone } from "@/lib/format";

const P = ["/complaints", "/"];

/** Upload photos chosen in a form field to the private complaint-photos bucket. */
async function uploadPhotos(f: FormData, folder: string): Promise<{ paths: string[]; error?: string }> {
  const files = f.getAll("photos").filter((x): x is File => x instanceof File && x.size > 0);
  if (files.length > 5) return { paths: [], error: "Add up to 5 photos at a time." };
  const supabase = await createClient();
  const paths: string[] = [];
  for (const file of files) {
    if (file.size > 5 * 1024 * 1024) return { paths, error: `${file.name} is larger than 5 MB.` };
    const ext = (file.name.split(".").pop() ?? "jpg").toLowerCase().replace(/[^a-z0-9]/g, "") || "jpg";
    const path = `${folder}/${crypto.randomUUID()}.${ext}`;
    const { error } = await supabase.storage.from("complaint-photos").upload(path, file, { contentType: file.type || "image/jpeg" });
    if (error) return { paths, error: `Could not upload ${file.name}: ${error.message}` };
    paths.push(path);
  }
  return { paths };
}

export async function logComplaint(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const supabase = await createClient();
  let customerId = str(f, "customer_id") || null;
  const lookup = str(f, "customer_lookup");
  if (!customerId && lookup) {
    const phone = normalizeSriLankanPhone(lookup);
    const q = supabase.from("customers").select("id").limit(1);
    const { data } = phone ? await q.or(`phone.eq.${phone},phone2.eq.${phone}`) : await q.eq("customer_no", lookup.toUpperCase());
    if (!data?.[0]) return { ok: false, message: `No customer found for "${lookup}". Leave it empty and fill in the contact details instead.` };
    customerId = data[0].id;
  }
  let orderId: string | null = null;
  if (str(f, "order_no")) {
    const { data } = await supabase.from("orders").select("id").eq("order_no", str(f, "order_no").toUpperCase()).maybeSingle();
    if (!data) return { ok: false, message: `Order ${str(f, "order_no")} not found.` };
    orderId = data.id;
  }
  const up = await uploadPhotos(f, "new");
  if (up.error) return { ok: false, message: up.error };
  const res = await runRpc<{ complaint_id: string; complaint_no: string }>("log_complaint", {
    p: {
      category_code: str(f, "category_code"), priority: str(f, "priority") || null, channel: str(f, "channel"), subject: str(f, "subject"),
      description: str(f, "description"), customer_id: customerId, contact_name: str(f, "contact_name"), contact_phone: str(f, "contact_phone"),
      location_id: str(f, "location_id") || null, order_id: orderId, batch_no: str(f, "batch_no") || null, bottle_code: str(f, "bottle_code") || null,
      product_id: str(f, "product_id") || null, assigned_to: str(f, "assigned_to") || null, photo_paths: up.paths,
    },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `${d.complaint_no} logged.`, P);
  if (!res.ok) return res;
  redirect(`/complaints/${res.data!.complaint_id}`);
}

const one = (id: string) => [...P, `/complaints/${id}`];

export async function assignComplaint(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "complaint_id");
  return runRpc("assign_complaint", { p_id: id, p_user: str(f, "user_id"), p_note: str(f, "note") || null }, "Assigned.", one(id));
}

export async function updateComplaint(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "complaint_id");
  return runRpc("update_complaint", { p_id: id, p: { status: str(f, "status") || null, priority: str(f, "priority") || null,
    category_code: str(f, "category_code") || null, note: str(f, "note") || null } }, "Updated.", one(id));
}

export async function addComplaintNote(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "complaint_id");
  const up = await uploadPhotos(f, id);
  if (up.error) return { ok: false, message: up.error };
  return runRpc("add_complaint_note", { p_id: id, p_note: str(f, "note") || null, p_photo_paths: up.paths }, "Added to the timeline.", one(id));
}

export async function resolveComplaint(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "complaint_id");
  return runRpc("resolve_complaint", { p_id: id, p_resolution: str(f, "resolution"), p_root_cause: str(f, "root_cause") || null }, "Resolved.", one(id));
}

export async function closeComplaint(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "complaint_id");
  return runRpc("close_complaint", { p_id: id, p_note: str(f, "reason") || null }, "Closed.", one(id));
}

export async function reopenComplaint(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "complaint_id");
  return runRpc("reopen_complaint", { p_id: id, p_reason: str(f, "reason") }, "Reopened.", one(id));
}

export async function requestQcReview(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "complaint_id");
  return runRpc("request_complaint_qc_review", { p_id: id, p_batch_no: str(f, "batch_no"), p_note: str(f, "note") || null }, "Quality control asked to review.",
    [...one(id), "/quality"]);
}

export async function completeQcReview(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "complaint_id");
  return runRpc("complete_complaint_qc_review", { p_id: id, p_finding: str(f, "finding") }, "QC review recorded.", [...one(id), "/quality"]);
}
