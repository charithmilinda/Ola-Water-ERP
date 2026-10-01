"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export async function markNotificationsRead(ids: string[] | null) {
  const supabase = await createClient();
  await supabase.rpc("mark_notifications_read", { p_ids: ids });
  revalidatePath("/", "layout");
}
