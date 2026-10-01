import "server-only";
import { createClient } from "@supabase/supabase-js";
import { env } from "@/lib/env";

/**
 * Service-role client. Bypasses RLS — use ONLY for operations that cannot
 * run as the user (creating auth users, logging failed logins). Never import
 * this into client components.
 */
export function createAdminClient() {
  return createClient(env.supabaseUrl, env.serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
