"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { friendlyError, isUuid, str, type ActionResult } from "@/lib/actions";

const GenerateSchema = z.object({
  series: z.string().regex(/^[A-Z0-9-]+$/, "Choose a label series"),
  quantity: z.coerce.number().int("Quantity must be a whole number").min(1, "At least 1 label").max(5000, "At most 5,000 labels per batch"),
  symbology: z.enum(["qrcode", "datamatrix", "code128"]),
  size: z.enum(["50x25", "40x30", "30x20"]),
  notes: z.string().max(300).optional(),
  client_txn_id: z.string().uuid("Please reload the page and try again"),
});

export async function generateLabelBatch(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = GenerateSchema.safeParse({
    series: str(form, "series"),
    quantity: str(form, "quantity"),
    symbology: str(form, "symbology"),
    size: str(form, "size"),
    notes: str(form, "notes") || undefined,
    client_txn_id: str(form, "client_txn_id"),
  });
  if (!parsed.success) return { ok: false, message: parsed.error.issues[0].message };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("generate_label_batch", {
    p_series_code: parsed.data.series,
    p_quantity: parsed.data.quantity,
    p_symbology: parsed.data.symbology,
    p_label_size: parsed.data.size,
    p_notes: parsed.data.notes ?? null,
    p_client_txn_id: parsed.data.client_txn_id,
  });
  if (error) return { ok: false, message: friendlyError(error) };

  revalidatePath("/labels");
  redirect(`/labels/${data.batch_id}`);
}

export async function recordLabelPrint(batchId: string, reason: string | null): Promise<ActionResult> {
  if (!isUuid(batchId)) return { ok: false, message: "Invalid batch" };
  const supabase = await createClient();
  const { error } = await supabase.rpc("record_label_print", { p_batch_id: batchId, p_reason: reason });
  if (error) return { ok: false, message: friendlyError(error) };
  revalidatePath(`/labels/${batchId}`);
  revalidatePath("/labels");
  return { ok: true, message: "Print recorded" };
}

export async function reprintAction(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const reason = str(form, "reason");
  if (!reason) return { ok: false, message: "A reason is required to reprint labels." };
  return recordLabelPrint(str(form, "batch_id"), reason);
}

export async function cancelBatchAction(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const batchId = str(form, "batch_id");
  const reason = str(form, "reason");
  if (!reason) return { ok: false, message: "A reason is required." };
  if (!isUuid(batchId)) return { ok: false, message: "Invalid batch" };
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_label_batch", { p_batch_id: batchId, p_reason: reason });
  if (error) return { ok: false, message: friendlyError(error) };
  revalidatePath(`/labels/${batchId}`);
  revalidatePath("/labels");
  return { ok: true, message: "Batch cancelled. Its labels can no longer be applied." };
}
