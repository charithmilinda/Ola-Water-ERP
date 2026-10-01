"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { runRpc } from "@/lib/rpc";
import { createClient } from "@/lib/supabase/server";
import { str, type ActionResult } from "@/lib/actions";

const MAX = 10 * 1024 * 1024;

async function upload(category: string, file: File): Promise<{ path?: string; error?: string }> {
  if (file.size > MAX) return { error: "The file is larger than 10 MB." };
  if (!/^[a-z][a-z0-9_]{2,30}$/.test(category)) return { error: "Choose a document type." };
  const ext = (file.name.split(".").pop() ?? "pdf").toLowerCase().replace(/[^a-z0-9]/g, "") || "pdf";
  const path = `${category}/${crypto.randomUUID()}.${ext}`;
  const supabase = await createClient();
  const { error } = await supabase.storage.from("documents").upload(path, file, { contentType: file.type || undefined });
  if (error) return { error: /row-level|policy|denied/i.test(error.message) ? "You cannot upload this type of document." : `Could not upload: ${error.message}` };
  return { path };
}

export async function uploadDocument(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const file = f.get("file");
  if (!(file instanceof File) || file.size === 0) return { ok: false, message: "Choose the file to upload." };
  const category = str(f, "category_code");
  const up = await upload(category, file);
  if (up.error) return { ok: false, message: up.error };
  const res = await runRpc<{ document_id: string; doc_no: string }>("register_document", {
    p: {
      category_code: category, title: str(f, "title") || file.name.replace(/\.[^.]+$/, ""), reference_no: str(f, "reference_no") || null,
      entity_type: str(f, "entity_type") || null, entity_id: str(f, "entity_id") || null, file_path: up.path, file_name: file.name,
      mime_type: file.type || null, size_bytes: file.size, issued_on: str(f, "issued_on") || null, expires_on: str(f, "expires_on") || null,
      alert_days: str(f, "alert_days") ? Number(str(f, "alert_days")) : null, notes: str(f, "notes") || null, replaces_id: str(f, "replaces_id") || null,
    },
  }, (d) => `${d.doc_no} saved.`, ["/documents"]);
  if (!res.ok) {
    const supabase = await createClient();
    await supabase.storage.from("documents").remove([up.path!]);
    return res;
  }
  const back = str(f, "return_to");
  if (back.startsWith("/")) revalidatePath(back);
  if (str(f, "replaces_id")) redirect(`/documents/${res.data!.document_id}`);
  return res;
}

export async function updateDocument(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "document_id");
  return runRpc("update_document", { p_id: id, p: {
    title: str(f, "title"), reference_no: str(f, "reference_no"), issued_on: str(f, "issued_on"), expires_on: str(f, "expires_on"),
    alert_days: str(f, "alert_days") ? Number(str(f, "alert_days")) : null, notes: str(f, "notes"),
  }, p_reason: str(f, "reason") || null }, "Saved.", ["/documents", `/documents/${id}`]);
}

export async function archiveDocument(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "document_id");
  return runRpc("archive_document", { p_id: id, p_reason: str(f, "reason") }, "Archived.", ["/documents", `/documents/${id}`]);
}
