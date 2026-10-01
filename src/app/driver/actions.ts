"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function driverSignOut() {
  const supabase = await createClient();
  await supabase.rpc("log_auth_event", { p_action: "logout" });
  await supabase.auth.signOut();
  redirect("/login");
}
