import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { dispatchMessages } from "@/lib/messaging/dispatch";

export const dynamic = "force-dynamic";

/**
 * Called by Vercel Cron (see vercel.json) with "Authorization: Bearer <CRON_SECRET>".
 * Runs the alert scan and sends queued SMS / WhatsApp / email.
 */
export async function GET(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  const admin = createAdminClient();
  const scan = await admin.rpc("refresh_notifications", { p_force: true });
  const sent = await dispatchMessages(admin, 100);
  return NextResponse.json({ scan: scan.data ?? scan.error?.message, messages: sent });
}
