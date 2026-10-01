import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import { createAdminClient } from "@/lib/supabase/admin";
import { sendMessage, type OutboxMessage } from "./providers";

/** Send queued messages through the providers and record each result. */
export async function dispatchMessages(client: SupabaseClient, limit = 25) {
  const { data, error } = await client.rpc("claim_messages", { p_limit: limit });
  if (error) return { sent: 0, failed: 0, error: error.message };
  let sent = 0;
  let failed = 0;
  for (const m of (data ?? []) as OutboxMessage[]) {
    const r = await sendMessage(m);
    await client.rpc("report_message_result", {
      p_id: m.id, p_ok: r.ok, p_provider: r.provider, p_ref: r.ok ? r.ref : null, p_error: r.ok ? null : r.error,
    });
    if (r.ok) sent++;
    else failed++;
  }
  return { sent, failed };
}

/**
 * Background housekeeping run after page loads: the alert scan (throttled in
 * the database) and, every couple of minutes, the message queue. Never throws.
 */
export async function backgroundHousekeeping(userClient: SupabaseClient) {
  try {
    await userClient.rpc("refresh_notifications", { p_force: false });
    if (!process.env.SUPABASE_SERVICE_ROLE_KEY) return;
    const { data: st } = await userClient.from("notification_scan_state").select("last_dispatch_at").maybeSingle();
    const last = st?.last_dispatch_at ? new Date(st.last_dispatch_at).getTime() : 0;
    if (Date.now() - last < 2 * 60_000) return;
    await dispatchMessages(createAdminClient());
  } catch {
    // housekeeping must never break a page
  }
}
